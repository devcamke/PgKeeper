# frozen_string_literal: true

require "cgi"
require "time"

module PgKeeper
  module Web
    # Formatting helpers shared by every ERB view. Everything dynamic goes
    # through {#h} — no credential or user-controlled string is ever rendered
    # raw.
    module ViewHelpers
      UNITS = %w[B KB MB GB TB].freeze

      def h(value)
        CGI.escapeHTML(value.to_s)
      end

      # URL-escape a query-string value.
      def u(value)
        CGI.escape(value.to_s)
      end

      def human_size(bytes)
        return "-" if bytes.nil?

        size = bytes.to_f
        unit = 0
        while size >= 1024 && unit < UNITS.length - 1
          size /= 1024
          unit += 1
        end
        format("%<n>.1f%<u>s", n: size, u: UNITS[unit])
      end

      # Age like "3h ago" from a Time or an ISO-8601 string.
      def human_age(time)
        time = Time.iso8601(time) if time.is_a?(String)
        return "never" if time.nil?

        seconds = (Time.now - time).to_i
        return "#{seconds}s ago" if seconds < 60
        return "#{seconds / 60}m ago" if seconds < 3600
        return "#{seconds / 3600}h ago" if seconds < 86_400

        "#{seconds / 86_400}d ago"
      rescue ArgumentError, TypeError
        "?"
      end

      def fmt_time(time)
        time = Time.iso8601(time) if time.is_a?(String)
        time&.utc&.strftime("%Y-%m-%d %H:%M:%SZ") || "-"
      rescue ArgumentError, TypeError
        "?"
      end

      # A colored status dot with an accessible label.
      def light_dot(color)
        %(<span class="dot dot-#{h(color)}" title="#{h(color)}"></span>)
      end

      def status_class(status)
        { "success" => "ok", "partial" => "warn", "failure" => "bad" }.fetch(status.to_s, "")
      end

      # A tinted status pill. `cls` is one of "ok"/"warn"/"bad" (or ""); the
      # inner text is escaped.
      def pill(text, cls)
        klass = cls.to_s.empty? ? "pill" : "pill #{h(cls)}"
        %(<span class="#{klass}">#{h(text)}</span>)
      end

      # Pill for a run/job status string, colored by its severity.
      def status_pill(status)
        pill(status, status_class(status))
      end

      # Inline SVG sparkline of artifact sizes — surfaces the "dump suddenly
      # 60% smaller" anomaly visually. Values are chronological.
      def sparkline(values, width: 120, height: 24)
        values = Array(values).map(&:to_i)
        return "" if values.length < 2

        max = [values.max, 1].max
        step = width.to_f / (values.length - 1)
        points = values.each_with_index.map do |v, i|
          "#{(i * step).round(1)},#{(height - 2 - ((v.to_f / max) * (height - 4))).round(1)}"
        end
        %(<svg class="spark" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">) +
          %(<polyline fill="none" stroke="currentColor" stroke-width="1.5" points="#{points.join(' ')}"/></svg>)
      end
    end
  end
end
