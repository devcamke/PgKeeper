# frozen_string_literal: true

module PgKeeper
  module PITR
    # Coupled base + WAL retention (Phase 12, Stage 3).
    #
    # A base backup and the WAL needed to recover *from* it are one unit. Pruning
    # must never strand a base or break a recovery chain, and must never shrink
    # the reachable recovery horizon below the configured recovery window.
    #
    # This is a pure planner: given a cluster's cataloged base backups and WAL
    # artifacts, the recovery window (seconds), and the current time, it returns
    # exactly which artifacts are safe to delete. No I/O — the {Pruner} deletes.
    #
    # The rule:
    #   * The *anchor* is the newest base at or before `now - window` — the base
    #     that lets you still recover to the far edge of the window.
    #   * Keep the anchor and every newer base; delete bases older than it (they
    #     sit entirely before the window).
    #   * The WAL floor is the anchor's start segment: keep every WAL segment
    #     from there forward (any recovery point in the window replays from the
    #     anchor or a newer base); delete WAL older than the floor.
    #
    # Safety: with no window configured, no base old enough to reach the window,
    # or an anchor missing its start segment, nothing is pruned — always fail
    # toward keeping the chain intact.
    module Retention
      Plan = Struct.new(:bases, :wals, keyword_init: true) do
        def empty? = bases.empty? && wals.empty?
      end

      module_function

      def plan(bases:, wals:, window_seconds:, now:)
        keep_all = Plan.new(bases: [], wals: [])
        return keep_all if window_seconds.nil? || bases.empty?

        sorted = bases.sort_by(&:timestamp)
        anchor = sorted.select { |base| base.timestamp <= now - window_seconds }.last
        # Nothing old enough to cover the window yet, or the anchor can't tell us
        # where its WAL begins: keep everything.
        return keep_all if anchor.nil? || anchor.start_segment.nil?

        Plan.new(
          bases: sorted.select { |base| base.timestamp < anchor.timestamp },
          wals: wals.select { |wal| wal.segment && wal.segment < anchor.start_segment }
        )
      end
    end
  end
end
