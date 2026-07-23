# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # End-to-end PITR staging against a real Postgres: take a base backup, then
  # `restore --to-time` it into a fresh data directory and assert the directory
  # is a materialized cluster with a correct recovery configuration. (Starting
  # the recovered server to replay is an operator step, environment-specific, and
  # out of scope for the suite.) Skips unless PGKEEPER_TEST_PGHOST points at a
  # server whose role can take a base backup (REPLICATION).
  class TestPitrRestoreIntegration < Minitest::Test
    include TestHelpers

    def setup
      skip_unless_live_pg
    end

    def config(dir)
      pg = live_pg_env
      Config.parse(<<~YAML)
        workdir: #{dir}
        databases:
          - name: app
        storage:
          - type: local
            path: #{dir}/store
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

    def test_restore_stages_a_recovery_ready_data_directory
      in_tmpdir do |dir|
        cfg = config(dir)
        cluster = cfg.pitr_clusters.first
        assert_equal ExitCode::SUCCESS, PITR::BaseBackup.new(cfg, logger: null_logger).run.exit_code

        data_dir = File.join(dir, "recovered")
        target = PITR::Restore::Target.new(type: :time, value: Time.now.utc + 3600)
        PITR::Restore.new(cfg, cluster, logger: null_logger).run(target: target, data_dir: data_dir)

        assert_path_exists File.join(data_dir, "PG_VERSION") # base.tar was extracted
        assert_path_exists File.join(data_dir, "recovery.signal")

        auto_conf = File.read(File.join(data_dir, "postgresql.auto.conf"))

        assert_includes auto_conf, "restore_command"
        assert_includes auto_conf, "wal fetch"
        # Postgres-format target (space + numeric offset), not ISO-8601 "T…Z".
        assert_match(/recovery_target_time = '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\+00'/, auto_conf)
        assert_includes auto_conf, "recovery_target_action = 'promote'"
      end
    end
  end
end
