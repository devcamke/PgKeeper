# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestOrchestratorReport < Minitest::Test
    include TestHelpers

    def result(status)
      Orchestrator::Result.new(database: "db", status: status, artifacts: [], duration_seconds: 0)
    end

    def test_exit_code_all_success
      report = Orchestrator::RunReport.new(results: [result(:success), result(:success)])

      assert_equal ExitCode::SUCCESS, report.exit_code
    end

    def test_exit_code_partial_failure
      report = Orchestrator::RunReport.new(results: [result(:success), result(:failure)])

      assert_equal ExitCode::PARTIAL, report.exit_code
    end

    def test_exit_code_total_failure
      report = Orchestrator::RunReport.new(results: [result(:failure), result(:failure)])

      assert_equal ExitCode::FAILURE, report.exit_code
    end

    def test_exit_code_empty_run_is_success
      report = Orchestrator::RunReport.new(results: [])

      assert_equal ExitCode::SUCCESS, report.exit_code
    end

    def test_preflight_raises_when_space_below_threshold
      in_tmpdir do |dir|
        config = Config.parse("databases:\n  - name: app\n")
        orch = Orchestrator.new(config, logger: null_logger, min_free_bytes: 1 << 62)
        assert_raises(PreflightError) { orch.send(:preflight!, dir) }
      end
    end

    def test_preflight_passes_with_default_threshold
      in_tmpdir do |dir|
        config = Config.parse("databases:\n  - name: app\n")
        orch = Orchestrator.new(config, logger: null_logger)
        # Should not raise on a normal temp filesystem.
        orch.send(:preflight!, dir)
      end
    end

    def test_unknown_database_in_only_raises
      config = Config.parse("databases:\n  - name: app\n")
      orch = Orchestrator.new(config, logger: null_logger)
      assert_raises(Error) { orch.send(:select_databases, ["nope"]) }
    end

    def test_selects_all_databases_when_only_nil
      config = Config.parse("databases:\n  - name: a\n  - name: b\n")
      orch = Orchestrator.new(config, logger: null_logger)

      assert_equal %w[a b], orch.send(:select_databases, nil).map(&:name)
    end
  end
end
