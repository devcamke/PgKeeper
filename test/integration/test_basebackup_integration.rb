# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # End-to-end PITR base backup against a real Postgres: pg_basebackup → bundle →
  # (encrypt) → manifest → local store → catalog. Skips unless PGKEEPER_TEST_PGHOST
  # points at a server whose role can take a physical base backup (REPLICATION).
  class TestBaseBackupIntegration < Minitest::Test
    include TestHelpers

    def setup
      skip_unless_live_pg
    end

    def cluster_config(dir)
      pg = live_pg_env
      Config.parse(<<~YAML)
        workdir: #{dir}
        databases:
          - name: app
        storage:
          - type: local
            path: #{dir}/backups
        clusters:
          - name: it_cluster
            host: #{pg['host']}
            port: #{pg['port']}
            username: #{pg['username']}
            password: #{pg['password']}
            database: #{pg['database']}
            pitr:
              enabled: true
      YAML
    end

    def test_base_backup_is_captured_stored_and_cataloged
      in_tmpdir do |dir|
        report = PITR::BaseBackup.new(cluster_config(dir), logger: null_logger).run

        assert_equal ExitCode::SUCCESS, report.exit_code, report.results.first.error&.message

        artifact = report.results.first.artifacts.first

        assert_equal "base", artifact[:kind]
        assert_equal "zip", artifact[:compression]
        assert_predicate artifact[:destinations].first, :ok?

        adapter = Storage.build({ "type" => "local", "path" => File.join(dir, "backups") }, logger: null_logger)
        base = Catalog.new(adapter).artifacts.find { |a| a.kind == "base" }

        refute_nil base, "the base backup is cataloged as kind=base"
        assert_equal "it_cluster", base.database
      end
    end
  end
end
