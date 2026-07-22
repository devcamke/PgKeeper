# frozen_string_literal: true

require "time"

module PgKeeper
  module Web
    # The management operations the dashboard can trigger, each returning a
    # one-line human summary for the job list. These are the same code paths
    # the CLI drives — the orchestrator's flock, the pruner's dry-run default,
    # the verifier's tiers — so a browser click can never do anything a shell
    # command couldn't.
    class Actions
      def initialize(config, logger: PgKeeper.logger)
        @config = config
        @logger = logger
      end

      def backup(only: nil)
        report = Orchestrator.new(@config, logger: @logger).run(only: only)
        summary = "#{report.succeeded.length} succeeded, #{report.partial.length} partial, " \
                  "#{report.failed.length} failed"
        raise Error, "backup finished with failures: #{summary}" unless report.exit_code == ExitCode::SUCCESS

        summary
      end

      def verify(deep: false)
        results = Verifier.new(@config, logger: @logger).verify(selector: "latest", deep: deep)
        failed = results.reject(&:ok?)
        unless failed.empty?
          raise Error, "verification failed: #{failed.map { |r| "#{r.database} (#{r.detail})" }.join('; ')}"
        end

        "#{results.length} backup(s) verified (#{deep ? 'deep' : 'structural'})"
      end

      def prune(apply: false)
        report = Pruner.new(@config, logger: @logger).prune(apply: apply)
        return "no retention policy configured" unless report.configured
        return "nothing to prune" if report.deletions.empty?

        "#{report.applied ? 'deleted' : 'would delete'} #{report.count} backup set(s)"
      end

      def test_notification
        notifier = Notify.build(@config, logger: @logger)
        raise Error, "no notifiers configured (see `notifications:` in your config)" unless notifier.any?

        results = notifier.dispatch(test_summary)
        "dispatched to #{notifier.backends.length} notifier(s); #{results.count(true)} succeeded"
      end

      def doctor
        checks = Doctor.new(config_path: @config.source, logger: @logger).run
        failures = checks.reject(&:ok?)
        return "#{checks.length} checks passed" if failures.empty?

        "#{checks.length} checks: " +
          failures.map { |c| "#{c.name} #{c.status} (#{c.detail.lines.first&.strip})" }.join("; ")
      end

      private

      def test_summary
        report = Orchestrator::RunReport.new(
          results: [Orchestrator::Result.new(database: "test", status: :success, artifacts: [],
                                             duration_seconds: 0.0)]
        )
        now = Time.now.utc
        Notify::Summary.new(report: report, run_id: "dashboard-test-notification",
                            started_at: now, finished_at: now, hostname: Manifest.safe_hostname)
      end
    end
  end
end
