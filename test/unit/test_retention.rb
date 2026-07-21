# frozen_string_literal: true

require "test_helper"
require "time"

module PgKeeper
  class TestRetention < Minitest::Test
    include TestHelpers

    FakeSet = Struct.new(:timestamp)

    def sets(*iso_times)
      iso_times.map { |t| FakeSet.new(Time.iso8601(t)) }
    end

    def times_of(list)
      list.map { |s| s.timestamp.iso8601 }
    end

    def test_unconfigured_policy_keeps_everything
      policy = Retention.build({})
      all = sets("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z")
      plan = policy.partition(all)

      assert_equal all, plan.keep
      assert_empty plan.delete
    end

    def test_keep_last_keeps_newest_n
      policy = Retention.build({ "keep_last" => 2 })
      all = sets(
        "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z",
        "2026-01-03T00:00:00Z", "2026-01-04T00:00:00Z"
      )
      plan = policy.partition(all)

      assert_equal ["2026-01-03T00:00:00Z", "2026-01-04T00:00:00Z"], times_of(plan.keep)
      assert_equal ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"], times_of(plan.delete)
    end

    def test_keep_daily_keeps_newest_per_day
      policy = Retention.build({ "keep_daily" => 2 })
      # Two backups on day 3, one each on days 1-2. keep_daily:2 keeps the two
      # most recent days (day 3 and day 2), newest backup within each.
      all = sets(
        "2026-03-01T02:00:00Z",
        "2026-03-02T02:00:00Z",
        "2026-03-03T02:00:00Z", "2026-03-03T20:00:00Z"
      )
      plan = policy.partition(all)

      assert_equal ["2026-03-02T02:00:00Z", "2026-03-03T20:00:00Z"], times_of(plan.keep)
      assert_includes times_of(plan.delete), "2026-03-01T02:00:00Z"
      assert_includes times_of(plan.delete), "2026-03-03T02:00:00Z"
    end

    def test_always_keeps_most_recent_even_when_policy_would_drop_it
      # keep_daily:1 with all backups on the same day keeps only the newest.
      policy = Retention.build({ "keep_daily" => 1 })
      all = sets("2026-05-01T01:00:00Z", "2026-05-01T05:00:00Z", "2026-05-01T09:00:00Z")
      plan = policy.partition(all)

      assert_equal ["2026-05-01T09:00:00Z"], times_of(plan.keep)
      refute_empty plan.delete
    end

    def test_never_prunes_to_zero
      # A policy that selects nothing still keeps the newest backup.
      policy = Retention.build({ "keep_last" => 0 })
      all = sets("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z")
      plan = policy.partition(all)

      assert_equal ["2026-01-02T00:00:00Z"], times_of(plan.keep)
    end

    def test_gfs_union_of_daily_weekly_monthly
      # Daily backups across ~10 weeks; GFS keeps recent dailies, then weeklies,
      # then monthlies, as a union.
      days = (0...70).map { |i| Time.utc(2026, 1, 1) + (i * 86_400) }
      all = days.map { |t| FakeSet.new(t) }
      policy = Retention.build({ "keep_daily" => 7, "keep_weekly" => 4, "keep_monthly" => 3 })
      plan = policy.partition(all)

      # The 7 most recent days are all kept.
      assert_operator plan.keep.length, :>=, 7
      # Newest overall is kept; oldest is pruned (covered by monthly at most).
      assert_includes plan.keep, all.last
      assert_includes plan.delete, all.first
      # Keep + delete partition the whole set with no overlap.
      assert_equal all.length, plan.keep.length + plan.delete.length
      assert_empty(plan.keep & plan.delete)
    end

    def test_weekly_bucket_handles_year_boundary
      # Backups straddling the 2025/2026 new year fall in different ISO weeks.
      all = sets(
        "2025-12-29T00:00:00Z", # ISO week 2026-W01 (Mon)
        "2025-12-31T00:00:00Z",
        "2026-01-05T00:00:00Z"  # ISO week 2026-W02
      )
      policy = Retention.build({ "keep_weekly" => 1 })
      plan = policy.partition(all)

      # keep_weekly:1 keeps the newest of the single most recent ISO week, plus
      # the always-keep-newest rail (same backup here).
      assert_includes times_of(plan.keep), "2026-01-05T00:00:00Z"
    end

    def test_protected_after_keeps_newer_than_last_verified
      policy = Retention.build({ "keep_last" => 1 })
      all = sets(
        "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z",
        "2026-06-03T00:00:00Z", "2026-06-04T00:00:00Z"
      )
      # Last verified is 2026-06-02; nothing newer than it may be pruned.
      plan = policy.partition(all, protected_after: Time.iso8601("2026-06-02T00:00:00Z"))

      assert_includes times_of(plan.keep), "2026-06-03T00:00:00Z"
      assert_includes times_of(plan.keep), "2026-06-04T00:00:00Z"
      assert_includes times_of(plan.delete), "2026-06-01T00:00:00Z"
    end

    def test_empty_input
      plan = Retention.build({ "keep_last" => 5 }).partition([])

      assert_empty plan.keep
      assert_empty plan.delete
    end
  end
end
