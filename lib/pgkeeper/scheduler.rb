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
  module Scheduler
    # One scheduled unit of work.
    Entry = Struct.new(:label, :schedule, :only, keyword_init: true) do
      # Databases this entry backs up: a specific list, or nil for "all".
      def scope_args
        only ? ["--only", *only] : []
      end
    end

    module_function

    def entries(config)
      global = config.schedule
      per_db = config.databases.select(&:schedule)

      if per_db.any?
        entries_per_database(config, global)
      elsif global
        [Entry.new(label: "all", schedule: Schedule.parse(global), only: nil)]
      else
        []
      end
    end

    def entries_per_database(config, global)
      config.databases.filter_map do |db|
        expr = db.schedule || global
        next nil unless expr

        Entry.new(label: db.name, schedule: Schedule.parse(expr), only: [db.name])
      end
    end
  end
end
