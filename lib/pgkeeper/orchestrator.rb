# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "time"
require "open3"

module PgKeeper
  # Drives a backup run end-to-end for one or more databases.
  #
  # Lifecycle per run:
  #   1. acquire an flock so overlapping cron runs can't corrupt each other,
  #   2. for each database: dump into a temp dir *on the destination filesystem*,
  #      checksum it, write a manifest, then atomically rename into place — so a
  #      crash mid-dump never leaves a half-written file that looks complete,
  #   3. optionally capture cluster globals (roles/tablespaces),
  #   4. collect per-database results and derive an overall exit code.
  #
  # Failures are isolated: one database blowing up doesn't abort the others, and
  # the run reports partial success (exit 1) vs total failure (exit 2).
  class Orchestrator
    # Outcome for a single database.
    Result = Struct.new(:database, :status, :artifacts, :error, :duration_seconds, keyword_init: true) do
      def success? = status == :success
      def failure? = status == :failure
    end

    # Aggregate outcome for a whole run.
    RunReport = Struct.new(:results, keyword_init: true) do
      def succeeded = results.select(&:success?)
      def failed = results.select(&:failure?)

      def exit_code
        return ExitCode::SUCCESS if results.empty? || failed.empty?
        return ExitCode::FAILURE if succeeded.empty?

        ExitCode::PARTIAL
      end
    end

    # Everything a single database's dump needs, threaded through the dump
    # helpers as one value instead of a long parameter list.
    DumpContext = Struct.new(:db, :staging, :timestamp, :began_at, :destination, :log, keyword_init: true)

    def initialize(config, logger: PgKeeper.logger, clock: Time, min_free_bytes: 100 * 1024 * 1024)
      @config = config
      @logger = logger
      @clock = clock
      @min_free_bytes = min_free_bytes
    end

    # Run backups for the selected databases (all, or the subset named in
    # +only+). Returns a {RunReport}.
    def run(only: nil)
      databases = select_databases(only)
      destination = ensure_destination
      run_logger = @logger.with(run: run_id)
      run_logger.info("backup run starting", databases: databases.map(&:name).join(","), destination: destination)

      report = Lock.acquire(lock_path(destination)) do
        results = databases.map { |db| backup_database(db, destination, run_logger) }
        RunReport.new(results: results)
      end

      run_logger.info("backup run finished",
                      succeeded: report.succeeded.length,
                      failed: report.failed.length,
                      exit_code: report.exit_code)
      report
    end

    private

    def select_databases(only)
      return @config.databases if only.nil? || only.empty?

      wanted = Array(only)
      wanted.map do |name|
        @config.database(name) || raise(Error, "unknown database in --only: #{name}")
      end
    end

    # Resolve the local destination directory, creating it if needed. v0.1 ships
    # local storage; cloud backends land the same artifacts in later phases.
    def ensure_destination
      path = @config.local_path
      raise ConfigError, "no local storage target configured" if path.nil?

      FileUtils.mkdir_p(path)
      path
    end

    def lock_path(destination)
      File.join(destination, ".pgkeeper.lock")
    end

    def backup_database(db, destination, run_logger)
      log = run_logger.with(db: db.name)
      started = monotonic
      began_at = @clock.now.utc
      log.info("dumping database")

      preflight!(destination)
      staging = Dir.mktmpdir(".pgkeeper-staging-", destination)
      artifacts = perform_dump(db, staging, began_at, destination, log)

      duration = (monotonic - started).round(3)
      log.info("dump complete", artifacts: artifacts.length, duration_s: duration)
      Result.new(database: db.name, status: :success, artifacts: artifacts, duration_seconds: duration)
    rescue StandardError => e
      duration = (monotonic - started).round(3)
      log.error("dump failed", error: e.message, error_class: e.class.name)
      Result.new(database: db.name, status: :failure, artifacts: [], error: e, duration_seconds: duration)
    ensure
      FileUtils.remove_entry(staging) if staging && File.exist?(staging)
    end

    # Dump the database (and optionally globals) into the staging dir, then
    # finalize each artifact into the destination atomically. Returns finalized
    # artifact descriptors.
    def perform_dump(db, staging, began_at, destination, log)
      ctx = DumpContext.new(
        db: db,
        staging: staging,
        timestamp: began_at.strftime("%Y-%m-%dT%H%M%SZ"),
        began_at: began_at,
        destination: destination,
        log: log
      )

      artifacts = [dump_primary(ctx)]
      artifacts << dump_globals(ctx) if db.include_globals
      artifacts.compact
    end

    def dump_primary(ctx)
      dumper = Dump::PgDump.new(ctx.db, logger: ctx.log)
      staged = File.join(ctx.staging, "#{ctx.db.slug}-#{ctx.timestamp}.#{dumper.extension}")
      duration = timed { dumper.dump(to: staged) }

      attrs = base_manifest(ctx, duration).merge(
        "kind" => "database",
        "format" => ctx.db.format,
        "pg_dump_version" => dumper.version
      )
      finalize(staged, Manifest.for_artifact(staged, attrs), ctx.destination)
    end

    def dump_globals(ctx)
      dumper = Dump::PgDumpall.new(ctx.db, logger: ctx.log)
      staged = File.join(ctx.staging, "#{ctx.db.slug}-globals-#{ctx.timestamp}.sql")
      duration = timed { dumper.dump_globals(to: staged) }

      attrs = base_manifest(ctx, duration).merge(
        "kind" => "globals",
        "format" => "plain",
        "pg_dumpall_version" => dumper.version
      )
      finalize(staged, Manifest.for_artifact(staged, attrs), ctx.destination)
    end

    # Manifest fields common to every artifact in a run.
    def base_manifest(ctx, duration)
      {
        "database" => ctx.db.database,
        "compression" => "none",
        "started_at" => ctx.began_at.iso8601,
        "finished_at" => @clock.now.utc.iso8601,
        "duration_seconds" => duration,
        "server_version" => server_version(ctx.db)
      }
    end

    # Run a block, returning its wall-clock duration in seconds (3 dp).
    def timed
      started = monotonic
      yield
      (monotonic - started).round(3)
    end

    # Move a staged artifact + its manifest into the destination directory with
    # an atomic rename (same filesystem, since staging lives under destination).
    def finalize(staged_artifact, manifest, destination)
      final_artifact = File.join(destination, File.basename(staged_artifact))
      manifest.write(File.join(File.dirname(staged_artifact), "#{File.basename(staged_artifact)}#{Manifest::SUFFIX}"))

      final_manifest = Manifest.path_for(final_artifact)
      staged_manifest = Manifest.path_for(staged_artifact)

      File.chmod(0o600, staged_artifact) if File.file?(staged_artifact)
      File.chmod(0o600, staged_manifest) if File.file?(staged_manifest)
      File.rename(staged_artifact, final_artifact)
      File.rename(staged_manifest, final_manifest)

      {
        artifact: final_artifact,
        manifest: final_manifest,
        kind: manifest.data["kind"],
        size_bytes: manifest.size_bytes,
        checksum: manifest.checksum
      }
    end

    # Fail before dumping if the destination filesystem is low on space — better
    # a clear preflight error than a truncated dump when the disk fills.
    def preflight!(destination)
      free = free_bytes(destination)
      return if free.nil? # unknown; don't block

      return unless free < @min_free_bytes

      raise PreflightError,
            "insufficient free space at #{destination}: #{free} bytes free, " \
            "need at least #{@min_free_bytes}"
    end

    def free_bytes(path)
      out, status = Open3.capture2("df", "-Pk", path)
      return nil unless status.success?

      line = out.lines[1]
      return nil if line.nil?

      available_kb = line.split[3]
      Integer(available_kb) * 1024
    rescue StandardError
      nil
    end

    def server_version(db)
      out, status = Open3.capture2e(db.libpq_env, "psql", "-XtAc", "SHOW server_version")
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def run_id
      format("%<time>s-%<pid>d", time: @clock.now.utc.strftime("%Y%m%dT%H%M%SZ"), pid: Process.pid)
    end
  end
end
