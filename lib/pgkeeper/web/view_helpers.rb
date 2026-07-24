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

      # A compact duration like "5m", "3h", "7d" — for spans (lag, window) rather
      # than a moment in the past ({#human_age} adds "ago").
      def human_duration(seconds)
        return "-" if seconds.nil?
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end

      def fmt_time(time)
        time = Time.iso8601(time) if time.is_a?(String)
        time&.utc&.strftime("%Y-%m-%d %H:%M:%SZ") || "-"
      rescue ArgumentError, TypeError
        "?"
      end

      # Default human labels for a traffic-light color, shown in the dot's
      # tooltip so hovering explains what the color means.
      LIGHT_LABELS = { "green" => "Healthy", "yellow" => "Needs attention", "red" => "Failing" }.freeze

      # A colored status dot with a branded tooltip. +label+ overrides the
      # default word for the color.
      def light_dot(color, label = nil)
        text = label || LIGHT_LABELS.fetch(color.to_s, color.to_s)
        tip(%(<span class="dot dot-#{h(color)}"></span>), text)
      end

      # Wrap +inner+ (already-safe HTML) in a branded tooltip trigger showing
      # +hint+ on hover/focus. Returns +inner+ unchanged when there's no hint.
      # The trigger is focusable and carries an aria-label so the hint reaches
      # keyboard and screen-reader users, not just a mouse hover.
      def tip(inner, hint)
        return inner.to_s if hint.nil? || hint.to_s.empty?

        %(<span class="tip" tabindex="0" role="note" aria-label="#{h(hint)}" ) +
          %(data-tip="#{h(hint)}">#{inner}</span>)
      end

      # Inline icons for the notice/flash banners, keyed by severity. Stroked
      # with currentColor so each inherits its notice's accent.
      NOTICE_ICONS = {
        ok: %(<path d="m9 12 2 2 4-4"/><circle cx="12" cy="12" r="9"/>),
        warn: %(<path d="M12 9v4M12 17h.01"/><path d="M10.3 4 2.6 18a1.5 1.5 0 0 0 1.3 2.2h16.2) +
              %(a1.5 1.5 0 0 0 1.3-2.2L13.7 4a1.5 1.5 0 0 0-2.6 0Z"/>),
        bad: %(<circle cx="12" cy="12" r="9"/><path d="m15 9-6 6M9 9l6 6"/>),
        info: %(<circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v4h1"/>)
      }.freeze

      # A branded notification banner. +kind+ is :ok/:warn/:bad/:info; when
      # +dismiss+ is a URL, a close control links there (clearing the flash
      # without any JavaScript).
      def notice(message, kind: :info, dismiss: nil)
        kind = kind.to_sym
        glyph = NOTICE_ICONS.fetch(kind, NOTICE_ICONS[:info])
        icon = %(<span class="notice-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ) +
               %(stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">) +
               %(#{glyph}</svg></span>)
        body = %(<div class="notice-body">#{h(message)}</div>)
        %(<div class="notice notice-#{kind}" role="status">#{icon}#{body}#{notice_close(dismiss)}</div>)
      end

      # The optional dismiss control — a plain link back to +url+ that drops the
      # flash query param, so closing the banner needs no JavaScript.
      CLOSE_ICON = %(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ) +
                   %(stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>)

      def notice_close(url)
        return "" if url.nil?

        %(<a class="notice-close" href="#{h(url)}" aria-label="Dismiss">#{CLOSE_ICON}</a>)
      end

      # Classify a flash message so the banner picks a fitting color. Defensive:
      # anything unrecognized reads as neutral info.
      def flash_kind(message)
        text = message.to_s.downcase
        return :warn if text.match?(/nothing was (started|written)|required|failed|error|denied/)
        return :ok if text.match?(/\bstarted\b|\badded\b|succeeded|queued|dispatched|complete/)

        :info
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
