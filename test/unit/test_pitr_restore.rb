# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Base selection for a PITR target (pure). Materialization + recovery staging
  # are exercised end-to-end against a live server in the integration suite.
  class TestPitrRestore < Minitest::Test
    include TestHelpers

    Base = Struct.new(:timestamp, :start_lsn, :remote_path, :finished_at, :end_lsn, keyword_init: true)

    T0 = Time.utc(2026, 7, 20, 0, 0, 0)
    HOUR = 3600

    def base(days, lsn, finished_at: nil, end_lsn: nil)
      Base.new(timestamp: T0 + (days * 86_400), start_lsn: lsn, remote_path: "base/#{days}",
               finished_at: finished_at, end_lsn: end_lsn)
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

    # Recovery can only stop at points after the backup's consistency point
    # (its finish); a base that merely *started* before the target may still
    # overshoot it, and Postgres refuses to stop before consistency.
    def test_time_target_inside_a_backup_window_falls_back_to_the_previous_base
      long = base(2, "0/5000000", finished_at: T0 + (2 * 86_400) + (2 * HOUR)) # runs 02:00h
      pairs = [[nil, base(0, "0/1000000", finished_at: T0 + HOUR)], [nil, long]]

      chosen = PITR::Restore.pick(pairs, target(:time, T0 + (2 * 86_400) + HOUR))&.last

      assert_equal "0/1000000", chosen.start_lsn, "target falls inside the newer backup's start–finish window"
      # at/after the consistency point, the newer base is eligible again
      assert_equal "0/5000000",
                   PITR::Restore.pick(pairs, target(:time, T0 + (2 * 86_400) + (2 * HOUR))).last.start_lsn
    end

    def test_lsn_target_inside_a_backup_window_falls_back_to_the_previous_base
      pairs = [[nil, base(0, "0/1000000", end_lsn: "0/2000000")],
               [nil, base(2, "0/5000000", end_lsn: "0/7000000")]]

      chosen = PITR::Restore.pick(pairs, target(:lsn, "0/6000000"))&.last

      assert_equal "0/1000000", chosen.start_lsn, "LSN between the newer base's start and end LSN"
    end

    def test_legacy_bases_without_a_recorded_finish_still_select_by_start
      # Manifests written before end_lsn/finished_at existed keep the old
      # (start-based) behavior instead of becoming unselectable.
      assert_equal "0/5000000", pick(target(:time, T0 + (3 * 86_400))).start_lsn
    end

    # Postgres runs restore_command with the data directory as CWD, so a
    # relative config path would never resolve there — every fetch would fail,
    # which recovery treats as end-of-WAL and silently promotes at the base.
    def test_write_recovery_bakes_an_absolute_config_path
      in_tmpdir do |dir|
        cfg = Config.parse(
          "workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/s\n" \
          "clusters:\n  - name: c1\n    host: h\n    pitr: { enabled: true }\n",
          source: "pgkeeper.yml"
        )
        restore = PITR::Restore.new(cfg, cfg.pitr_clusters.first, logger: null_logger)

        restore.send(:write_recovery, dir, target(:latest, nil), "promote", "pgkeeper")

        conf = File.read(File.join(dir, "postgresql.auto.conf"))

        assert_includes conf, "--config #{File.expand_path('pgkeeper.yml')}"
        assert_path_exists File.join(dir, "recovery.signal")
      end
    end
  end
end
