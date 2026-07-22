# frozen_string_literal: true

module PgKeeper
  # Long-running scheduler for container deployments where cron/systemd aren't
  # available. It computes each schedule's next fire time, sleeps until the
  # soonest, runs the due backups (isolated so one failure doesn't stop the
  # loop), and repeats.
  #
  # The clock, sleeper, and runner are injectable so the tick loop can be driven
  # deterministically in tests with a fake clock instead of real time.
  class Daemon
    def initialize(config, logger: PgKeeper.logger, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) },
                   runner: nil, jitter: 0)
      @config = config
      @logger = logger
      @clock = clock
      @sleeper = sleeper
      @jitter = jitter
      @entries = Scheduler.entries(config)
      @runner = runner || method(:run_backup)
    end

    attr_reader :entries

    # Run the scheduler loop. +max_ticks+ bounds the number of iterations (tests
    # pass a finite value; production leaves it nil to run forever). Returns the
    # count of fires performed.
    def run(max_ticks: nil)
      raise Error, "no schedules configured; set `schedule:` in your config" if @entries.empty?

      schedule = @entries.to_h { |entry| [entry, entry.schedule.next_time(from: now)] }
      @logger.info("daemon started", schedules: @entries.length)

      fires = 0
      ticks = 0
      until max_ticks && ticks >= max_ticks
        ticks += 1
        sleep_until(schedule.values.min)
        fires += fire_due(schedule)
      end
      fires
    end

    private

    def now = @clock.call

    def sleep_until(target)
      delay = target - now
      delay += rand * @jitter if @jitter.positive?
      @sleeper.call(delay) if delay.positive?
    end

    def fire_due(schedule)
      fired = 0
      schedule.each do |entry, at|
        next if at > now

        run_entry(entry)
        fired += 1
        # Advance past the current second so the same tick isn't re-fired.
        schedule[entry] = entry.schedule.next_time(from: now + 1)
      end
      fired
    end

    def run_entry(entry)
      @logger.info("scheduled run firing", schedule: entry.label)
      @runner.call(entry)
    rescue StandardError => e
      @logger.error("scheduled run failed (non-fatal to daemon)", schedule: entry.label, error: e.message)
    end

    def run_backup(entry)
      Orchestrator.new(@config, logger: @logger).run(only: entry.only)
    end
  end
end
