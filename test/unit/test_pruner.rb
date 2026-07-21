# frozen_string_literal: true

require "test_helper"
require "support/backup_seeding"

module PgKeeper
  class TestPruner < Minitest::Test
    include TestHelpers
    include BackupSeeding

    def setup
      @root = Dir.mktmpdir("pgkeeper-pruner-test-")
    end

    def teardown
      FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    end

    def config(retention)
      Config.new({
                   "workdir" => @root,
                   "storage" => [{ "type" => "local", "path" => @root }],
                   "retention" => retention,
                   "databases" => [{ "name" => "app" }]
                 })
    end

    def seed_days(count)
      count.times { |i| seed_backup(@root, "app", Time.utc(2026, 1, 1) + (i * 86_400)) }
    end

    def remaining_labels
      Catalog.new(Storage::Local.new(root: @root, logger: null_logger))
             .backup_sets(database: "app").map(&:label)
    end

    def test_dry_run_reports_but_deletes_nothing
      seed_days(5)
      report = Pruner.new(config({ "keep_last" => 2 }), logger: null_logger).prune(apply: false)

      assert_equal 3, report.count
      refute report.applied
      assert_equal 5, remaining_labels.length, "dry run must not delete anything"
    end

    def test_apply_deletes_out_of_policy_sets
      seed_days(5)
      report = Pruner.new(config({ "keep_last" => 2 }), logger: null_logger).prune(apply: true)

      assert_equal 3, report.count
      assert report.applied
      remaining = remaining_labels

      assert_equal 2, remaining.length
      assert_equal %w[2026-01-04T000000Z 2026-01-05T000000Z], remaining, "keeps the two newest"
    end

    def test_deletes_both_artifact_and_manifest
      seed_days(3)
      Pruner.new(config({ "keep_last" => 1 }), logger: null_logger).prune(apply: true)
      leftover = Dir.glob(File.join(@root, "**", "*")).select { |f| File.file?(f) }
      # 1 kept set = 1 artifact + 1 manifest.
      assert_equal 2, leftover.length
    end

    def test_no_retention_configured_is_noop
      seed_days(3)
      report = Pruner.new(config({}), logger: null_logger).prune(apply: true)

      refute report.configured
      assert_equal 0, report.count
      assert_equal 3, remaining_labels.length
    end

    def test_never_prunes_below_policy_and_keeps_newest
      seed_days(3)
      # keep_last:0 would delete all, but the newest is always protected.
      report = Pruner.new(config({ "keep_last" => 0 }), logger: null_logger).prune(apply: true)

      assert_equal 2, report.count
      assert_equal ["2026-01-03T000000Z"], remaining_labels
    end

    def test_protects_backups_newer_than_last_verified
      # 4 daily backups; mark day 2 verified. keep_last:1 would drop days 1-3,
      # but nothing newer than the verified day-2 may be pruned.
      4.times do |i|
        verified = i == 1 ? Time.utc(2026, 1, 2, 12) : nil
        seed_backup(@root, "app", Time.utc(2026, 1, 1) + (i * 86_400), verified_at: verified)
      end
      Pruner.new(config({ "keep_last" => 1 }), logger: null_logger).prune(apply: true)

      remaining = remaining_labels

      assert_includes remaining, "2026-01-03T000000Z", "newer-than-verified must be protected"
      assert_includes remaining, "2026-01-04T000000Z"
      refute_includes remaining, "2026-01-01T000000Z", "older-than-verified may be pruned"
    end
  end
end
