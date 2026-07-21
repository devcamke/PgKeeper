# frozen_string_literal: true

require "pgkeeper/notify/base"
require "pgkeeper/notify/email"
require "pgkeeper/notify/webhook"
require "pgkeeper/notify/healthcheck"

module PgKeeper
  # Notifications & reporting. {Notifier} fans a finished run out to every
  # configured backend (email, webhook, dead-man's switch), each firing only for
  # the events it wants and never able to fail the backup itself.
  module Notify
    module_function

    # Build a {Notifier} from the +notifications+ config block.
    def build(config, logger: PgKeeper.logger)
      notifications = config.notifications || {}
      backends = []
      backends << Email.from_config(notifications["email"], logger) if notifications["email"]
      backends << Webhook.from_config(notifications["webhook"], logger) if notifications["webhook"]
      backends << Healthcheck.from_config(notifications["healthcheck"], logger) if notifications["healthcheck"]
      Notifier.new(backends.compact, logger: logger)
    end

    # Immutable snapshot of a finished run, plus rendering to the forms the
    # notifiers need (plain text, HTML, JSON payload).
    class Summary
      UNITS = %w[B KB MB GB TB].freeze

      attr_reader :report, :run_id, :started_at, :finished_at, :hostname

      def initialize(report:, run_id:, started_at:, finished_at:, hostname:)
        @report = report
        @run_id = run_id
        @started_at = started_at
        @finished_at = finished_at
        @hostname = hostname
      end

      # The run's overall event for trigger matching: success only when every
      # database succeeded and reached every destination.
      def event
        report.exit_code == ExitCode::SUCCESS ? :success : :failure
      end

      def success? = event == :success

      def subject
        "PgKeeper backup #{event.to_s.upcase} on #{hostname} " \
          "(#{report.succeeded.length} ok, #{report.partial.length} partial, #{report.failed.length} failed)"
      end

      def to_text
        lines = [subject, "run: #{run_id}", "started: #{started_at.iso8601}  finished: #{finished_at.iso8601}", ""]
        report.results.each { |r| lines.concat(text_lines_for(r)) }
        lines.join("\n")
      end

      def to_html
        rows = report.results.map { |r| html_row_for(r) }.join
        <<~HTML
          <h2>#{subject}</h2>
          <p>run <code>#{run_id}</code><br>
          started #{started_at.iso8601} &middot; finished #{finished_at.iso8601}</p>
          <table border="1" cellpadding="6" cellspacing="0">
            <tr><th>Database</th><th>Status</th><th>Duration</th><th>Artifacts</th><th>Detail</th></tr>
            #{rows}
          </table>
        HTML
      end

      def to_payload
        {
          "event" => event.to_s, "run_id" => run_id, "hostname" => hostname,
          "started_at" => started_at.iso8601, "finished_at" => finished_at.iso8601,
          "summary" => { "succeeded" => report.succeeded.length,
                         "partial" => report.partial.length,
                         "failed" => report.failed.length },
          "databases" => report.results.map { |r| database_payload(r) }
        }
      end

      def format_bytes(bytes)
        return "?" if bytes.nil?

        size = bytes.to_f
        unit = 0
        while size >= 1024 && unit < UNITS.length - 1
          size /= 1024
          unit += 1
        end
        format("%<n>.1f%<u>s", n: size, u: UNITS[unit])
      end

      private

      def text_lines_for(result)
        header = "[#{result.status}] #{result.database} (#{result.duration_seconds}s)"
        return [header, "    error: #{result.error&.message}", ""] if result.failure?

        lines = [header]
        result.artifacts.each do |a|
          dests = a[:destinations].map { |d| "#{d.name}=#{d.status}" }.join(", ")
          lines << "    #{a[:kind]} #{format_bytes(a[:size_bytes])} [#{pipeline(a)}] → #{dests}"
        end
        lines << ""
        lines
      end

      def html_row_for(result)
        detail = result.failure? ? escape(result.error&.message.to_s) : artifact_detail(result)
        "<tr><td>#{escape(result.database)}</td><td>#{result.status}</td>" \
          "<td>#{result.duration_seconds}s</td><td>#{result.artifacts.length}</td><td>#{detail}</td></tr>"
      end

      def artifact_detail(result)
        result.artifacts.map do |a|
          "#{a[:kind]} #{format_bytes(a[:size_bytes])} [#{pipeline(a)}]"
        end.join("<br>")
      end

      def database_payload(result)
        {
          "database" => result.database, "status" => result.status.to_s,
          "duration_seconds" => result.duration_seconds,
          "error" => result.error&.message,
          "artifacts" => result.artifacts.map do |a|
            { "kind" => a[:kind], "size_bytes" => a[:size_bytes],
              "compression" => a[:compression], "encryption" => a[:encryption],
              "destinations" => a[:destinations].map { |d| { "name" => d.name, "status" => d.status.to_s } } }
          end
        }
      end

      def pipeline(artifact)
        [artifact[:compression], artifact[:encryption]].reject { |x| x == "none" }.join("+").then do |p|
          p.empty? ? "raw" : p
        end
      end

      def escape(str)
        str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end

    # Fans a {Summary} out to each backend, isolating failures.
    class Notifier
      attr_reader :backends

      def initialize(backends, logger: PgKeeper.logger)
        @backends = backends
        @logger = logger
      end

      def dispatch(summary)
        @backends.map { |backend| backend.notify(summary) }
      end

      def any?
        !@backends.empty?
      end
    end
  end
end
