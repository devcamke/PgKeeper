# frozen_string_literal: true

require "test_helper"
require "time"

module PgKeeper
  class TestDaemon < Minitest::Test
    include TestHelpers

    # A clock the daemon's sleeper advances, so the tick loop runs
    # deterministically without real time passing.
    class FakeClock
      attr_reader :now

      def initialize(start)
        @now = start
      end

      def advance(seconds)
        @now += seconds
      end
    end

    def config(hash)
      Config.new({ "workdir" => "/wd", "storage" => [{ "type" => "local", "path" => "/wd/b" }] }.merge(hash))
    end

    def build_daemon(cfg, clock, runner:, jitter: 0)
      Daemon.new(cfg, logger: null_logger, jitter: jitter,
                      clock: -> { clock.now }, sleeper: ->(s) { clock.advance(s) }, runner: runner)
    end

    def test_fires_each_scheduled_tick
      clock = FakeClock.new(Time.utc(2026, 5, 1, 0, 30, 0))
      fired = []
      daemon = build_daemon(config("schedule" => "hourly", "databases" => [{ "name" => "app" }]),
                            clock, runner: ->(e) { fired << [e.label, clock.now] })

      count = daemon.run(max_ticks: 3)

      assert_equal 3, count
      assert_equal %w[all all all], fired.map(&:first)
      # Fires land on the top of each hour: 01:00, 02:00, 03:00.
      assert_equal([1, 2, 3], fired.map { |(_, t)| t.hour })
      assert(fired.all? { |(_, t)| t.min.zero? })
    end

    def test_per_database_schedules_fire_independently
      clock = FakeClock.new(Time.utc(2026, 5, 1, 0, 0, 0))
      fired = []
      cfg = config(
        "databases" => [
          { "name" => "fast", "schedule" => "hourly" },
          { "name" => "slow", "schedule" => "daily at 00:00" }
        ]
      )
      daemon = build_daemon(cfg, clock, runner: ->(e) { fired << e.label })

      daemon.run(max_ticks: 3)

      # In the first few hours the hourly "fast" db fires every tick; "slow"
      # (daily at midnight) does not fire again until the next day.
      assert_operator fired.count("fast"), :>=, 3
      assert_equal 0, fired.count("slow")
    end

    def test_runner_error_is_non_fatal_to_the_loop
      clock = FakeClock.new(Time.utc(2026, 5, 1, 0, 30, 0))
      calls = 0
      runner = lambda do |_e|
        calls += 1
        raise "boom on first fire" if calls == 1
      end
      daemon = build_daemon(config("schedule" => "hourly", "databases" => [{ "name" => "app" }]),
                            clock, runner: runner)

      count = daemon.run(max_ticks: 3)

      assert_equal 3, count, "loop keeps ticking despite a run raising"
      assert_equal 3, calls
    end

    def test_no_schedule_raises
      daemon = Daemon.new(config("databases" => [{ "name" => "app" }]), logger: null_logger)
      assert_raises(Error) { daemon.run(max_ticks: 1) }
    end

    def test_maintenance_jobs_fire_with_their_action_and_flags
      clock = FakeClock.new(Time.utc(2026, 5, 1, 3, 59, 0))
      fired = []
      cfg = config(
        "databases" => [{ "name" => "app" }],
        "maintenance" => {
          "verify" => { "schedule" => "daily at 04:00", "deep" => true },
          "prune" => { "schedule" => "daily at 05:00", "apply" => true }
        }
      )
      daemon = build_daemon(cfg, clock, runner: ->(e) { fired << [e.action, e.flags] })

      daemon.run(max_ticks: 2)

      assert_includes fired, [:verify, ["--deep"]]
      assert_includes fired, [:prune, ["--apply"]]
    end

    # Wraps a real schedule but raises on the first +failures+ next_time calls —
    # the shape of et-orbi's ArgumentError inside the DST fall-back hour.
    class FlakySchedule
      def initialize(real, failures:)
        @real = real
        @failures = failures
        @calls = 0
      end

      attr_reader :calls

      def next_time(from:)
        @calls += 1
        raise ArgumentError, 'Cannot determine timezone from "EDT"' if @calls <= @failures

        @real.next_time(from: from)
      end
    end

    def test_an_ambiguous_clock_does_not_kill_the_daemon
      clock = FakeClock.new(Time.utc(2026, 5, 1, 0, 30, 0))
      fired = []
      daemon = build_daemon(config("schedule" => "hourly", "databases" => [{ "name" => "app" }]),
                            clock, runner: ->(e) { fired << e.label })
      entry = daemon.entries.first
      entry.schedule = FlakySchedule.new(entry.schedule, failures: 2)

      count = daemon.run(max_ticks: 3)

      assert_equal 3, count, "the loop survives next_time raising and keeps firing"
    end

    def test_sigterm_stops_the_loop_between_jobs
      clock = FakeClock.new(Time.utc(2026, 5, 1, 0, 30, 0))
      sleeps = 0
      daemon = Daemon.new(config("schedule" => "hourly", "databases" => [{ "name" => "app" }]),
                          logger: null_logger, clock: -> { clock.now },
                          sleeper: lambda { |s|
                            sleeps += 1
                            Process.kill("TERM", Process.pid)
                            sleep 0.05 # let the trap handler run
                            clock.advance(s)
                          },
                          runner: ->(_e) {})

      count = daemon.run(max_ticks: 5, handle_signals: true)

      assert_equal 0, count, "the loop exits before firing once stop is requested"
      assert_equal 1, sleeps, "the loop exits right after the interrupted sleep"
    ensure
      Signal.trap("TERM", "DEFAULT")
      Signal.trap("INT", "DEFAULT")
    end

    def test_default_runner_dispatches_on_action
      cfg = config(
        "databases" => [{ "name" => "app" }],
        "maintenance" => { "verify" => { "schedule" => "daily at 04:00" },
                           "prune" => { "schedule" => "daily at 05:00" } },
        "clusters" => [{ "name" => "c1", "host" => "h",
                         "pitr" => { "enabled" => true,
                                     "base_backup" => { "schedule" => "daily at 02:00" } } }]
      )
      daemon = Daemon.new(cfg, logger: null_logger)
      seen = []
      # Stand in for the heavyweight collaborators so we assert *dispatch* only.
      daemon.define_singleton_method(:run_backup) { |e| seen << [:backup, e.action] }
      daemon.define_singleton_method(:run_verify) { |e| seen << [:verify, e.action] }
      daemon.define_singleton_method(:run_prune) { |e| seen << [:prune, e.action] }
      daemon.define_singleton_method(:run_basebackup) { |e| seen << [:basebackup, e.action] }

      Scheduler.entries(cfg).each { |e| daemon.send(:run_action, e) }

      assert_equal [%i[basebackup basebackup], %i[verify verify], %i[prune prune]], seen
    end
  end
end
