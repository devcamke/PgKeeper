# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestSubprocess < Minitest::Test
    include TestHelpers

    def test_capture3_returns_stdout_stderr_and_status
      out, err, status = Subprocess.capture3({}, "sh", "-c", "printf out; printf err 1>&2")

      assert_equal "out", out
      assert_equal "err", err
      assert_predicate status, :success?
    end

    def test_capture3_nonzero_exit_is_not_success
      _out, _err, status = Subprocess.capture3({}, "sh", "-c", "exit 3")

      refute_predicate status, :success?
      assert_equal 3, status.exitstatus
    end

    def test_capture3_passes_env
      out, _err, _status = Subprocess.capture3({ "PGK_X" => "hello" }, "sh", "-c", "printf %s \"$PGK_X\"")

      assert_equal "hello", out
    end

    def test_capture3_feeds_stdin
      out, _err, _status = Subprocess.capture3({}, "cat", stdin_data: "piped")

      assert_equal "piped", out
    end

    def test_missing_binary_raises_environment_error
      assert_raises(EnvironmentError) do
        Subprocess.capture3({}, "pgkeeper-does-not-exist-#{$PROCESS_ID}")
      end
    end

    def test_timeout_raises_and_kills_the_child_quickly
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      err = assert_raises(TimeoutError) do
        Subprocess.capture3({}, "sleep", "30", timeout: 0.4)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_match(/timed out after 0.4s/, err.message)
      assert_in_delta(0.4, err.timeout_seconds)
      # Must return promptly (deadline + KILL grace + slack), not wait 30s.
      assert_operator elapsed, :<, 8, "expected the hung child to be killed near the deadline"
    end

    def test_zero_timeout_means_no_deadline
      out, _err, status = Subprocess.capture3({}, "sh", "-c", "printf ok", timeout: 0)

      assert_equal "ok", out
      assert_predicate status, :success?
    end

    def test_stream_yields_stderr_lines_live
      lines = []
      out, err, status = Subprocess.stream({}, "sh", "-c", "printf 'a\\nb\\n' 1>&2; printf done") do |line|
        lines << line
      end

      assert_equal %W[a\n b\n], lines
      assert_equal "a\nb\n", err
      assert_equal "done", out
      assert_predicate status, :success?
    end

    def test_stream_enforces_timeout
      seen = []
      assert_raises(TimeoutError) do
        Subprocess.stream({}, "sleep", "30", timeout: 0.4) { |line| seen << line }
      end
    end
  end
end
