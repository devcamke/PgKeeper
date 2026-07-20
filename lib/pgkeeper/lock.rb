# frozen_string_literal: true

require "fileutils"

module PgKeeper
  # A cross-process advisory lock backed by +flock+, used to prevent overlapping
  # runs (the classic "two cron jobs stomp on each other" failure). Non-blocking
  # by default: if another run holds the lock we fail loudly rather than queueing
  # up a pile-up of dumps.
  #
  #   PgKeeper::Lock.acquire("/var/backups/pgkeeper/.lock") do
  #     # ... exclusive section ...
  #   end
  class Lock
    attr_reader :path

    def initialize(path)
      @path = path
    end

    # Run +block+ while holding the lock, releasing it afterward. Raises
    # {LockError} if the lock is already held.
    def self.acquire(path, &)
      new(path).acquire(&)
    end

    def acquire
      FileUtils.mkdir_p(File.dirname(path))
      # The handle must outlive this open call: flock is released when the file
      # is closed, and we close it explicitly in the ensure block below.
      file = File.open(path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen

      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise LockError, "another PgKeeper run holds the lock at #{path}"
      end

      write_owner(file)
      begin
        yield
      ensure
        file.flock(File::LOCK_UN)
        file.close
      end
    end

    private

    def write_owner(file)
      file.truncate(0)
      file.rewind
      file.write("pid=#{Process.pid} host=#{hostname}\n")
      file.flush
    end

    def hostname
      require "socket"
      Socket.gethostname
    rescue StandardError
      "unknown"
    end
  end
end
