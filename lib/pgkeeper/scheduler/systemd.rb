# frozen_string_literal: true

module PgKeeper
  module Scheduler
    # Renders schedule entries as systemd service + timer units. Timers are the
    # preferred way to run scheduled jobs on modern Linux: journald captures the
    # logs, +Persistent=true+ catches up a run missed while the box was off, and
    # +RandomizedDelaySec+ staggers multiple databases so they don't all hit the
    # server at once.
    class Systemd
      def initialize(entries, config_path:, bin: "pgkeeper", unit_prefix: "pgkeeper", jitter_seconds: 0)
        @entries = entries
        @bin = bin
        @config_path = config_path
        @unit_prefix = unit_prefix
        @jitter_seconds = jitter_seconds
      end

      # A { filename => contents } map of every unit file to install. The action
      # is part of the unit name (+pgkeeper-backup-app+, +pgkeeper-verify-all+),
      # so backup, verify, and prune install as independent timers.
      def units
        @entries.each_with_object({}) do |entry, files|
          base = "#{@unit_prefix}-#{entry.action}-#{entry.label}"
          files["#{base}.service"] = service_unit(entry)
          files["#{base}.timer"] = timer_unit(entry)
        end
      end

      def service_unit(entry)
        exec = [@bin, entry.action.to_s, "--config", @config_path, *entry.command_args].join(" ")
        <<~UNIT
          [Unit]
          Description=PgKeeper #{entry.action} (#{entry.label})
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=oneshot
          ExecStart=#{exec}
        UNIT
      end

      def timer_unit(entry)
        timer = ["OnCalendar=#{OnCalendar.from_cron(entry.schedule.to_cron)}", "Persistent=true"]
        timer << "RandomizedDelaySec=#{@jitter_seconds}" if @jitter_seconds.positive?
        <<~UNIT
          [Unit]
          Description=PgKeeper #{entry.action} timer (#{entry.label})

          [Timer]
          #{timer.join("\n")}

          [Install]
          WantedBy=timers.target
        UNIT
      end

      # Converts a 5-field cron string into a systemd OnCalendar expression.
      # Covers the shapes PgKeeper generates (single values, comma lists, and
      # +*+); fugit has already expanded ranges/steps to comma lists upstream.
      module OnCalendar
        DOW = %w[Sun Mon Tue Wed Thu Fri Sat Sun].freeze # index 0 and 7 = Sun

        module_function

        def from_cron(cron)
          minute, hour, dom, month, dow = cron.split
          date = "*-#{field(month)}-#{field(dom)}"
          time = "#{pad(field(hour))}:#{pad(field(minute))}:00"
          prefix = weekday_prefix(dow)
          [prefix, "#{date} #{time}"].reject(&:empty?).join(" ")
        end

        def field(value)
          value == "*" ? "*" : value
        end

        # Zero-pad single numeric values (systemd accepts "3" but "03" reads
        # clearer); leave "*" and comma-lists alone.
        def pad(value)
          value.match?(/\A\d+\z/) ? format("%02d", value.to_i) : value
        end

        def weekday_prefix(dow)
          return "" if dow == "*"

          dow.split(",").map { |d| DOW[d.to_i] }.join(",")
        end
      end
    end
  end
end
