# frozen_string_literal: true

require "support/backup_seeding"
require "pgkeeper/web"

module PgKeeper
  # Test helper: builds a dashboard-ready config (tmp workdir + local storage),
  # seeds backups and run history, and fakes the management actions so web
  # tests never shell out to pg_dump.
  module WebHelpers
    include BackupSeeding

    TOKEN = "test-dashboard-token"

    def web_config(dir, extra_yaml = "")
      Config.parse(<<~YAML, source: "test")
        workdir: #{dir}
        schedule: "daily at 03:15"
        databases:
          - name: app
          - name: analytics
        storage:
          - type: local
            path: #{dir}/backups
        retention:
          keep_last: 1
        web:
          auth:
            token: #{TOKEN}
        #{extra_yaml}
      YAML
    end

    def seed_history(config, run_id: "20260721T031500Z-42", database: "app", status: :success,
                     at: Time.utc(2026, 7, 21, 3, 15), size: 2048, error: nil)
      artifacts = if status == :failure
                    []
                  else
                    [{ kind: "database", size_bytes: size,
                       destinations: [Orchestrator::Destination.new(name: "local:#{config.workdir}/backups",
                                                                    status: :ok)] }]
                  end
      result = Orchestrator::Result.new(database: database, status: status, artifacts: artifacts,
                                        error: error && RuntimeError.new(error), duration_seconds: 1.25)
      History.new(File.join(config.workdir, "history.sqlite3"), logger: null_logger)
             .record(Orchestrator::RunReport.new(results: [result]),
                     run_id: run_id, started_at: at, finished_at: at + 5)
    end

    # Stands in for Web::Actions: records calls, returns a canned detail or
    # raises the configured error.
    class FakeActions
      attr_reader :calls

      def initialize(error: nil)
        @calls = []
        @error = error
      end

      %i[backup verify prune test_notification doctor].each do |name|
        define_method(name) do |**kwargs|
          @calls << [name, kwargs]
          raise @error if @error

          "#{name} ok"
        end
      end
    end

    # Background jobs finish asynchronously; poll briefly so assertions on job
    # outcomes don't race the worker thread.
    def wait_for_jobs(app, timeout: 5)
      deadline = Time.now + timeout
      sleep 0.01 while app.jobs.all.any?(&:running?) && Time.now < deadline
      app.jobs.all
    end
  end
end
