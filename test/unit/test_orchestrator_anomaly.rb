# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # The orchestrator's anomaly annotation reads the SQLite history baseline and
  # attaches a warning to a suddenly-small dump — without needing a database.
  class TestOrchestratorAnomaly < Minitest::Test
    include TestHelpers

    def artifact(bytes)
      { kind: "database", size_bytes: bytes, compression: "none", encryption: "none",
        destinations: [Orchestrator::Destination.new(name: "local", status: :ok)] }
    end

    def success_result(db, bytes)
      Orchestrator::Result.new(database: db, status: :success, artifacts: [artifact(bytes)],
                               duration_seconds: 1.0)
    end

    def seed_history(workdir, db, sizes)
      history = History.new(File.join(workdir, "history.sqlite3"), logger: null_logger)
      sizes.each_with_index do |bytes, i|
        report = Orchestrator::RunReport.new(results: [success_result(db, bytes)])
        t = Time.utc(2026, 1, 1 + i)
        history.record(report, run_id: "seed-#{i}", started_at: t, finished_at: t)
      end
    end

    def orchestrator(workdir, overrides = {})
      cfg = { "workdir" => workdir, "databases" => [{ "name" => "app" }],
              "storage" => [{ "type" => "local", "path" => File.join(workdir, "b") }] }.merge(overrides)
      Orchestrator.new(Config.new(cfg), logger: null_logger)
    end

    def test_flags_a_shrunken_dump_against_history
      in_tmpdir do |dir|
        seed_history(dir, "app", [1000, 1000, 1000, 1000])
        orch = orchestrator(dir)
        report = Orchestrator::RunReport.new(results: [success_result("app", 300)])

        orch.send(:annotate_anomalies, report, null_logger)

        assert_equal 1, report.results.first.warnings.length
        assert_match(/shrank/, report.results.first.warnings.first)
      end
    end

    def test_no_warning_for_a_normal_dump
      in_tmpdir do |dir|
        seed_history(dir, "app", [1000, 1000, 1000, 1000])
        orch = orchestrator(dir)
        report = Orchestrator::RunReport.new(results: [success_result("app", 980)])

        orch.send(:annotate_anomalies, report, null_logger)

        assert_empty report.results.first.warnings
      end
    end

    def test_disabled_anomaly_skips_entirely
      in_tmpdir do |dir|
        seed_history(dir, "app", [1000, 1000, 1000, 1000])
        orch = orchestrator(dir, "anomaly" => { "enabled" => false })
        report = Orchestrator::RunReport.new(results: [success_result("app", 1)])

        orch.send(:annotate_anomalies, report, null_logger)

        assert_empty report.results.first.warnings
      end
    end

    def test_no_history_means_no_warning
      in_tmpdir do |dir|
        orch = orchestrator(dir)
        report = Orchestrator::RunReport.new(results: [success_result("app", 1)])

        orch.send(:annotate_anomalies, report, null_logger)

        assert_empty report.results.first.warnings
      end
    end
  end
end
