# frozen_string_literal: true

require "test_helper"
require "open3"

module PgKeeper
  # End-to-end against a real Postgres: seed a database, run the full v0.2
  # pipeline (dump → compress → encrypt → fan-out), and assert the stored
  # artifacts are correct, reversible, and restorable.
  #
  # Skips unless PGKEEPER_TEST_PGHOST points at a reachable server.
  class TestBackupIntegration < Minitest::Test
    include TestHelpers

    def setup
      skip_unless_live_pg
      @admin_env = base_env
      @test_db = "pgkeeper_it_#{Process.pid}"
      recreate_database(@test_db)
      seed_schema(@test_db)
    end

    def teardown
      drop_database(@test_db) if live_pg_env
    end

    def test_custom_backup_is_stored_with_valid_manifest
      in_tmpdir do |dir|
        report = run_backup(dir, format: "custom")

        assert_equal ExitCode::SUCCESS, report.exit_code, report.results.first.error&.message

        artifact = report.results.first.artifacts.first
        stored = stored_path(dir, artifact)

        assert_path_exists stored
        assert_predicate artifact[:destinations].first, :ok?

        manifest = Manifest.load("#{stored}#{Manifest::SUFFIX}")

        assert manifest.checksum_valid?(stored), "stored checksum must match"
        assert_equal "none", manifest.data["compression"]
        assert_equal "none", manifest.data["encryption"]
        assert manifest.data["server_version"]
      end
    end

    def test_gzip_compressed_plain_dump_round_trips
      in_tmpdir do |dir|
        report = run_backup(dir, format: "plain", compression: "gzip")
        artifact = report.results.first.artifacts.first

        assert_equal "gzip", artifact[:compression]

        stored = stored_path(dir, artifact)

        assert stored.end_with?(".sql.gz"), "artifact should carry .sql.gz suffix, got #{stored}"

        restored = File.join(dir, "restored.sql")
        Compress.for("gzip").decompress(stored, restored)

        assert_includes File.read(restored), "widgets", "decompressed SQL should contain the table"
      end
    end

    def test_encrypted_dump_round_trips_and_hides_plaintext
      in_tmpdir do |dir|
        report = run_backup(dir, format: "plain", encryption: aes_config("s3cr3t"))
        artifact = report.results.first.artifacts.first

        assert_equal "aes256gcm", artifact[:encryption]

        stored = stored_path(dir, artifact)

        refute_includes File.binread(stored), "widgets", "ciphertext must not leak table names"

        decrypted = File.join(dir, "plain.sql")
        Crypto.build(aes_config("s3cr3t")).decrypt(stored, decrypted)

        assert_includes File.read(decrypted), "widgets"
      end
    end

    def test_compressed_then_encrypted_pipeline
      in_tmpdir do |dir|
        report = run_backup(dir, format: "plain", compression: "gzip", encryption: aes_config("k"))
        artifact = report.results.first.artifacts.first

        assert_equal "gzip", artifact[:compression]
        assert_equal "aes256gcm", artifact[:encryption]

        stored = stored_path(dir, artifact)

        assert stored.end_with?(".sql.gz.enc"), "artifact should carry .sql.gz.enc, got #{stored}"

        gz = File.join(dir, "out.sql.gz")
        Crypto.build(aes_config("k")).decrypt(stored, gz)
        sql = File.join(dir, "out.sql")
        Compress.for("gzip").decompress(gz, sql)

        assert_includes File.read(sql), "widgets"
      end
    end

    def test_custom_dump_stays_structurally_restorable
      in_tmpdir do |dir|
        report = run_backup(dir, format: "custom")
        stored = stored_path(dir, report.results.first.artifacts.first)

        out, status = Open3.capture2e("pg_restore", "--list", stored)

        assert_predicate status, :success?, "pg_restore --list should succeed:\n#{out}"
        assert_includes out, "widgets"
      end
    end

    def test_directory_format_is_packaged_into_zip
      in_tmpdir do |dir|
        report = run_backup(dir, format: "directory")
        artifact = report.results.first.artifacts.first

        assert_equal "zip", artifact[:compression]
        assert stored_path(dir, artifact).end_with?(".dir.zip")
      end
    end

    def test_fans_out_to_multiple_destinations
      in_tmpdir do |dir|
        config = Config.new({
                              "workdir" => dir,
                              "storage" => [
                                { "type" => "local", "path" => File.join(dir, "primary") },
                                { "type" => "local", "path" => File.join(dir, "mirror") }
                              ],
                              "databases" => [db_hash(format: "custom")]
                            })
        report = Orchestrator.new(config, logger: null_logger).run
        artifact = report.results.first.artifacts.first

        assert_equal 2, artifact[:destinations].length
        assert(artifact[:destinations].all?(&:ok?), "both destinations should succeed")
        assert_path_exists File.join(dir, "mirror", @test_db, artifact[:artifact])
      end
    end

    def test_globals_are_captured_as_second_artifact
      in_tmpdir do |dir|
        report = run_backup(dir, format: "custom", include_globals: true)
        kinds = report.results.first.artifacts.map { |a| a[:kind] }

        assert_includes kinds, "database"
        assert_includes kinds, "globals"
      end
    end

    private

    def run_backup(dir, format:, compression: "none", encryption: nil, include_globals: false)
      config = Config.new({
                            "workdir" => dir,
                            "compression" => compression,
                            "encryption" => encryption || { "enabled" => false },
                            "storage" => [{ "type" => "local", "path" => File.join(dir, "backups") }],
                            "databases" => [db_hash(format: format, include_globals: include_globals)]
                          })
      Orchestrator.new(config, logger: null_logger).run
    end

    def db_hash(format:, include_globals: false)
      conn = live_pg_env
      {
        "name" => @test_db, "database" => @test_db,
        "host" => conn["host"], "port" => conn["port"].to_i,
        "username" => conn["username"], "password" => conn["password"],
        "format" => format, "include_globals" => include_globals
      }
    end

    def aes_config(pass)
      ENV["PGKEEPER_IT_PASS"] = pass
      { "enabled" => true, "type" => "aes256gcm", "passphrase_env" => "PGKEEPER_IT_PASS" }
    end

    # Resolve the on-disk path of a stored artifact: <root>/<db-slug>/<basename>.
    def stored_path(dir, artifact)
      File.join(dir, "backups", @test_db, artifact[:artifact])
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

    def recreate_database(name)
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
