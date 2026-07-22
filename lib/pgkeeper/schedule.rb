# frozen_string_literal: true

require "fugit"

module PgKeeper
  # A parsed backup schedule. Accepts raw 5-field cron, fugit's natural language
  # ("every day at 03:15", "every monday at 9am", "every 15 minutes"), and a few
  # friendly shorthands ("hourly", "daily at 03:15", "weekly on sunday at
  # 04:00"). Everything normalizes to a cron expression, which drives both the
  # installers (cron / systemd) and the in-process {Daemon}.
  class Schedule
    # Bare shorthands → cron.
    WORDS = {
      "hourly" => "0 * * * *",
      "daily" => "0 0 * * *",
      "nightly" => "0 0 * * *",
      "weekly" => "0 0 * * 0",
      "monthly" => "0 0 1 * *",
      "yearly" => "0 0 1 1 *",
      "annually" => "0 0 1 1 *"
    }.freeze

    attr_reader :expression, :cron

    def initialize(expression)
      @expression = expression.to_s.strip
      @cron = parse!(@expression)
    end

    def self.parse(expression) = new(expression)

    # Normalized 5-field cron string.
    def to_cron
      @cron.to_cron_s
    end
    alias to_s to_cron

    # Next fire time at or after +from+, as a Ruby Time.
    def next_time(from: Time.now)
      @cron.next_time(from).to_t
    end

    # A human description of the cadence.
    def summary
      "#{@expression} (cron: #{to_cron})"
    end

    private

    def parse!(expr)
      raise ConfigError, "empty schedule expression" if expr.empty?

      normalized = normalize(expr)
      parsed = Fugit.parse(normalized)
      return parsed if parsed.is_a?(Fugit::Cron)

      raise ConfigError,
            "unrecognized schedule #{expr.inspect} — use cron (\"15 3 * * *\") or " \
            "a phrase like \"daily at 03:15\" / \"every monday at 9am\""
    end

    def normalize(expr)
      lower = expr.downcase
      return WORDS[lower] if WORDS.key?(lower)

      if (m = lower.match(/\Adaily at (\d{1,2}:\d{2})\z/))
        "every day at #{m[1]}"
      elsif (m = lower.match(/\Aweekly on (\w+) at (\d{1,2}:\d{2})\z/))
        "every #{m[1]} at #{m[2]}"
      else
        expr
      end
    end
  end
end
