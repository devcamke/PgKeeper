# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Hermetic tests for PITR::BaseBackup cluster selection and reporting. The full
  # pg_basebackup pipeline is exercised against a live server in
  # test/integration/test_basebackup_integration.rb.
  class TestPitrBaseBackup < Minitest::Test
    include TestHelpers

    def config
      Config.parse(<<~YAML)
        workdir: /tmp/pgkeeper-test
        databases:
          - name: app
        storage:
          - type: memory
        clusters:
          - name: c1
            host: h1
            pitr: { enabled: true }
          - name: c2
            host: h2
            pitr: { enabled: true }
          - name: idle
            host: h3
      YAML
    end

    def base_backup(cfg = config)
      PITR::BaseBackup.new(cfg, logger: null_logger)
    end

    def test_selects_all_pitr_clusters_by_default
      assert_equal %w[c1 c2], base_backup.send(:select_clusters, nil).map(&:name)
    end

    def test_selects_a_named_cluster
      assert_equal %w[c2], base_backup.send(:select_clusters, ["c2"]).map(&:name)
    end

    def test_unknown_cluster_raises
      assert_raises(Error) { base_backup.send(:select_clusters, ["nope"]) }
    end

    def test_a_non_pitr_cluster_is_not_selectable
      # `idle` exists but has no `pitr.enabled`, so it can't be base-backed-up.
      assert_raises(Error) { base_backup.send(:select_clusters, ["idle"]) }
    end

    def test_no_pitr_clusters_configured_raises
      cfg = Config.parse("databases:\n  - name: app\nstorage:\n  - type: memory\n")

      error = assert_raises(Error) { base_backup(cfg).send(:select_clusters, nil) }

      assert_includes error.message, "no PITR clusters"
    end
  end
end
