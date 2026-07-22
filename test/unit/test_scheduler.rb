# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestScheduler < Minitest::Test
    include TestHelpers

    def config(hash)
      Config.new({ "workdir" => "/wd", "storage" => [{ "type" => "local", "path" => "/wd/b" }] }.merge(hash))
    end

    # --- entry resolution -------------------------------------------------

    def test_global_schedule_runs_all_databases_in_one_entry
      cfg = config("schedule" => "daily at 03:15", "databases" => [{ "name" => "a" }, { "name" => "b" }])
      entries = Scheduler.entries(cfg)

      assert_equal 1, entries.length
      assert_equal "all", entries.first.label
      assert_nil entries.first.only
      assert_equal "15 3 * * *", entries.first.schedule.to_cron
    end

    def test_per_database_schedule_creates_one_entry_each
      cfg = config(
        "schedule" => "daily at 02:00",
        "databases" => [{ "name" => "a", "schedule" => "hourly" }, { "name" => "b" }]
      )
      entries = Scheduler.entries(cfg).to_h { |e| [e.label, e] }

      assert_equal %w[a b], entries.keys.sort
      assert_equal "0 * * * *", entries["a"].schedule.to_cron, "a uses its own schedule"
      assert_equal "0 2 * * *", entries["b"].schedule.to_cron, "b falls back to the global schedule"
      assert_equal ["a"], entries["a"].only
    end

    def test_no_schedule_yields_no_entries
      assert_empty Scheduler.entries(config("databases" => [{ "name" => "a" }]))
    end

    # --- cron generation (golden) -----------------------------------------

    def test_cron_line_has_flock_guard_and_scope
      cfg = config("schedule" => "daily at 03:15", "databases" => [{ "name" => "app" }])
      cron = Scheduler::Cron.new(Scheduler.entries(cfg), config_path: "/etc/pgkeeper.yml", workdir: "/var/pgk")
      line = cron.lines.first

      assert line.start_with?("15 3 * * * "), "starts with the cron expression"
      assert_includes line, "/usr/bin/flock -n /var/pgk/.cron-all.lock"
      assert_includes line, "pgkeeper backup --config /etc/pgkeeper.yml"
      assert_includes line, ">> /var/pgk/pgkeeper.log 2>&1"
    end

    def test_cron_render_is_marked_and_empty_when_unscheduled
      cfg = config("databases" => [{ "name" => "app" }])

      assert_equal "", Scheduler::Cron.new(Scheduler.entries(cfg), config_path: "/c.yml", workdir: "/w").render
    end

    # --- systemd generation (golden) --------------------------------------

    def test_systemd_units_service_and_timer
      cfg = config("databases" => [{ "name" => "app", "schedule" => "daily at 03:15" }])
      units = Scheduler::Systemd.new(Scheduler.entries(cfg), config_path: "/etc/pgkeeper.yml",
                                                             jitter_seconds: 120).units

      assert_equal %w[pgkeeper-backup-app.service pgkeeper-backup-app.timer], units.keys.sort

      service = units["pgkeeper-backup-app.service"]

      assert_includes service, "Type=oneshot"
      assert_includes service, "ExecStart=pgkeeper backup --config /etc/pgkeeper.yml --only app"

      timer = units["pgkeeper-backup-app.timer"]

      assert_includes timer, "OnCalendar=*-*-* 03:15:00"
      assert_includes timer, "Persistent=true"
      assert_includes timer, "RandomizedDelaySec=120"
      assert_includes timer, "WantedBy=timers.target"
    end

    def test_oncalendar_conversions
      conv = ->(cron) { Scheduler::Systemd::OnCalendar.from_cron(cron) }

      assert_equal "*-*-* 03:15:00", conv.call("15 3 * * *")
      assert_equal "*-*-* *:00:00", conv.call("0 * * * *")
      assert_equal "Mon,Tue,Wed,Thu,Fri *-*-* 03:00:00", conv.call("0 3 * * 1,2,3,4,5")
      assert_equal "Sun *-*-* 04:00:00", conv.call("0 4 * * 0")
    end
  end
end
