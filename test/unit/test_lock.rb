# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestLock < Minitest::Test
    include TestHelpers

    def test_acquire_runs_block_and_releases
      in_tmpdir do |dir|
        path = File.join(dir, ".lock")
        ran = false
        Lock.acquire(path) { ran = true }

        assert ran

        # Lock is released, so a second acquire succeeds.
        second = false
        Lock.acquire(path) { second = true }

        assert second
      end
    end

    def test_concurrent_holder_is_denied
      in_tmpdir do |dir|
        path = File.join(dir, ".lock")
        observation = nil
        Lock.acquire(path) do
          # A separate process must see the lock as already held.
          observation = child_lock_observation(path)
        end

        assert_equal "denied", observation
      end
    end

    def test_lock_file_records_owner
      in_tmpdir do |dir|
        path = File.join(dir, ".lock")

        Lock.acquire(path) do
          assert_includes File.read(path), "pid=#{Process.pid}"
        end
      end
    end

    private

    # flock is per-open-file-description, so real contention needs a second
    # process. Fork a child that tries to grab the (already-held) lock and report
    # whether it was denied.
    def child_lock_observation(path)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          Lock.acquire(path) { writer.write("acquired") }
        rescue LockError
          writer.write("denied")
        ensure
          writer.close
        end
      end
      writer.close
      result = reader.read
      Process.wait(pid)
      reader.close
      result
    end
  end
end
