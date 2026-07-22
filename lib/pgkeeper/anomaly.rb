# frozen_string_literal: true

module PgKeeper
  # Backup-size anomaly detection.
  #
  # A dump that is suddenly far smaller than its recent history is the classic
  # symptom of a silently broken backup: a table got dropped, an +exclude_tables+
  # rule went wrong, a migration truncated data, or the dump captured a
  # half-restored database. The run still "succeeds" — pg_dump exits 0 — so
  # nothing else catches it. This compares each database's fresh dump size
  # against a baseline drawn from its recent successful runs and, when it moves
  # too far, produces a {Finding} the orchestrator logs loudly and attaches to
  # the run's notification.
  #
  # The baseline is the *median* of the last N successful sizes, so a single
  # outlier (one unusually large or small prior run) doesn't skew the judgment.
  module Anomaly
    Finding = Struct.new(:database, :current_bytes, :baseline_bytes, :direction, :threshold_pct,
                         keyword_init: true) do
      # Percentage change from baseline (negative = shrank).
      def change_pct
        return 0 if baseline_bytes.zero?

        (((current_bytes - baseline_bytes).to_f / baseline_bytes) * 100).round
      end

      def message
        verb = direction == :shrink ? "shrank" : "grew"
        "backup #{verb} #{change_pct.abs}% vs recent median " \
          "(#{format_bytes(current_bytes)} now, #{format_bytes(baseline_bytes)} typical) — " \
          "possible data loss or a broken dump; investigate before relying on it"
      end

      def to_log
        { current_bytes: current_bytes, baseline_bytes: baseline_bytes,
          change_pct: change_pct, direction: direction }
      end

      def format_bytes(bytes)
        units = %w[B KB MB GB TB]
        size = bytes.to_f
        unit = 0
        while size >= 1024 && unit < units.length - 1
          size /= 1024
          unit += 1
        end
        format("%<n>.1f%<u>s", n: size, u: units[unit])
      end
    end

    module_function

    # Judge +current_bytes+ against +baseline_sizes+ (recent successful sizes,
    # newest first is fine — order doesn't matter). Returns a {Finding} or nil.
    #
    # +config+ is the config's +anomaly+ hash (string keys), typically
    # {Config::DEFAULT_ANOMALY} merged with the user's overrides.
    def detect(database:, current_bytes:, baseline_sizes:, config:)
      return nil unless config["enabled"]

      samples = Array(baseline_sizes).select { |b| b.to_i.positive? }.map(&:to_i)
      return nil if samples.length < config["min_samples"].to_i
      return nil if current_bytes.to_i <= 0

      baseline = median(samples.first(config["sample_size"].to_i))
      return nil if baseline.zero?

      finding_for(database, current_bytes.to_i, baseline, config)
    end

    def finding_for(database, current, baseline, config)
      shrink = threshold(config["shrink_pct"])
      grow = threshold(config["grow_pct"])

      if shrink && current < baseline * (1 - shrink)
        build(database, current, baseline, :shrink, config["shrink_pct"])
      elsif grow && current > baseline * (1 + grow)
        build(database, current, baseline, :grow, config["grow_pct"])
      end
    end

    # A percent knob of 0 (or nil) disables that direction.
    def threshold(pct)
      value = pct.to_i
      value.positive? ? value / 100.0 : nil
    end

    def build(database, current, baseline, direction, threshold_pct)
      Finding.new(database: database, current_bytes: current, baseline_bytes: baseline,
                  direction: direction, threshold_pct: threshold_pct)
    end

    def median(values)
      return 0 if values.empty?

      sorted = values.sort
      mid = sorted.length / 2
      if sorted.length.odd?
        sorted[mid]
      else
        ((sorted[mid - 1] + sorted[mid]) / 2.0).round
      end
    end
  end
end
