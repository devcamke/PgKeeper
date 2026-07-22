# frozen_string_literal: true

require "test_helper"
require "time"

module PgKeeper
  class TestSchedule < Minitest::Test
    include TestHelpers

    def test_raw_cron_passes_through
      assert_equal "15 3 * * *", Schedule.parse("15 3 * * *").to_cron
    end

    def test_natural_language_every_day
      assert_equal "15 3 * * *", Schedule.parse("every day at 03:15").to_cron
    end

    def test_shorthand_daily_at
      assert_equal "15 3 * * *", Schedule.parse("daily at 03:15").to_cron
    end

    def test_shorthand_weekly_on
      assert_equal "0 4 * * 0", Schedule.parse("weekly on sunday at 04:00").to_cron
    end

    def test_bare_words
      assert_equal "0 * * * *", Schedule.parse("hourly").to_cron
      assert_equal "0 0 * * *", Schedule.parse("daily").to_cron
      assert_equal "0 0 * * 0", Schedule.parse("weekly").to_cron
      assert_equal "0 0 1 * *", Schedule.parse("monthly").to_cron
    end

    def test_every_monday
      assert_equal "0 9 * * 1", Schedule.parse("every monday at 9am").to_cron
    end

    def test_next_time_is_after_from
      schedule = Schedule.parse("15 3 * * *")
      from = Time.utc(2026, 5, 1, 10, 0, 0)
      nxt = schedule.next_time(from: from)

      assert_operator nxt, :>, from
      assert_equal 3, nxt.hour
      assert_equal 15, nxt.min
    end

    def test_empty_expression_raises
      assert_raises(ConfigError) { Schedule.parse("  ") }
    end

    def test_garbage_expression_raises
      assert_raises(ConfigError) { Schedule.parse("whenever i feel like it") }
    end

    def test_summary_includes_cron
      assert_includes Schedule.parse("hourly").summary, "0 * * * *"
    end
  end
end
