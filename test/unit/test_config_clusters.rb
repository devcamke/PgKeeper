# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Config parsing for the PITR `clusters:` block (Phase 12, Stage 0). Validation
  # only — no base-backup / WAL behavior exists yet.
  class TestConfigClusters < Minitest::Test
    include TestHelpers

    def base(clusters_yaml)
      Config.parse(<<~YAML)
        databases:
          - name: app
        #{clusters_yaml}
      YAML
    end

    def test_clusters_are_optional
      config = Config.parse("databases:\n  - name: app\n")

      assert_empty config.clusters
      assert_empty config.pitr_clusters
    end

    def test_parses_a_full_pitr_cluster
      config = base(<<~YAML)
        clusters:
          - name: app_cluster
            host: db.internal
            port: 5432
            username: repl
            password: secret
            pitr:
              enabled: true
              mode: stream
              slot: pgkeeper
              recovery_window: 7d
              base_backup:
                schedule: "daily at 02:00"
              destinations: [nas, s3]
      YAML

      cluster = config.cluster("app_cluster")

      assert_equal [cluster], config.pitr_clusters
      assert_predicate cluster, :pitr?
      assert_equal "postgres", cluster.database, "maintenance DB defaults to postgres"
      assert_equal "stream", cluster.pitr.mode
      assert_equal "pgkeeper", cluster.pitr.slot
      assert_equal 7 * 86_400, cluster.pitr.recovery_window_seconds
      assert_equal "daily at 02:00", cluster.pitr.base_backup_schedule
      assert_equal %w[nas s3], cluster.pitr.destinations
    end

    def test_libpq_env_keeps_password_out_of_argv
      cluster = base(<<~YAML).cluster("c")
        clusters:
          - name: c
            host: h
            port: 6000
            username: u
            password: pw
            pitr: { enabled: true }
      YAML
      env = cluster.libpq_env

      assert_equal "h", env["PGHOST"]
      assert_equal "6000", env["PGPORT"]
      assert_equal "u", env["PGUSER"]
      assert_equal "pw", env["PGPASSWORD"]
    end

    def test_a_cluster_without_pitr_enabled_is_not_a_pitr_cluster
      config = base(<<~YAML)
        clusters:
          - name: idle
            host: h
      YAML

      refute_predicate config.cluster("idle"), :pitr?
      assert_empty config.pitr_clusters
    end

    def test_mode_defaults_to_stream_and_rejects_unknown_modes
      assert_equal "stream", base("clusters:\n  - name: c\n    pitr: { enabled: true }").cluster("c").pitr.mode

      err = assert_raises(ConfigError) { base("clusters:\n  - name: c\n    pitr: { mode: telepathy }") }

      assert(err.problems.any? { |p| p.include?("mode must be one of") })
    end

    def test_rejects_a_bad_recovery_window
      err = assert_raises(ConfigError) do
        base("clusters:\n  - name: c\n    pitr: { recovery_window: soon }")
      end

      assert(err.problems.any? { |p| p.include?("recovery_window") })
    end

    def test_rejects_unknown_keys_at_every_level
      err = assert_raises(ConfigError) { base("clusters:\n  - name: c\n    bogus: 1") }

      assert(err.problems.any? { |p| p.include?("unknown key") }, "cluster level")

      err = assert_raises(ConfigError) { base("clusters:\n  - name: c\n    pitr: { nope: 1 }") }

      assert(err.problems.any? { |p| p.include?("unknown key") }, "pitr level")

      err = assert_raises(ConfigError) do
        base("clusters:\n  - name: c\n    pitr:\n      base_backup: { every: day }")
      end

      assert(err.problems.any? { |p| p.include?("unknown key") }, "base_backup level")
    end

    def test_rejects_duplicate_and_nameless_clusters
      err = assert_raises(ConfigError) do
        base("clusters:\n  - name: dup\n  - name: dup")
      end

      assert(err.problems.any? { |p| p.include?("duplicate cluster name") })

      err = assert_raises(ConfigError) { base("clusters:\n  - host: h") }

      assert(err.problems.any? { |p| p.include?("missing a non-empty `name`") })
    end

    def test_rejects_an_invalid_base_backup_schedule
      err = assert_raises(ConfigError) do
        base("clusters:\n  - name: c\n    pitr:\n      base_backup: { schedule: \"not a schedule\" }")
      end

      assert(err.problems.any? { |p| p.include?("base_backup.schedule") })
    end
  end
end
