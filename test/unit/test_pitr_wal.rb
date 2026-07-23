# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestPitrWal < Minitest::Test
    include TestHelpers

    def test_maps_an_lsn_to_its_segment_name
      # 16 MiB segments: LSN 0/8000028 on timeline 1 lives in segment ...0008.
      assert_equal "000000010000000000000008", PITR::Wal.lsn_to_segment("0/8000028", 1)
      assert_equal "000000020000000100000002", PITR::Wal.lsn_to_segment("1/2000000", 2)
    end

    def test_returns_nil_for_missing_or_malformed_input
      assert_nil PITR::Wal.lsn_to_segment(nil, 1)
      assert_nil PITR::Wal.lsn_to_segment("0/8000028", nil)
      assert_nil PITR::Wal.lsn_to_segment("not-an-lsn", 1)
    end

    def test_next_segment_increments_and_rolls_over_into_the_next_log
      assert_equal "000000010000000000000009", PITR::Wal.next_segment("000000010000000000000008")
      # ...000000FF is the last segment in a log; the next rolls the log over.
      assert_equal "000000010000000100000000", PITR::Wal.next_segment("0000000100000000000000FF")
      assert_nil PITR::Wal.next_segment("nope")
    end
  end
end
