# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "pgkeeper"

module PgKeeper
  module TestHelpers
    # A logger that discards output, so tests stay quiet.
    def null_logger
      Logging.build(level: :fatal, destinations: [StringIO.new])
    end

    # Run a block inside a fresh temp directory, cleaned up afterward.
    def in_tmpdir(&)
      Dir.mktmpdir("pgkeeper-test-", &)
    end

    # Connection settings for a live Postgres used by integration tests, or nil
    # if the environment doesn't provide one (tests skip in that case).
    def self.live_pg_env
      host = ENV.fetch("PGKEEPER_TEST_PGHOST", nil)
      return nil if host.nil? || host.empty?

      {
        "host" => host,
        "port" => ENV["PGKEEPER_TEST_PGPORT"] || "5432",
        "username" => ENV.fetch("PGKEEPER_TEST_PGUSER", nil),
        "password" => ENV.fetch("PGKEEPER_TEST_PGPASSWORD", nil),
        "database" => ENV["PGKEEPER_TEST_PGDATABASE"] || "postgres"
      }.compact
    end

    def live_pg_env
      TestHelpers.live_pg_env
    end

    def skip_unless_live_pg
      skip "no live Postgres configured (set PGKEEPER_TEST_PGHOST)" if live_pg_env.nil?
    end
  end
end

require "stringio"
