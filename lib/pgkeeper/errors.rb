# frozen_string_literal: true

module PgKeeper
  # Base class for every error PgKeeper raises deliberately. Rescuing this at
  # the CLI boundary lets us print a clean message instead of a backtrace.
  class Error < StandardError; end

  # Raised when the config file is missing, unparseable, or fails validation.
  # Carries a list of human-readable problems so the CLI can print them all at
  # once rather than one-at-a-time.
  class ConfigError < Error
    attr_reader :problems

    def initialize(message, problems: [])
      @problems = Array(problems)
      super(message)
    end
  end

  # Raised when a required external tool (pg_dump, pg_restore, ...) is missing
  # or incompatible.
  class EnvironmentError < Error; end

  # Raised when another PgKeeper run already holds the lock.
  class LockError < Error; end

  # Raised when a dump subprocess exits non-zero. Carries the captured stderr
  # so notifiers and logs can surface the real cause.
  class DumpError < Error
    attr_reader :stderr, :exit_status

    def initialize(message, stderr: nil, exit_status: nil)
      @stderr = stderr
      @exit_status = exit_status
      super(message)
    end
  end

  # Raised on preflight failures (insufficient disk space, unwritable target).
  class PreflightError < Error; end

  # Raised by storage adapters when an upload/download/verify fails after any
  # retries. Carries the destination name so per-destination reporting can name
  # the backend that failed.
  class StorageError < Error
    attr_reader :destination

    def initialize(message, destination: nil)
      @destination = destination
      super(message)
    end
  end
end
