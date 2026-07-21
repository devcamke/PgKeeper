# frozen_string_literal: true

require "test_helper"
require "open3"

module PgKeeper
  # End-to-end verification and restore against a real Postgres: back up, verify
  # (checksum → structural → deep), and restore into a fresh database, asserting
  # the data comes back intact. Skips unless PGKEEPER_TEST_PGHOST is set.
  class TestVerifyRestoreIntegration < Minitest::Test
    include TestHelpers

    def setup
      skip_unless_live_pg
      @admin_env = base_env
      @test_db = "pgkeeper_vr_#{Process.pid}"
      @extra_dbs = []
      recreate_database(@test_db)
      seed_schema(@test_db)
    end

    def teardown
      return unless live_pg_env

      drop_database(@test_db)
      @extra_dbs.each { |db| drop_database(db) }
    end

    def test_verify_checksum_and_structural_passes_and_marks_verified
      in_tmpdir do |dir|
        config = backup_config(dir, format: "custom")
        Orchestrator.new(config, logger: null_logger).run

        results = Verifier.new(config, logger: null_logger).verify(selector: "latest")

        assert results.all?(&:ok?), "verify failed: #{results.map(&:detail).inspect}"
        assert_equal "structural", results.first.tier

        # The manifest is now stamped verified, which `list`/prune rely on.
        adapter = Storage::Local.new(root: File.join(dir, "backups"), logger: null_logger)

        assert_predicate Catalog.new(adapter).backup_sets(database: @test_db).first, :verified?
      end
    end

    def test_verify_deep_restores_into_scratch_db
      in_tmpdir do |dir|
        config = backup_config(dir, format: "custom")
        Orchestrator.new(config, logger: null_logger).run

        results = Verifier.new(config, logger: null_logger).verify(selector: "latest", deep: true)

        assert results.all?(&:ok?), "verify failed: #{results.map(&:detail).inspect}"
        assert_equal "deep", results.first.tier
      end
    end

    def test_verify_detects_corrupted_artifact
      in_tmpdir do |dir|
        config = backup_config(dir, format: "custom")
        Orchestrator.new(config, logger: null_logger).run

        corrupt_stored_artifact(dir)
        results = Verifier.new(config, logger: null_logger).verify(selector: "latest")

        refute_predicate(results.first, :ok?, "verification should fail on a corrupted artifact")
        assert_equal "checksum", results.first.tier
      end
    end

    def test_restore_round_trips_data_into_a_fresh_database
      in_tmpdir do |dir|
        config = backup_config(dir, format: "custom")
        Orchestrator.new(config, logger: null_logger).run

        target = "#{@test_db}_restored"
        create_empty_database(target)
        restore_latest(config, dir, target)

        assert_equal "3", row_count(target, "widgets"), "restored data should match the source"
      end
    end

    def test_restore_of_encrypted_compressed_plain_dump
      in_tmpdir do |dir|
        ENV["PGKEEPER_IT_PASS"] = "restore-secret"
        config = backup_config(dir, format: "plain", compression: "gzip",
                                    encryption: { "enabled" => true, "type" => "aes256gcm",
                                                  "passphrase_env" => "PGKEEPER_IT_PASS" })
        Orchestrator.new(config, logger: null_logger).run

        target = "#{@test_db}_enc_restored"
        create_empty_database(target)
        restore_latest(config, dir, target)

        assert_equal "3", row_count(target, "widgets")
      end
    end

    def test_restore_refuses_nonempty_target_without_force
      in_tmpdir do |dir|
        config = backup_config(dir, format: "custom")
        Orchestrator.new(config, logger: null_logger).run
        adapter = Storage::Local.new(root: File.join(dir, "backups"), logger: null_logger)
        set = Catalog.new(adapter).backup_sets(database: @test_db).last
        restorer = Restorer.new(config, logger: null_logger)

        # @test_db already has the widgets table → refuse without force.
        err = assert_raises(Error) do
          restorer.restore(set.primary, adapter, @test_db, config.database(@test_db), force: false)
        end
        assert_match(/--force/, err.message)

        # With force, it succeeds.
        restorer.restore(set.primary, adapter, @test_db, config.database(@test_db), force: true)

        assert_equal "3", row_count(@test_db, "widgets")
      end
    end

    private

    def restore_latest(config, dir, target)
      adapter = Storage::Local.new(root: File.join(dir, "backups"), logger: null_logger)
      set = Catalog.new(adapter).backup_sets(database: @test_db).last
      Restorer.new(config, logger: null_logger)
              .restore(set.primary, adapter, target, config.database(@test_db), force: false)
    end

    def corrupt_stored_artifact(dir)
      artifact = Dir.glob(File.join(dir, "backups", @test_db, "*"))
                    .reject { |f| f.end_with?(Manifest::SUFFIX) }.first
      File.binwrite(artifact, "corrupted contents")
    end

    def backup_config(dir, format:, compression: "none", encryption: nil)
      Config.new({
                   "workdir" => dir,
                   "compression" => compression,
                   "encryption" => encryption || { "enabled" => false },
                   "storage" => [{ "type" => "local", "path" => File.join(dir, "backups") }],
                   "databases" => [db_hash(format)]
                 })
    end

    def db_hash(format)
      conn = live_pg_env
      {
        "name" => @test_db, "database" => @test_db,
        "host" => conn["host"], "port" => conn["port"].to_i,
        "username" => conn["username"], "password" => conn["password"], "format" => format
      }
    end

    def base_env
      conn = live_pg_env
      {
        "PGHOST" => conn["host"], "PGPORT" => conn["port"].to_s, "PGUSER" => conn["username"],
        "PGPASSWORD" => conn["password"], "PGDATABASE" => conn["database"]
      }.compact
    end

    def psql!(env, sql, db: nil)
      run_env = db ? env.merge("PGDATABASE" => db) : env
      out, status = Open3.capture2e(run_env, "psql", "-XtAc", sql)
      raise "psql failed: #{sql}\n#{out}" unless status.success?

      out
    end

    def row_count(db, table)
      psql!(base_env, "SELECT count(*) FROM #{table}", db: db).strip
    end

    def recreate_database(name)
      psql!(@admin_env, "DROP DATABASE IF EXISTS #{name}")
      psql!(@admin_env, "CREATE DATABASE #{name}")
    end

    def create_empty_database(name)
      @extra_dbs << name
      psql!(@admin_env, "DROP DATABASE IF EXISTS #{name}")
      psql!(@admin_env, "CREATE DATABASE #{name}")
    end

    def drop_database(name)
      psql!(base_env, "DROP DATABASE IF EXISTS #{name}")
    rescue StandardError
      nil
    end

    def seed_schema(name)
      psql!(@admin_env, <<~SQL, db: name)
        CREATE TABLE widgets (id serial PRIMARY KEY, label text NOT NULL);
        INSERT INTO widgets (label) VALUES ('alpha'), ('beta'), ('gamma');
      SQL
    end
  end
end
