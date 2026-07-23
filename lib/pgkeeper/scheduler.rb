# frozen_string_literal: true

require "pgkeeper/schedule"
require "pgkeeper/scheduler/cron"
require "pgkeeper/scheduler/systemd"

module PgKeeper
  # Turns a config's schedule settings into concrete schedule entries, and hosts
  # the installers that render those entries as crontab lines or systemd units.
  #
  # Resolution: if any database declares its own +schedule+, each database is
  # scheduled independently (falling back to the global schedule when it has
  # none); otherwise a single global schedule runs every database together.
  #
  # Beyond the backup itself, the optional +maintenance:+ config block schedules
  # the two upkeep jobs the tool's philosophy depends on — +verify+ (a backup
  # you haven't restored isn't a backup) and +prune+ (storage shouldn't grow
  # forever). Each becomes an entry with its own +action+, rendered as a distinct
  # cron line / systemd unit and dispatched by the {Daemon}.
  module Scheduler
    # One scheduled unit of work: a backup (default), a verify, or a prune.
    Entry = Struct.new(:label, :schedule, :only, :action, :flags, keyword_init: true) do
      # The pgkeeper subcommand this entry runs.
      def action = self[:action] || :backup

      # Extra flags for the action (e.g. +--deep+ for verify, +--apply+ for
      # prune), before the database scope.
      def flags = self[:flags] || []

      # Databases this entry targets: a specific list, or nil for "all".
      def scope_args
        only ? ["--only", *only] : []
      end

      # Everything after the subcommand: action flags then database scope.
      def command_args = [*flags, *scope_args]

      # Stable identity, unique across action *and* scope, used for cron lock
      # files and systemd unit names. Backup keeps its bare label so existing
      # installs are unchanged; verify/prune are prefixed with the action.
      def slug = action == :backup ? label.to_s : "#{action}-#{label}"
    end

    module_function

    def entries(config)
      backup_entries(config) + maintenance_entries(config)
    end

    def backup_entries(config)
      global = config.schedule
      per_db = config.databases.select(&:schedule)

      if per_db.any?
        entries_per_database(config, global)
      elsif global
        [Entry.new(label: "all", schedule: Schedule.parse(global), only: nil, action: :backup)]
      else
        []
      end
    end

    def entries_per_database(config, global)
      config.databases.filter_map do |db|
        expr = db.schedule || global
        next nil unless expr

        Entry.new(label: db.name, schedule: Schedule.parse(expr), only: [db.name], action: :backup)
      end
    end

    # Build verify/prune entries from the +maintenance:+ block. A task with no
    # schedule contributes nothing.
    def maintenance_entries(config)
      %i[verify prune].filter_map do |action|
        task = config.maintenance[action.to_s]
        next nil unless task && task["schedule"]

        Entry.new(
          label: maintenance_label(task["only"]),
          schedule: Schedule.parse(task["schedule"]),
          only: task["only"],
          action: action,
          flags: maintenance_flags(action, task)
        )
      end
    end

    def maintenance_label(only)
      only && !only.empty? ? only.join("-") : "all"
    end

    def maintenance_flags(action, task)
      case action
      when :verify then task["deep"] ? ["--deep"] : []
      when :prune then task["apply"] ? ["--apply"] : []
      else []
      end
    end
  end
end
