# frozen_string_literal: true

require "open3"

module PgKeeper
  # Wrappers around the PostgreSQL dump utilities. PgKeeper never reimplements
  # dumping — it shells out to the battle-tested +pg_dump+/+pg_dumpall+ binaries
  # via +Open3+, streaming their stderr into the structured log.
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
      # on a non-zero exit, carrying the captured stderr.
      def run!(tool, args, env:, logger:, label: tool)
        logger.debug("running #{label}", argv: ([tool] + args).join(" "))
        stderr_buf = +""

        status = Open3.popen3(env, tool, *args) do |stdin, stdout, stderr, wait|
          stdin.close
          drain = Thread.new { stdout.read }
          stderr.each_line do |line|
            stderr_buf << line
            logger.debug(label, stderr: line.chomp)
          end
          drain.join
          wait.value
        end

        return if status.success?

        raise DumpError.new(
          "#{label} exited #{status.exitstatus}",
          stderr: stderr_buf,
          exit_status: status.exitstatus
        )
      rescue Errno::ENOENT
        raise EnvironmentError, "#{tool} not found on PATH"
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

      def initialize(db, logger: PgKeeper.logger, jobs: nil, compress: nil)
        @db = db
        @logger = logger
        @jobs = jobs
        @compress = compress
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
        Runner.run!("pg_dump", build_args(to), env: @db.libpq_env, logger: @logger, label: "pg_dump")
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
