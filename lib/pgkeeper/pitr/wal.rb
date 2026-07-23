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

      # The segment immediately following +name+ on the same timeline, or nil if
      # +name+ isn't a segment. With 16 MiB segments there are 256 (0x00..0xFF)
      # per logical log file, so the segment number rolls over into the next log.
      def next_segment(name)
        m = name.to_s.match(/\A([0-9A-F]{8})([0-9A-F]{8})([0-9A-F]{8})\z/)
        return nil unless m

        timeline = m[1]
        log = m[2].to_i(16)
        seg = m[3].to_i(16) + 1
        if seg > 0xFF
          seg = 0
          log += 1
        end
        format("%<tl>s%<log>08X%<seg>08X", tl: timeline, log: log, seg: seg)
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
