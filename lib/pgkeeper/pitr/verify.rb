# frozen_string_literal: true

module PgKeeper
  module PITR
    # Verify a cluster's recovery chain: from the newest base backup's start
    # segment, is the archived WAL an unbroken run forward? A gap — a segment
    # that was never archived, or lost — silently caps how far a restore can
    # replay, and is only discovered at recovery time unless something looks.
    # This looks, ahead of time. (Phase 12, Stage 5.)
    #
    # This is the offline, portable core of `verify --pitr`: it needs only the
    # catalog, no scratch server. The deep scratch-restore-and-replay reuses the
    # Stage 4 restore path and is an operator/CI step; the chain check is what
    # makes "a base whose WAL chain has a gap fails" hold on every host.
    class Verify
      Gap = Struct.new(:after, :missing, keyword_init: true)

      Result = Struct.new(:cluster, :ok, :detail, :base_label, :from_segment, :to_segment,
                          :segment_count, :gap, keyword_init: true) do
        def ok? = ok
      end

      def initialize(config, cluster, logger: PgKeeper.logger)
        @config = config
        @cluster = cluster
        @logger = logger
        @adapters = Storage.build_all(@config.storage, logger: @logger)
      end

      def verify
        base = latest_base
        return result(false, "no base backup found") if base.nil?
        return result(false, "base #{base_label(base)} has no recorded start segment", base) if base.start_segment.nil?

        chain = archived_segments.select { |seg| seg >= base.start_segment }
        return result(false, "no archived WAL at or after the base start #{base.start_segment}", base) if chain.empty?

        # A gap at the head is a gap like any other: recovery replays from the
        # base's start segment, so a chain that begins later can't be reached.
        unless chain.first == base.start_segment
          gap = Gap.new(after: base.start_segment, missing: base.start_segment)
          return result(false, "WAL chain does not start at the base's start segment " \
                               "#{base.start_segment} (first archived: #{chain.first})", base, chain, gap)
        end

        assess(base, chain)
      end

      private

      def assess(base, chain)
        gap = first_gap(chain)
        if gap
          result(false, "WAL gap after #{gap.after} (missing #{gap.missing})", base, chain, gap)
        else
          result(true, "recovery chain intact: #{chain.length} segment(s)", base, chain)
        end
      end

      # The first break in the contiguous run: a segment whose successor isn't the
      # next archived segment. Timeline switches are out of scope here — the chain
      # is checked on the base's timeline, the common single-timeline case.
      def first_gap(chain)
        timeline = chain.first[0, 8]
        same_line = chain.select { |seg| seg[0, 8] == timeline }
        same_line.each_cons(2) do |current, following|
          expected = Wal.next_segment(current)
          return Gap.new(after: current, missing: expected) unless expected == following
        end
        nil
      end

      def latest_base
        Inventory.bases(discover).max_by(&:timestamp)
      end

      # Plain segments only: archived timeline-history / backup-history files
      # ride the same WAL conveyor but are not links in the replay chain.
      def archived_segments
        Inventory.wal(discover).filter_map(&:segment).grep(WalArchiver::SEGMENT).uniq.sort
      end

      # Cataloged artifacts for this cluster across destinations, deduped by path.
      def discover
        @discover ||= Inventory.artifacts(@cluster, @adapters)
      end

      def result(passed, detail, base = nil, chain = nil, gap = nil)
        Result.new(cluster: @cluster.name, ok: passed, detail: detail, base_label: base && base_label(base),
                   from_segment: base&.start_segment, to_segment: chain&.last,
                   segment_count: chain&.length, gap: gap)
      end

      def base_label(base) = base.timestamp&.strftime("%Y-%m-%dT%H%M%SZ") || File.basename(base.remote_path)
    end
  end
end
