# frozen_string_literal: true

module PgKeeper
  module PITR
    # WAL segment-name arithmetic, shared by the base backup (recording where a
    # base's recovery begins), the archiver, and retention.
    #
    # A segment file name is 24 uppercase hex chars — timeline(8) + LSN-high(8) +
    # segment-within-log(8) — for the default 16 MiB segment size. Because the
    # name encodes position, plain lexicographic order is chronological order.
    module Wal
      module_function

      SEGMENT_SIZE_BITS = 24 # 16 MiB == 2**24 bytes per segment

      # Map an LSN ("hi/lo", hex) on a timeline to its containing segment name,
      # or nil when either input is missing or malformed.
      def lsn_to_segment(lsn, timeline)
        return nil if lsn.nil? || timeline.nil?

        high, low = lsn.to_s.split("/", 2)
        format("%<tl>08X%<hi>08X%<seg>08X",
               tl: Integer(timeline), hi: Integer(high, 16), seg: Integer(low, 16) >> SEGMENT_SIZE_BITS)
      rescue ArgumentError, TypeError
        nil
      end

      # An LSN ("hi/lo", hex) as a single comparable integer, or nil if malformed.
      def lsn_to_int(lsn)
        return nil if lsn.nil?

        high, low = lsn.to_s.split("/", 2)
        (Integer(high, 16) << 32) | Integer(low, 16)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
