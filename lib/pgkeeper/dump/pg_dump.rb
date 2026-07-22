# frozen_string_literal: true

require "open3"
require_relative "../subprocess"

module PgKeeper
  # Wrappers around the PostgreSQL dump utilities. PgKeeper never reimplements
  # dumping — it shells out to the battle-tested +pg_dump+/+pg_dumpall+ binaries
  # via {Subprocess}, streaming their stderr into the structured log and
  # enforcing a wall-clock deadline so a hung dump can't block a run forever.
  module Dump
    # Shared helpers for shelling out to a dump tool.
    module Runner
      module_function

      # Return the tool's +--version+ string, or nil if it isn't on PATH.
      def tool_version(tool, env: {})
        out, status = Open3.capture2e(env, tool, "--version")
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end

      # Run +tool+ with +args+, streaming stderr to +logger+. Raises {DumpError}
      # on a non-zero exit (carrying the captured stderr), or {TimeoutError} if
      # +timeout+ seconds elapse first.
      def run!(tool, args, env:, logger:, label: tool, timeout: nil)
        logger.debug("running #{label}", argv: ([tool] + args).join(" "))

        _out, stderr_buf, status = Subprocess.stream(env, tool, *args, timeout: timeout, label: label) do |line|
          logger.debug(label, stderr: line.chomp)
        end

        return if status.success?

        raise DumpError.new(
          "#{label} exited #{status.exitstatus}",
          stderr: stderr_buf,
          exit_status: status.exitstatus
        )
      end
    end

    # Single-database dump via +pg_dump+.
    #
    #   dumper = PgKeeper::Dump::PgDump.new(db_config, logger: logger)
    #   dumper.dump(to: "/tmp/app.dump")
    class PgDump
      FORMAT_FLAG = { "custom" => "c", "plain" => "p", "directory" => "d" }.freeze
      EXTENSION = { "custom" => "dump", "plain" => "sql", "directory" => "dir" }.freeze

      attr_reader :db

      def initialize(db, logger: PgKeeper.logger, jobs: nil, compress: nil, timeout: nil)
        @db = db
        @logger = logger
        @jobs = jobs
        @compress = compress
        @timeout = timeout
      end

      # Filename extension appropriate for the configured dump format.
      def extension
        EXTENSION.fetch(@db.format)
      end

      # The +pg_dump --version+ string, or nil if not installed.
      def version
        Runner.tool_version("pg_dump", env: @db.libpq_env)
      end

      # Whether the target dump format is a directory (vs a single file).
      def directory_format?
        @db.format == "directory"
      end

      # Run the dump, writing to +to+ (a file path, or a directory path for
      # +directory+ format). Returns +to+.
      def dump(to:)
        Runner.run!("pg_dump", build_args(to), env: @db.libpq_env, logger: @logger,
                                               label: "pg_dump", timeout: @timeout)
        to
      end

      private

      def build_args(to)
        args = ["--no-password", "--format=#{FORMAT_FLAG.fetch(@db.format)}", "--file=#{to}"]
        args << "--jobs=#{@jobs}" if @jobs && directory_format?
        args << "--compress=#{@compress}" unless @compress.nil?
        @db.schemas.each { |s| args << "--schema=#{s}" }
        @db.exclude_tables.each { |t| args << "--exclude-table=#{t}" }
        args << @db.database
        args
      end
    end
  end
end
