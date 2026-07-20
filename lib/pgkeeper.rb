# frozen_string_literal: true

require "pgkeeper/version"
require "pgkeeper/errors"
require "pgkeeper/logging"
require "pgkeeper/config"
require "pgkeeper/lock"
require "pgkeeper/manifest"
require "pgkeeper/dump/pg_dump"
require "pgkeeper/dump/pg_dumpall"
require "pgkeeper/orchestrator"
require "pgkeeper/doctor"
require "pgkeeper/cli"

# PgKeeper is an automated PostgreSQL backup solution.
#
# The public entry point is {PgKeeper::CLI}, the thor-based command line
# interface driven by +bin/pgkeeper+. Library consumers can also drive the
# {PgKeeper::Orchestrator} directly with a loaded {PgKeeper::Config}.
module PgKeeper
  # Process exit codes, shared by the CLI and orchestrator.
  module ExitCode
    SUCCESS = 0        # everything succeeded
    PARTIAL = 1        # some databases failed, others succeeded
    FAILURE = 2        # nothing succeeded / fatal error
  end

  class << self
    # A process-wide default logger. The CLI replaces this with one configured
    # from flags; library callers may set their own.
    attr_writer :logger

    def logger
      @logger ||= Logging.build
    end
  end
end
