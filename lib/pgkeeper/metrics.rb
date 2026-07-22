# frozen_string_literal: true

require "time"
require "fileutils"
require "tempfile"

module PgKeeper
  # Renders backup state as Prometheus text-exposition metrics, so a scrape (or
  # the node_exporter textfile collector) can alarm on the things that actually
  # matter operationally: "no successful backup in 26 hours", "last dump was
  # 0 bytes", "last run failed". It reads the same SQLite run-history the CLI and
  # dashboard read — no second data path.
  #
  # Two ways to consume it:
  #   * +pgkeeper metrics+ prints the exposition (or +--output FILE+ writes a
  #     textfile-collector file atomically), for a pull with no web server, and
  #   * the dashboard's +/metrics+ route serves the same text behind its auth.
  module Metrics
    CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

    Metric = Struct.new(:name, :help, :type)

    SERIES = [
      Metric.new("pgkeeper_last_run_timestamp_seconds", "Unix time of the last recorded run.", "gauge"),
      Metric.new("pgkeeper_last_success_timestamp_seconds", "Unix time of the last successful run.", "gauge"),
      Metric.new("pgkeeper_last_run_success", "Whether the last run succeeded (1) or not (0).", "gauge"),
      Metric.new("pgkeeper_last_backup_size_bytes", "Total artifact bytes of the last run.", "gauge"),
      Metric.new("pgkeeper_last_run_duration_seconds", "Duration of the last run.", "gauge")
    ].freeze

    module_function

    # Return the full exposition text for +config+.
    def render(config, logger: PgKeeper.logger)
      history = History.new(File.join(config.workdir, "history.sqlite3"), logger: logger)
      last = index_by_database(history.last_per_database)
      success = index_by_database(history.last_success_per_database)

      out = []
      out.concat(up_metric)
      SERIES.each { |m| out.concat(series(m, config, last, success)) }
      "#{out.join("\n")}\n"
    end

    # Write the exposition to +path+ atomically (tmp file + rename), so a
    # concurrently-scraping node_exporter never reads a half-written file.
    def write_textfile(text, path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = Tempfile.create(["pgkeeper-metrics-", ".prom"], dir)
      tmp.write(text)
      tmp.close
      File.rename(tmp.path, path)
    ensure
      File.unlink(tmp.path) if tmp && File.exist?(tmp.path)
    end

    # -- internals ---------------------------------------------------------

    def index_by_database(rows)
      rows.to_h { |row| [row.database, row] }
    end

    def up_metric
      ["# HELP pgkeeper_up Whether the pgkeeper metrics renderer is responding.",
       "# TYPE pgkeeper_up gauge",
       "pgkeeper_up 1"]
    end

    def series(metric, config, last, success)
      lines = ["# HELP #{metric.name} #{metric.help}", "# TYPE #{metric.name} #{metric.type}"]
      config.databases.each do |db|
        value = value_for(metric.name, last[db.name], success[db.name])
        next if value.nil?

        lines << %(#{metric.name}{database="#{escape_label(db.name)}"} #{value})
      end
      lines
    end

    # value(last_run_row, last_success_row) -> number or nil (nil = omit series).
    VALUE_FNS = {
      "pgkeeper_last_run_timestamp_seconds" => ->(last, _s) { unix(last&.started_at) },
      "pgkeeper_last_success_timestamp_seconds" => ->(_last, s) { unix(s&.started_at) },
      "pgkeeper_last_run_success" => ->(last, _s) { last && (last.success? ? 1 : 0) },
      "pgkeeper_last_backup_size_bytes" => ->(last, _s) { last&.total_bytes&.to_i },
      "pgkeeper_last_run_duration_seconds" => ->(last, _s) { last&.duration_seconds }
    }.freeze

    def value_for(name, last_row, success_row)
      VALUE_FNS.fetch(name).call(last_row, success_row)
    end

    def unix(iso)
      return nil if iso.nil?

      Time.iso8601(iso).to_i
    rescue ArgumentError, TypeError
      nil
    end

    # Prometheus label-value escaping: backslash, double-quote, newline.
    def escape_label(value)
      value.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", '\\n')
    end
  end
end
