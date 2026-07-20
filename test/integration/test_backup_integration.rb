# frozen_string_literal: true

require "test_helper"
require "open3"

module PgKeeper
  # End-to-end: seed a real Postgres database, run a backup, and assert the
  # artifact + manifest are correct and the dump is structurally restorable.
  #
  # Skips entirely unless PGKEEPER_TEST_PGHOST (and friends) point at a reachable
  # server — so the unit suite stays hermetic while CI runs the real thing
  # against a Postgres service container.
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

    def test_backup_produces_artifact_and_valid_manifest
      in_tmpdir do |dir|
        config = build_config(dir, format: "custom", include_globals: false)
        report = Orchestrator.new(config, logger: null_logger).run

        assert_equal ExitCode::SUCCESS, report.exit_code, "run should succeed"
        result = report.results.first

        assert_predicate result, :success?, "database backup should succeed: #{result.error&.message}"

        artifact = result.artifacts.first

        assert_path_exists artifact[:artifact]
        assert_path_exists artifact[:manifest]

        manifest = Manifest.load(artifact[:manifest])

        assert manifest.checksum_valid?(artifact[:artifact]), "checksum should match artifact on disk"
        assert_operator manifest.size_bytes, :>, 0
        assert_equal "custom", manifest.data["format"]
        assert manifest.data["server_version"], "server version recorded"
        assert manifest.data["pg_dump_version"], "pg_dump version recorded"
      end
    end

    def test_custom_dump_is_structurally_restorable
      in_tmpdir do |dir|
        config = build_config(dir, format: "custom", include_globals: false)
        report = Orchestrator.new(config, logger: null_logger).run
        artifact = report.results.first.artifacts.first[:artifact]

        # pg_restore --list proves the archive is complete and readable, and
        # that our seeded table made it into the dump.
        out, status = Open3.capture2e("pg_restore", "--list", artifact)

        assert_predicate status, :success?, "pg_restore --list should succeed:\n#{out}"
        assert_includes out, "widgets", "dumped archive should contain the seeded table"
      end
    end

    def test_include_globals_produces_second_artifact
      in_tmpdir do |dir|
        config = build_config(dir, format: "custom", include_globals: true)
        report = Orchestrator.new(config, logger: null_logger).run

        result = report.results.first

        assert_predicate result, :success?, result.error&.message
        kinds = result.artifacts.map { |a| a[:kind] }

        assert_includes kinds, "database"
        assert_includes kinds, "globals"
      end
    end

    def test_only_flag_limits_databases
      in_tmpdir do |dir|
        config = build_config(dir, format: "custom", include_globals: false)
        report = Orchestrator.new(config, logger: null_logger).run(only: [@test_db])

        assert_equal 1, report.results.length
        assert_equal @test_db, report.results.first.database
      end
    end

    private

    def build_config(dir, format:, include_globals:)
      conn = live_pg_env
      Config.parse(<<~YAML)
        workdir: #{dir}
        storage:
          - type: local
            path: #{File.join(dir, 'backups')}
        databases:
          - name: #{@test_db}
            database: #{@test_db}
            host: #{conn['host']}
            port: #{conn['port']}
            username: #{conn['username']}
            password: #{conn['password']}
            format: #{format}
            include_globals: #{include_globals}
      YAML
    end

    def base_env
      conn = live_pg_env
      {
        "PGHOST" => conn["host"],
        "PGPORT" => conn["port"].to_s,
        "PGUSER" => conn["username"],
        "PGPASSWORD" => conn["password"],
        "PGDATABASE" => conn["database"]
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
