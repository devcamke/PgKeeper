# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Base selection for a PITR target (pure). Materialization + recovery staging
  # are exercised end-to-end against a live server in the integration suite.
  class TestPitrRestore < Minitest::Test
    include TestHelpers

    Base = Struct.new(:timestamp, :start_lsn, :remote_path, keyword_init: true)

    T0 = Time.utc(2026, 7, 20, 0, 0, 0)

    def base(days, lsn)
      Base.new(timestamp: T0 + (days * 86_400), start_lsn: lsn, remote_path: "base/#{days}")
    end

    # [adapter, base] pairs; the adapter is irrelevant to selection, so nil.
    def candidates
      [[nil, base(0, "0/1000000")], [nil, base(2, "0/5000000")], [nil, base(4, "0/9000000")]]
    end

    def target(type, value) = PITR::Restore::Target.new(type: type, value: value)

    def pick(tgt) = PITR::Restore.pick(candidates, tgt)&.last

    def test_time_target_picks_the_newest_base_at_or_before_it
      assert_equal 2, pick(target(:time, T0 + (3 * 86_400))).timestamp.yday - T0.yday
      # exactly on a base timestamp still selects it
      assert_equal "0/5000000", pick(target(:time, T0 + (2 * 86_400))).start_lsn
    end

    def test_time_target_before_every_base_selects_nothing
      assert_nil pick(target(:time, T0 - 3600))
    end

    def test_lsn_target_picks_the_newest_base_at_or_before_the_lsn
      assert_equal "0/5000000", pick(target(:lsn, "0/8000000")).start_lsn
      assert_equal "0/9000000", pick(target(:lsn, "0/9000000")).start_lsn
    end

    def test_latest_and_name_pick_the_newest_base
      assert_equal "0/9000000", pick(target(:latest, nil)).start_lsn
      assert_equal "0/9000000", pick(target(:name, "before_upgrade")).start_lsn
    end

    def test_target_describe
      assert_equal "the latest archived WAL", target(:latest, nil).describe
      assert_includes target(:lsn, "0/9000000").describe, "0/9000000"
    end
  end
end
