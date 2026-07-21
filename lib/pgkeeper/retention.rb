# frozen_string_literal: true

require "time"

module PgKeeper
  # Retention policy: decides which backups to keep and which to prune.
  #
  # Two policy styles, which may be combined:
  #   * +keep_last: N+ — keep the N most recent backups.
  #   * GFS (grandfather-father-son) — keep the newest backup within each of the
  #     most recent +keep_daily+ days, +keep_weekly+ ISO weeks, +keep_monthly+
  #     months, and +keep_yearly+ years.
  #
  # A backup is kept if *any* rule selects it (the union). On top of the policy,
  # hard safety rails always apply: the most recent backup is never deleted, a
  # policy can never prune everything to zero, and — when a verified backup
  # exists — nothing newer than it is deleted (don't discard your safety margin
  # of not-yet-verified recent backups).
  #
  # {#partition} operates on any objects that respond to +#timestamp+ (a Time);
  # callers pass backup sets and get back which to keep and which to delete.
  module Retention
    KEYS = %w[keep_last keep_daily keep_weekly keep_monthly keep_yearly].freeze

    module_function

    def build(config)
      config ||= {}
      Policy.new(
        keep_last: config["keep_last"],
        keep_daily: config["keep_daily"],
        keep_weekly: config["keep_weekly"],
        keep_monthly: config["keep_monthly"],
        keep_yearly: config["keep_yearly"]
      )
    end

    # The keep/delete split for one set of backups.
    Plan = Struct.new(:keep, :delete, keyword_init: true)

    class Policy
      Period = Struct.new(:keep, :bucket, keyword_init: true)

      def initialize(keep_last: nil, keep_daily: nil, keep_weekly: nil, keep_monthly: nil, keep_yearly: nil)
        @keep_last = keep_last
        @periods = [
          Period.new(keep: keep_daily, bucket: ->(t) { t.strftime("%Y-%m-%d") }),
          Period.new(keep: keep_weekly, bucket: ->(t) { t.strftime("%G-W%V") }),
          Period.new(keep: keep_monthly, bucket: ->(t) { t.strftime("%Y-%m") }),
          Period.new(keep: keep_yearly, bucket: ->(t) { t.strftime("%Y") })
        ]
      end

      # Whether any rule is configured. An unconfigured policy keeps everything.
      def configured?
        !@keep_last.nil? || @periods.any? { |p| !p.keep.nil? && p.keep.positive? }
      end

      # Split +sets+ into keep/delete. +protected_after+ (a Time) force-keeps any
      # set newer than it — used to protect backups newer than the last verified
      # one.
      def partition(sets, protected_after: nil)
        return Plan.new(keep: sets.dup, delete: []) unless configured? && !sets.empty?

        by_time = sets.sort_by(&:timestamp)
        descending = by_time.reverse

        keep = Set.new
        keep.merge(descending.first(@keep_last)) if @keep_last
        @periods.each { |period| keep.merge(select_period(descending, period)) }
        keep << by_time.last # rail: never delete the most recent backup
        keep.merge(by_time.select { |s| protected_after && s.timestamp > protected_after })

        Plan.new(
          keep: by_time.select { |s| keep.include?(s) },
          delete: by_time.reject { |s| keep.include?(s) }
        )
      end

      private

      # The newest set within each of the most recent +keep+ buckets.
      def select_period(descending, period)
        return [] if period.keep.nil? || period.keep.zero?

        seen = {}
        descending.each do |set|
          key = period.bucket.call(set.timestamp)
          next if seen.key?(key)
          break if seen.size >= period.keep

          seen[key] = set
        end
        seen.values
      end
    end
  end
end
