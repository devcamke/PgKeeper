# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestHistory < Minitest::Test
    include TestHelpers

    def setup
      @dir = Dir.mktmpdir("pgkeeper-history-")
      @history = History.new(File.join(@dir, "history.sqlite3"), logger: null_logger)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    def result(db, status, artifacts: [])
      Orchestrator::Result.new(database: db, status: status, artifacts: artifacts, duration_seconds: 1.5)
    end

    def report(*results)
      Orchestrator::RunReport.new(results: results)
    end

    def dest(name, status)
      Orchestrator::Destination.new(name: name, status: status)
    end

    def record(report, run_id: "r1", at: Time.utc(2026, 5, 1, 3, 15))
      @history.record(report, run_id: run_id, started_at: at, finished_at: at + 5)
    end

    def test_records_and_reads_back_a_run
      artifacts = [{ kind: "database", size_bytes: 2048, destinations: [dest("local:/b", :ok)] }]

      assert record(report(result("app", :success, artifacts: artifacts)))

      rows = @history.recent

      assert_equal 1, rows.length
      row = rows.first

      assert_equal "app", row.database
      assert_equal "success", row.status
      assert_equal 1, row.artifact_count
      assert_equal 2048, row.total_bytes
      assert_equal "r1", row.run_id
      assert_equal [{ "name" => "local:/b", "status" => "ok" }], row.destinations
    end

    def test_last_per_database_returns_newest_per_db
      record(report(result("app", :success)), run_id: "old", at: Time.utc(2026, 5, 1))
      record(report(result("app", :failure)), run_id: "new", at: Time.utc(2026, 5, 2))
      record(report(result("analytics", :success)), run_id: "a1", at: Time.utc(2026, 5, 1))

      latest = @history.last_per_database
      by_db = latest.to_h { |r| [r.database, r] }

      assert_equal "new", by_db["app"].run_id, "keeps the most recent run for app"
      assert_equal "failure", by_db["app"].status
      assert_equal "a1", by_db["analytics"].run_id
    end

    def test_runs_for_returns_every_database_row_of_one_run
      record(report(result("app", :success), result("analytics", :failure)), run_id: "multi")
      record(report(result("app", :success)), run_id: "other", at: Time.utc(2026, 5, 2))

      rows = @history.runs_for("multi")

      assert_equal %w[app analytics], rows.map(&:database)
      assert_equal %w[success failure], rows.map(&:status)
      assert_empty @history.runs_for("nope")
    end

    def test_records_error_message_on_failure
      failing = result("app", :failure)
      failing.error = PgKeeper::DumpError.new("boom")
      record(report(failing))

      assert_equal "boom", @history.recent.first.error
    end

    def test_recent_limit_and_filter
      5.times { |i| record(report(result("app", :success)), run_id: "app#{i}", at: Time.utc(2026, 5, 1, i)) }
      record(report(result("other", :success)), run_id: "o1")

      assert_equal 2, @history.recent(limit: 2).length
      app_rows = @history.recent(limit: 100, database: "app")

      assert_equal 5, app_rows.length
      assert(app_rows.all? { |r| r.database == "app" })
    end

    def test_record_is_non_fatal_on_bad_path
      broken = History.new("/proc/nonexistent/cannot/write.sqlite3", logger: null_logger)
      # Should log and return false, never raise.
      refute broken.record(report(result("app", :success)), run_id: "x",
                                                            started_at: Time.now, finished_at: Time.now)
    end
  end
end
