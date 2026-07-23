# frozen_string_literal: true

require "test_helper"
require "json"

module PgKeeper
  # `verify --pitr`: from the newest base's start segment, is the archived WAL an
  # unbroken chain? A missing segment must fail verification.
  class TestPitrVerify < Minitest::Test
    include TestHelpers

    START = "000000010000000000000005"

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

    def seed_base(root, start_segment: START)
      seed(root, "c1/base/b1",
           { "database" => "c1", "kind" => "base", "started_at" => Time.now.utc.iso8601, "size_bytes" => 1,
             "checksum" => { "value" => "x" }, "start_segment" => start_segment })
    end

    def seed_wal(root, segment)
      seed(root, "c1/wal/#{segment}", { "database" => "c1", "kind" => "wal", "started_at" => Time.now.utc.iso8601,
                                        "size_bytes" => 1, "checksum" => { "value" => "x" }, "segment" => segment })
    end

    def config(dir)
      Config.parse("workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/store\n" \
                   "clusters:\n  - name: c1\n    host: h\n    pitr: { enabled: true }\n")
    end

    def verify(dir)
      cfg = config(dir)
      PITR::Verify.new(cfg, cfg.pitr_clusters.first, logger: null_logger).verify
    end

    def test_an_intact_chain_passes
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root)
        %w[000000010000000000000005 000000010000000000000006 000000010000000000000007].each { |s| seed_wal(root, s) }

        result = verify(dir)

        assert_predicate result, :ok?
        assert_equal START, result.from_segment
        assert_equal 3, result.segment_count
      end
    end

    def test_a_gap_in_the_chain_fails
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root)
        # 06 is missing between 05 and 07.
        %w[000000010000000000000005 000000010000000000000007].each { |s| seed_wal(root, s) }

        result = verify(dir)

        refute_predicate result, :ok?
        assert_includes result.detail, "gap"
        assert_equal "000000010000000000000006", result.gap.missing
      end
    end

    def test_no_base_fails
      in_tmpdir do |dir|
        seed_wal(File.join(dir, "store"), START)

        refute_predicate verify(dir), :ok?
      end
    end

    def test_a_gap_at_the_head_of_the_chain_fails
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, start_segment: "000000010000000000000005")
        # 05 and 06 were never archived; the chain is internally contiguous but
        # starts after the base's start segment — unreachable by replay.
        %w[000000010000000000000007 000000010000000000000008].each { |s| seed_wal(root, s) }

        result = verify(dir)

        refute_predicate result, :ok?
        assert_includes result.detail, "does not start at the base's start segment"
        assert_equal "000000010000000000000005", result.gap.missing
      end
    end

    def test_archived_history_files_do_not_disturb_the_chain
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root)
        %w[000000010000000000000005 000000010000000000000006].each { |s| seed_wal(root, s) }
        seed_wal(root, "00000002.history")
        seed_wal(root, "000000010000000000000005.00000028.backup")

        result = verify(dir)

        assert_predicate result, :ok?
        assert_equal 2, result.segment_count
      end
    end

    def test_no_wal_at_or_after_the_base_fails
      in_tmpdir do |dir|
        root = File.join(dir, "store")
        seed_base(root, start_segment: "000000010000000000000005")
        seed_wal(root, "000000010000000000000002") # only WAL older than the base

        result = verify(dir)

        refute_predicate result, :ok?
        assert_includes result.detail, "no archived WAL"
      end
    end
  end
end
