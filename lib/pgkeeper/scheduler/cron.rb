# frozen_string_literal: true

require "shellwords"

module PgKeeper
  module Scheduler
    # Renders schedule entries as crontab lines. Each line is guarded by
    # +flock -n+ so a slow run never overlaps its next tick, and appends output
    # to a log file so failures aren't lost to cron's mail-to-nowhere default.
    #
    #   15 3 * * * /usr/bin/flock -n /var/backups/pgkeeper/.cron-all.lock \
    #     pgkeeper backup --config /etc/pgkeeper/pgkeeper.yml >> /var/log/pgkeeper.log 2>&1
    class Cron
      MARKER = "# pgkeeper managed"

      def initialize(entries, config_path:, workdir:, bin: "pgkeeper", log_file: nil, flock: "/usr/bin/flock")
        @entries = entries
        @bin = bin
        @config_path = config_path
        @workdir = workdir
        @log_file = log_file || File.join(workdir, "pgkeeper.log")
        @flock = flock
      end

      # The full crontab block (header comment + one line per entry).
      def render
        return "" if @entries.empty?

        "#{([MARKER] + lines).join("\n")}\n"
      end

      # Just the crontab lines, without the marker comment.
      def lines
        @entries.map { |e| line_for(e) }
      end

      private

      def line_for(entry)
        "#{entry.schedule.to_cron} #{command_for(entry)}"
      end

      def command_for(entry)
        lock = File.join(@workdir, ".cron-#{entry.label}.lock")
        argv = [@flock, "-n", lock, @bin, "backup", "--config", @config_path, *entry.scope_args]
        "#{argv.map { |a| Shellwords.escape(a) }.join(' ')} >> #{Shellwords.escape(@log_file)} 2>&1"
      end
    end
  end
end
