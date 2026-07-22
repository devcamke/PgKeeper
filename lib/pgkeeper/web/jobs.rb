# frozen_string_literal: true

require "time"

module PgKeeper
  module Web
    # An in-memory registry of management actions triggered from the dashboard.
    # Each job runs in its own thread so a long backup never blocks the HTTP
    # response; the registry keeps the outcome (bounded to the most recent
    # {MAX_JOBS}) for the actions page to display.
    #
    # Concurrency safety comes from the pipeline itself: the orchestrator (and
    # anything else that mutates state) takes the same flock as cron, so a job
    # colliding with a scheduled run fails loudly with a {LockError} instead of
    # running a second concurrent pipeline.
    class Jobs
      MAX_JOBS = 50

      Job = Struct.new(:id, :action, :status, :detail, :started_at, :finished_at, keyword_init: true) do
        def running? = status == :running
        def done? = status == :done
        def failed? = status == :failed
      end

      def initialize(logger: PgKeeper.logger)
        @logger = logger
        @mutex = Mutex.new
        @jobs = []
        @next_id = 0
      end

      # Start +action+ in a background thread. The block's return value becomes
      # the job's detail on success; any raised error marks it failed. Returns
      # the {Job} immediately.
      def run(action, &block)
        job = register(action)
        Thread.new { execute(job, &block) }
        job
      end

      # All jobs, newest first.
      def all
        @mutex.synchronize { @jobs.reverse }
      end

      def find(id)
        @mutex.synchronize { @jobs.find { |j| j.id == id } }
      end

      private

      def register(action)
        @mutex.synchronize do
          job = Job.new(id: @next_id += 1, action: action, status: :running,
                        detail: nil, started_at: Time.now.utc)
          @jobs << job
          @jobs.shift while @jobs.length > MAX_JOBS
          job
        end
      end

      def execute(job)
        detail = yield
        finish(job, :done, detail.to_s)
      rescue StandardError => e
        @logger.error("dashboard job failed", action: job.action, error: e.message)
        finish(job, :failed, e.message)
      end

      def finish(job, status, detail)
        @mutex.synchronize do
          job.status = status
          job.detail = detail
          job.finished_at = Time.now.utc
        end
      end
    end
  end
end
