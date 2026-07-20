# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Exercises the retry/backoff behavior in Storage::Base with a tiny fake
  # adapter, so we don't depend on any real backend's failure modes.
  class TestStorageRetry < Minitest::Test
    include TestHelpers

    # Fails its upload the first `fail_times` attempts, then succeeds. Treats
    # RuntimeError as transient so the retry loop engages.
    class FlakyAdapter < Storage::Base
      attr_reader :attempts

      def initialize(fail_times:, transient: true, **)
        super(**)
        @fail_times = fail_times
        @transient = transient
        @attempts = 0
      end

      def name = "flaky"

      private

      def do_upload(_local, _remote)
        @attempts += 1
        raise "transient blip" if @attempts <= @fail_times
      end

      # Skip size verification, honor the configured transience, and never
      # actually sleep during tests.
      def remote_size(_remote) = nil
      def transient_error?(_error) = @transient
      def pause(_seconds) = nil
    end

    def with_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.bin")
        File.binwrite(path, "data")
        yield path
      end
    end

    def test_retries_transient_failures_then_succeeds
      adapter = FlakyAdapter.new(fail_times: 2, retry_attempts: 3, logger: null_logger)
      with_file do |path|
        result = adapter.upload(path, "x.dump")

        assert_equal 3, adapter.attempts, "should have tried 3 times (2 fail + 1 success)"
        assert_equal "x.dump", result.remote_path
      end
    end

    def test_gives_up_after_attempts_exhausted
      adapter = FlakyAdapter.new(fail_times: 5, retry_attempts: 3, logger: null_logger)
      with_file do |path|
        assert_raises(StorageError) { adapter.upload(path, "x.dump") }
        assert_equal 3, adapter.attempts, "should stop after retry_attempts"
      end
    end

    def test_non_transient_error_is_not_retried
      adapter = FlakyAdapter.new(fail_times: 5, transient: false, retry_attempts: 3, logger: null_logger)
      with_file do |path|
        assert_raises(StorageError) { adapter.upload(path, "x.dump") }
        assert_equal 1, adapter.attempts, "non-transient errors must not retry"
      end
    end
  end
end
