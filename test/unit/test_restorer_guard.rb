# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # The destructive-restore guard and the psql invocation, exercised at the
  # Subprocess seam (no live Postgres). The guard must fail *closed*: an
  # unanswerable "is the target empty?" probe stops the restore rather than
  # waving it through.
  class TestRestorerGuard < Minitest::Test
    include TestHelpers

    FakeStatus = Struct.new(:ok) do
      def success? = ok
    end

    FakeConnection = Struct.new(:env) do
      def libpq_env = env || {}
    end

    def restorer
      Restorer.new(Config.new({ "workdir" => "/tmp", "databases" => [{ "name" => "app" }] }),
                   logger: null_logger)
    end

    # Temporarily replace Subprocess.capture3 (minitest/mock is not bundled
    # with Minitest 6, so this is a hand-rolled stub).
    def with_capture3(handler)
      Subprocess.singleton_class.alias_method(:original_capture3, :capture3)
      Subprocess.define_singleton_method(:capture3) { |*args, **kwargs| handler.call(*args, **kwargs) }
      yield
    ensure
      Subprocess.singleton_class.remove_method(:capture3)
      Subprocess.singleton_class.alias_method(:capture3, :original_capture3)
      Subprocess.singleton_class.remove_method(:original_capture3)
    end

    def guard(force:, probe:)
      with_capture3(->(*, **) { probe }) do
        restorer.send(:guard_target!, FakeConnection.new, "t", force)
      end
    end

    def test_empty_target_passes
      guard(force: false, probe: ["0\n", "", FakeStatus.new(true)])
    end

    def test_non_empty_target_without_force_raises
      error = assert_raises(Error) { guard(force: false, probe: ["7\n", "", FakeStatus.new(true)]) }

      assert_includes error.message, "already has 7 table(s)"
    end

    def test_a_failed_probe_fails_closed
      error = assert_raises(Error) { guard(force: false, probe: ["", "connection refused", FakeStatus.new(false)]) }

      assert_includes error.message, "refusing to restore"
    end

    def test_force_skips_the_probe_entirely
      with_capture3(->(*, **) { raise "probe must not run under --force" }) do
        restorer.send(:guard_target!, FakeConnection.new, "t", true)
      end
    end

    def test_plain_restore_stops_on_first_sql_error
      captured = nil
      probe = lambda do |_env, *argv, **|
        captured = argv
        ["", "", FakeStatus.new(true)]
      end
      with_capture3(probe) do
        restorer.send(:run_restore, { path: "dump.sql", format: "plain" }, "t", FakeConnection.new, nil, false)
      end

      assert_includes captured, "ON_ERROR_STOP=1",
                      "psql must abort on the first failed statement, or a partial restore reports success"
    end
  end
end
