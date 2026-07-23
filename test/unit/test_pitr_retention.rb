# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # The coupled base + WAL retention planner. The invariant under test: after any
  # prune, at least one surviving base still reaches the far edge of the recovery
  # window, and no surviving base is missing WAL below its start segment.
  class TestPitrRetention < Minitest::Test
    include TestHelpers

    Base = Struct.new(:timestamp, :start_segment, keyword_init: true)
    Seg = Struct.new(:segment, keyword_init: true)

    NOW = Time.utc(2026, 7, 23, 12, 0, 0)
    WEEK = 7 * 86_400

    def base(days_ago, segment) = Base.new(timestamp: NOW - (days_ago * 86_400), start_segment: segment)
    def seg(name) = Seg.new(segment: name)

    def plan(bases:, wals: [], window: WEEK)
      PITR::Retention.plan(bases: bases, wals: wals, window_seconds: window, now: NOW)
    end

    def test_keeps_everything_without_a_recovery_window
      assert_predicate plan(bases: [base(10, "S")], wals: [seg("W")], window: nil), :empty?
    end

    def test_keeps_everything_until_a_base_is_old_enough_to_cover_the_window
      # Only a 2-day-old base but a 7-day window: can't recover to 7 days back
      # yet, so nothing is safe to prune.
      assert_predicate plan(bases: [base(2, "000000010000000000000010")],
                            wals: [seg("000000010000000000000001")]), :empty?
    end

    def test_prunes_bases_and_wal_before_the_anchor
      old = base(20, "000000010000000000000005")
      anchor = base(10, "000000010000000000000010") # newest base still <= now-7d
      recent = base(2, "000000010000000000000030")
      wals = %w[000000010000000000000004
                000000010000000000000010
                000000010000000000000031].map { |n| seg(n) }

      result = plan(bases: [recent, old, anchor], wals: wals)

      assert_equal [old], result.bases, "only bases older than the anchor are pruned"
      refute_includes result.bases, anchor, "the anchor (window edge) is kept"
      refute_includes result.bases, recent, "newer bases are kept"
      # Floor is the anchor's start segment; only WAL strictly before it goes.
      assert_equal %w[000000010000000000000004], result.wals.map(&:segment)
    end

    def test_a_single_base_is_never_pruned
      result = plan(bases: [base(30, "000000010000000000000002")],
                    wals: [seg("000000010000000000000001")])

      assert_empty result.bases, "the only base is always kept"
      # WAL before that base's start is still prunable (nothing needs it).
      assert_equal %w[000000010000000000000001], result.wals.map(&:segment)
    end

    def test_an_anchor_without_a_start_segment_disables_wal_pruning
      # A base captured before start-segment recording (or that couldn't read it)
      # must not drive WAL pruning — fail toward keeping the chain.
      anchor = base(10, nil)
      result = plan(bases: [base(20, "000000010000000000000005"), anchor],
                    wals: [seg("000000010000000000000001")])

      assert_predicate result, :empty?
    end

    def test_surviving_bases_never_need_deleted_wal
      bases = [base(20, "000000010000000000000005"),
               base(10, "000000010000000000000010"),
               base(3, "000000010000000000000030")]
      wals = (1..40).map { |i| seg(format("0000000100000000000000%02X", i)) }

      result = plan(bases: bases, wals: wals)
      kept_bases = bases - result.bases
      kept_wals = (wals - result.wals).map(&:segment)
      floor = kept_bases.map(&:start_segment).min

      assert(kept_wals.all? { |s| s >= floor }, "no kept WAL is below the earliest kept base's start")
      assert(kept_bases.any? { |b| b.timestamp <= NOW - WEEK }, "a kept base still reaches the window edge")
    end
  end
end
