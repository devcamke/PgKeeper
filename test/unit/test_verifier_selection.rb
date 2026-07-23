# frozen_string_literal: true

require "test_helper"
require "json"

module PgKeeper
  # Which backup sets `pgkeeper verify` picks up. PITR cluster artifacts share
  # the catalog but are not logical dumps: selecting them would pg_restore a
  # WAL segment and turn every scheduled verify permanently red.
  class TestVerifierSelection < Minitest::Test
    include TestHelpers

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
      adapter
    end

    def config(dir)
      Config.parse(
        "workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/store\n" \
        "clusters:\n  - name: c1\n    host: h\n    pitr: { enabled: true }\n"
      )
    end

    def test_pitr_cluster_artifacts_are_not_selected_as_backup_sets
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed(root, "app/app-2026.dump",
             { "database" => "app", "kind" => "database", "started_at" => Time.now.utc.iso8601,
               "size_bytes" => 1, "checksum" => { "value" => "x" } })
        seed(root, "c1/wal/000000010000000000000001",
             { "database" => "c1", "kind" => "wal", "started_at" => Time.now.utc.iso8601,
               "size_bytes" => 1, "checksum" => { "value" => "x" },
               "segment" => "000000010000000000000001" })

        cfg = config(dir)
        verifier = Verifier.new(cfg, logger: null_logger)
        adapter = Storage::Local.new(root: root, logger: null_logger)
        sets = verifier.send(:select_sets, Catalog.new(adapter), "all", nil)

        assert_equal %w[app], sets.map(&:database).uniq,
                     "cluster WAL/base artifacts must not be selected as logical backup sets"
      end
    end
  end
end
