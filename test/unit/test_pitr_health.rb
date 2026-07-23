# frozen_string_literal: true

require "test_helper"
require "json"

module PgKeeper
  # PITR::Health: WAL lag, recovery window, and the dead-man's switch, computed
  # from the catalog alone.
  class TestPitrHealth < Minitest::Test
    include TestHelpers

    NOW = Time.utc(2026, 7, 23, 12, 0, 0)

    def seed(root, remote, manifest)
      adapter = Storage::Local.new(root: root, logger: null_logger)
      Dir.mktmpdir do |dir|
        artifact = File.join(dir, "a")
        File.binwrite(artifact, "x")
        adapter.upload(artifact, remote)
        meta = File.join(dir, "m.json")
        File.write(meta, JSON.generate(manifest))
        adapter.upload(meta, "#{remote}#{Manifest::SUFFIX}")
      end
    end

    def seed_base(root, label, at)
      seed(root, "c1/base/#{label}", { "database" => "c1", "kind" => "base", "started_at" => at.utc.iso8601,
                                       "size_bytes" => 1, "checksum" => { "value" => "x" },
                                       "start_segment" => "000000010000000000000005" })
    end

    def seed_wal(root, segment, at)
      seed(root, "c1/wal/#{segment}", { "database" => "c1", "kind" => "wal", "started_at" => at.utc.iso8601,
                                        "size_bytes" => 1, "checksum" => { "value" => "x" }, "segment" => segment })
    end

    def config(dir, pitr: "enabled: true")
      Config.parse("workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/store\n" \
                   "clusters:\n  - name: c1\n    host: h\n    pitr: { #{pitr} }\n")
    end

    def snapshot(dir, **)
      cfg = config(dir, **)
      PITR::Health.new(cfg, logger: null_logger).snapshot(cfg.pitr_clusters.first, now: NOW)
    end

    def test_lag_and_window_are_measured_from_the_newest_wal_and_oldest_base
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, "b1", NOW - (2 * 86_400))   # oldest base: 2 days ago
        seed_base(root, "b2", NOW - 3600)           # newest base: 1 hour ago
        seed_wal(root, "000000010000000000000005", NOW - 7200)
        seed_wal(root, "000000010000000000000006", NOW - 300) # newest WAL: 5 min ago

        snap = snapshot(dir)

        assert_equal 300, snap.lag_seconds
        assert_equal 2 * 86_400, snap.recovery_window_seconds
        assert_equal "000000010000000000000006", snap.last_wal_segment
        assert_equal 2, snap.base_count
        assert_equal 2, snap.wal_count
        assert_equal(NOW - 3600, snap.last_base_at)
      end
    end

    def test_stalled_when_lag_exceeds_max_lag
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, "b1", NOW - 3600)
        seed_wal(root, "000000010000000000000005", NOW - 1800) # 30 min old

        assert_predicate snapshot(dir, pitr: "enabled: true, max_lag: 5m"), :stalled?
        refute_predicate snapshot(dir, pitr: "enabled: true, max_lag: 1h"), :stalled?
        # No threshold configured: never stalled, and the switch is unarmed.
        refute_predicate snapshot(dir, pitr: "enabled: true"), :stalled?
        refute_predicate snapshot(dir, pitr: "enabled: true"), :monitored?
      end
    end

    def test_window_short_when_reachable_span_is_below_the_promise
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, "b1", NOW - 3600) # only 1h of history
        seed_wal(root, "000000010000000000000005", NOW - 60)

        assert_predicate snapshot(dir, pitr: "enabled: true, recovery_window: 7d"), :window_short?
        refute_predicate snapshot(dir, pitr: "enabled: true, recovery_window: 30m"), :window_short?
      end
    end

    def test_missing_base_or_wal_is_not_green
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_wal(root, "000000010000000000000005", NOW - 60) # WAL but no base

        snap = snapshot(dir)

        refute_predicate snap, :base?
        assert_predicate snap, :wal?
        refute_predicate snap, :ok?
        assert_equal "red", snap.light
        assert_nil snap.recovery_window_seconds
      end
    end

    def test_healthy_cluster_is_green
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, "b1", NOW - 3600)
        seed_wal(root, "000000010000000000000005", NOW - 60)

        snap = snapshot(dir, pitr: "enabled: true, recovery_window: 30m, max_lag: 10m")

        assert_predicate snap, :ok?
        assert_equal "green", snap.light
      end
    end
  end
end
