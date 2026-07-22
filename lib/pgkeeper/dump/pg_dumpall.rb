# frozen_string_literal: true

require "open3"
require_relative "pg_dump"

module PgKeeper
  module Dump
    # Dumps cluster-wide globals (roles, tablespaces, grants) via
    # +pg_dumpall --globals-only+.
    #
    # This is the most commonly forgotten piece of a backup: +pg_dump+ captures a
    # single database's schema and data but *not* the roles those objects depend
    # on. Restore a plain +pg_dump+ onto a fresh server and it fails on missing
    # roles. Capturing globals alongside each database closes that gap.
    class PgDumpall
      attr_reader :db

      def initialize(db, logger: PgKeeper.logger, timeout: nil)
        @db = db
        @logger = logger
        @timeout = timeout
      end

      def version
        Runner.tool_version("pg_dumpall", env: @db.libpq_env)
      end

      # Dump only the globals to the SQL file at +to+. Returns +to+.
      def dump_globals(to:)
        args = ["--no-password", "--globals-only", "--file=#{to}"]
        Runner.run!("pg_dumpall", args, env: @db.libpq_env, logger: @logger,
                                        label: "pg_dumpall", timeout: @timeout)
        to
      end
    end
  end
end
