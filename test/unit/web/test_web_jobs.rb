# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"

module PgKeeper
  class TestWebJobs < Minitest::Test
    include TestHelpers
    include WebHelpers

    def setup
      @jobs = Web::Jobs.new(logger: null_logger)
    end

    def wait(timeout: 5)
      deadline = Time.now + timeout
      sleep 0.01 while @jobs.all.any?(&:running?) && Time.now < deadline
    end

    def test_successful_job_captures_detail
      job = @jobs.run("backup") { "3 succeeded" }
      wait

      found = @jobs.find(job.id)

      assert_predicate found, :done?
      assert_equal "3 succeeded", found.detail
      assert found.started_at
      assert found.finished_at
    end

    def test_failing_job_records_the_error_without_raising
      @jobs.run("backup") { raise LockError, "another PgKeeper run holds the lock" }
      wait

      job = @jobs.all.first

      assert_predicate job, :failed?
      assert_match(/holds the lock/, job.detail)
    end

    def test_jobs_are_newest_first_and_bounded
      (Web::Jobs::MAX_JOBS + 5).times { |i| @jobs.run("job-#{i}") { "ok" } }
      wait

      all = @jobs.all

      assert_equal Web::Jobs::MAX_JOBS, all.length, "registry is bounded"
      assert_equal "job-#{Web::Jobs::MAX_JOBS + 4}", all.first.action, "newest first"
    end

    def test_ids_are_unique_and_monotonic
      ids = Array.new(5) { @jobs.run("x") { "ok" }.id }

      assert_equal ids.sort, ids
      assert_equal ids.uniq, ids
    end
  end
end
