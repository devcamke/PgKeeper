# frozen_string_literal: true

require "test_helper"
require "json"

module PgKeeper
  # The Pruner's coupled base + WAL pass: base/WAL artifacts are kept out of the
  # logical-dump GFS policy and pruned by the recovery-window rule instead.
  class TestPrunerPitr < Minitest::Test
    include TestHelpers

    def seed(root, remote, manifest)
      adapter = Storage::Local.new(root: root, logger: null_logger)
      Dir.mktmpdir do |dir|
        artifact = File.join(dir, "artifact")
        File.binwrite(artifact, "bytes")
        adapter.upload(artifact, remote)
        meta = File.join(dir, "manifest.json")
        File.write(meta, JSON.generate(manifest))
        adapter.upload(meta, "#{remote}#{Manifest::SUFFIX}")
      end
    end

    def base_manifest(days_ago, start_segment)
      { "database" => "c1", "kind" => "base", "started_at" => (Time.now.utc - (days_ago * 86_400)).iso8601,
        "size_bytes" => 1, "checksum" => { "value" => "x" }, "compression" => "zip", "encryption" => "none",
        "start_segment" => start_segment }
    end

    def wal_manifest(segment)
      { "database" => "c1", "kind" => "wal", "started_at" => Time.now.utc.iso8601, "size_bytes" => 1,
        "checksum" => { "value" => "x" }, "compression" => "gzip", "encryption" => "none", "segment" => segment }
    end

    def config(dir)
      Config.parse(<<~YAML)
        workdir: #{dir}
        databases:
          - name: app
        storage:
          - type: local
            path: #{dir}/store
        retention:
          keep_last: 1
        clusters:
          - name: c1
            host: h
            pitr:
              enabled: true
              recovery_window: 7d
      YAML
    end

    def test_prunes_pre_window_base_and_wal_but_keeps_the_recovery_chain
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        # Bases at 20d (pre-window), 10d (the anchor: newest <= now-7d), 2d.
        seed(root, "c1/base/b20", base_manifest(20, "000000010000000000000010"))
        seed(root, "c1/base/b10", base_manifest(10, "000000010000000000000020"))
        seed(root, "c1/base/b02", base_manifest(2, "000000010000000000000030"))
        # One WAL below the anchor's start floor (...20), one above it.
        seed(root, "c1/wal/000000010000000000000005", wal_manifest("000000010000000000000005"))
        seed(root, "c1/wal/000000010000000000000025", wal_manifest("000000010000000000000025"))

        report = Pruner.new(config(dir), logger: null_logger).prune(apply: false)
        labels = report.deletions.map(&:label)

        base_deletions = report.deletions.select { |d| d.label.start_with?("base") }

        assert_equal 1, base_deletions.length, "only the pre-window (oldest) base is pruned"
        assert_includes labels, "wal 000000010000000000000005", "WAL below the floor is pruned"
        refute_includes labels, "wal 000000010000000000000025", "WAL the anchor still needs is kept"
      end
    end
  end
end
