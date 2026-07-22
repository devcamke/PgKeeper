# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "time"
require "open3"

module PgKeeper
  # Drives a backup run end-to-end for one or more databases.
  #
  # Per database, per artifact (the dump, and optionally cluster globals) the
  # pipeline is:
  #
  #   pg_dump → package (directory formats) → compress → encrypt → manifest
  #           → fan out to every configured storage destination
  #
  # Cross-cutting guarantees:
  #   * an flock stops overlapping cron runs from colliding,
  #   * work happens in a staging dir and each storage backend finalizes
  #     atomically, so a crash never leaves a half-written backup,
  #   * every artifact gets a SHA-256 manifest describing exactly how to reverse
  #     the pipeline (compression + encryption) on restore,
  #   * destinations are independent — one cloud outage fails only that
  #     destination, and the report records status per-destination.
  class Orchestrator
    # Per-destination upload outcome for one artifact.
    Destination = Struct.new(:name, :status, :error, keyword_init: true) do
      def ok? = status == :ok
    end

    # Outcome for a single database. +status+ is :success (dumped and stored
    # everywhere), :partial (dumped, but at least one destination failed), or
    # :failure (the dump itself failed). +warnings+ carries non-fatal advisories
    # (e.g. a backup-size anomaly) surfaced in reports and notifications.
    Result = Struct.new(:database, :status, :artifacts, :error, :duration_seconds, :warnings,
                        keyword_init: true) do
      def success? = status == :success
      def partial? = status == :partial
      def failure? = status == :failure

      # Lazily-initialized so callers can push advisories without constructing
      # the array up front.
      def warnings = self[:warnings] ||= []

      def total_bytes = Array(artifacts).sum { |a| a[:size_bytes].to_i }
    end

    # Aggregate outcome for a whole run.
    RunReport = Struct.new(:results, keyword_init: true) do
      def succeeded = results.select(&:success?)
      def partial = results.select(&:partial?)
      def failed = results.select(&:failure?)

      def exit_code
        return ExitCode::SUCCESS if results.empty? || results.all?(&:success?)
        return ExitCode::FAILURE if results.all?(&:failure?)

        ExitCode::PARTIAL
      end
    end

    # Per-database dump context, threaded through the pipeline as one value.
    DumpContext = Struct.new(:db, :staging, :timestamp, :began_at, :log, keyword_init: true)

    def initialize(config, logger: PgKeeper.logger, clock: Time, min_free_bytes: 100 * 1024 * 1024,
                   scratch_factor: 1.5)
      @config = config
      @logger = logger
      @clock = clock
      @preflight = Preflight.new(min_free_bytes: min_free_bytes, scratch_factor: scratch_factor,
                                 query_timeout: config.timeout(:query))
    end

    # Run backups for the selected databases (all, or the subset named in
    # +only+), fanning out to the selected destinations (all, or the subset
    # named in +destinations+ by their friendly name or type). Returns a
    # {RunReport}.
    def run(only: nil, destinations: nil)
      started_at = @clock.now.utc
      run_identifier = run_id
      databases = select_databases(only)
      run_logger = start_run(databases, run_identifier, destinations)

      report = Lock.acquire(File.join(@config.workdir, ".pgkeeper.lock")) do
        RunReport.new(results: databases.map { |db| backup_database(db, @config.workdir, run_logger) })
      end

      annotate_anomalies(report, run_logger)
      log_run_finished(report, run_logger)
      finalize_run(report, run_identifier, started_at, run_logger)
      report
    end

    private

    # Build the run's adapters/encryptor, ensure the workdir, and log the start.
    # +destinations+ (nil for all) narrows the fan-out to a chosen subset.
    def start_run(databases, run_identifier, destinations = nil)
      targets = Storage.select(@config.storage, destinations)
      @adapters = Storage.build_all(targets, logger: @logger)
      @encryptor = Crypto.build(@config.encryption)
      ensure_workdir
      run_logger = @logger.with(run: run_identifier)
      run_logger.info("backup run starting",
                      databases: databases.map(&:name).join(","),
                      destinations: @adapters.map(&:name).join(","),
                      compression: @config.compression,
                      encryption: @encryptor&.name || "none")
      run_logger
    end

    def log_run_finished(report, run_logger)
      run_logger.info("backup run finished",
                      succeeded: report.succeeded.length,
                      partial: report.partial.length,
                      failed: report.failed.length,
                      warnings: report.results.sum { |r| r.warnings.length },
                      exit_code: report.exit_code)
    end

    # Compare each database's fresh dump size against its recent successful runs
    # and attach a loud advisory when it moves too far — the classic "silently
    # broken dump" signal. Best-effort: never changes the run's outcome.
    def annotate_anomalies(report, run_logger)
      return unless @config.anomaly["enabled"]

      history = History.new(File.join(@config.workdir, "history.sqlite3"), logger: run_logger)
      report.results.each do |result|
        next if result.failure? || result.total_bytes.zero?

        sizes = history.recent_success_sizes(result.database, limit: @config.anomaly["sample_size"].to_i)
        finding = Anomaly.detect(database: result.database, current_bytes: result.total_bytes,
                                 baseline_sizes: sizes, config: @config.anomaly)
        next unless finding

        result.warnings << finding.message
        run_logger.warn("backup size anomaly", db: result.database, **finding.to_log)
      end
    rescue StandardError => e
      run_logger.warn("anomaly check skipped (non-fatal)", error: e.message)
    end

    # Persist run history and fire notifications after a run. Both are
    # best-effort: neither may change the run's outcome, so failures here are
    # logged and swallowed.
    def finalize_run(report, run_identifier, started_at, log)
      finished_at = @clock.now.utc
      record_history(report, run_identifier, started_at, finished_at, log)
      dispatch_notifications(report, run_identifier, started_at, finished_at, log)
    end

    def record_history(report, run_identifier, started_at, finished_at, log)
      History.new(File.join(@config.workdir, "history.sqlite3"), logger: log)
             .record(report, run_id: run_identifier, started_at: started_at, finished_at: finished_at)
    rescue StandardError => e
      log.warn("history unavailable (non-fatal)", error: e.message)
    end

    def dispatch_notifications(report, run_identifier, started_at, finished_at, log)
      notifier = Notify.build(@config, logger: log)
      return unless notifier.any?

      summary = Notify::Summary.new(
        report: report, run_id: run_identifier,
        started_at: started_at, finished_at: finished_at, hostname: Manifest.safe_hostname
      )
      notifier.dispatch(summary)
    rescue StandardError => e
      log.error("notifications failed (non-fatal)", error: e.message)
    end

    def select_databases(only)
      return @config.databases if only.nil? || only.empty?

      Array(only).map do |name|
        @config.database(name) || raise(Error, "unknown database in --only: #{name}")
      end
    end

    def ensure_workdir
      dir = @config.workdir
      FileUtils.mkdir_p(dir)
      dir
    end

    def backup_database(db, workdir, run_logger)
      log = run_logger.with(db: db.name)
      started = monotonic
      began_at = @clock.now.utc
      log.info("dumping database")

      @preflight.check!(db, workdir)
      staging = Dir.mktmpdir(".pgkeeper-staging-", workdir)
      artifacts = perform_dump(db, staging, began_at, log)

      status = derive_status(artifacts)
      duration = (monotonic - started).round(3)
      log.info("database done", status: status, artifacts: artifacts.length, duration_s: duration)
      Result.new(database: db.name, status: status, artifacts: artifacts, duration_seconds: duration)
    rescue StandardError => e
      duration = (monotonic - started).round(3)
      log.error("dump failed", error: e.message, error_class: e.class.name)
      Result.new(database: db.name, status: :failure, artifacts: [], error: e, duration_seconds: duration)
    ensure
      FileUtils.remove_entry(staging) if staging && File.exist?(staging)
    end

    # :success if every artifact reached every destination; :partial if any
    # destination failed for any artifact; the dump itself failing is handled by
    # the rescue above.
    def derive_status(artifacts)
      all_dest = artifacts.flat_map { |a| a[:destinations] }
      return :success if all_dest.empty? || all_dest.all?(&:ok?)

      :partial
    end

    def perform_dump(db, staging, began_at, log)
      ctx = DumpContext.new(
        db: db, staging: staging, began_at: began_at,
        timestamp: began_at.strftime("%Y-%m-%dT%H%M%SZ"), log: log
      )
      artifacts = [dump_primary(ctx)]
      artifacts << dump_globals(ctx) if db.include_globals
      artifacts.compact
    end

    def dump_primary(ctx)
      dumper = Dump::PgDump.new(ctx.db, logger: ctx.log, timeout: @config.timeout(:dump))
      raw = File.join(ctx.staging, "#{ctx.db.slug}-#{ctx.timestamp}.#{dumper.extension}")
      duration = timed { dumper.dump(to: raw) }
      process_artifact(ctx, raw, kind: "database", dump_format: ctx.db.format, duration: duration,
                                 extra: { "pg_dump_version" => dumper.version })
    end

    def dump_globals(ctx)
      dumper = Dump::PgDumpall.new(ctx.db, logger: ctx.log, timeout: @config.timeout(:dump))
      raw = File.join(ctx.staging, "#{ctx.db.slug}-globals-#{ctx.timestamp}.sql")
      duration = timed { dumper.dump_globals(to: raw) }
      process_artifact(ctx, raw, kind: "globals", dump_format: "plain", duration: duration,
                                 extra: { "pg_dumpall_version" => dumper.version })
    end

    # Run one raw dump output through package → compress → encrypt → manifest →
    # upload, returning a descriptor of the finished artifact.
    def process_artifact(ctx, raw, kind:, dump_format:, duration:, extra:)
      packaged, compression = package_and_compress(raw, dump_format, ctx)
      final, encryption = maybe_encrypt(packaged, ctx)

      manifest = build_manifest(ctx, final, kind: kind, dump_format: dump_format, duration: duration,
                                            compression: compression, encryption: encryption, extra: extra)
      destinations = distribute(final, manifest, ctx)

      {
        artifact: File.basename(final), kind: kind,
        size_bytes: manifest.size_bytes, checksum: manifest.checksum,
        compression: compression, encryption: encryption, destinations: destinations
      }
    end

    # Turn the raw dump into a single compressed file. Directory-format dumps are
    # packaged into a zip (they can't be uploaded as a directory). custom/
    # directory outputs are already compressed by pg_dump, so external
    # compression is skipped there with a note.
    def package_and_compress(raw, dump_format, ctx)
      if dump_format == "directory"
        dest = "#{raw}.zip"
        Compress::Zip.new.compress_tree(raw, dest)
        FileUtils.remove_entry(raw)
        return [dest, "zip"]
      end

      configured = @config.compression
      if %w[custom].include?(dump_format) && configured != "none"
        ctx.log.debug("skipping external compression (dump already compressed)", format: dump_format)
        return [raw, "none"]
      end
      return [raw, "none"] if configured == "none"

      compressor = Compress.for(configured)
      dest = "#{raw}.#{compressor.extension}"
      compressor.compress(raw, dest)
      FileUtils.remove_entry(raw)
      [dest, configured]
    end

    def maybe_encrypt(path, ctx)
      return [path, "none"] if @encryptor.nil?

      dest = "#{path}.#{@encryptor.extension}"
      @encryptor.encrypt(path, dest)
      FileUtils.remove_entry(path)
      ctx.log.debug("encrypted artifact", type: @encryptor.name)
      [dest, @encryptor.name]
    end

    def build_manifest(ctx, final, kind:, dump_format:, duration:, compression:, encryption:, extra:)
      attrs = {
        "kind" => kind, "database" => ctx.db.database,
        "dump_format" => dump_format, "compression" => compression, "encryption" => encryption,
        "started_at" => ctx.began_at.iso8601, "finished_at" => @clock.now.utc.iso8601,
        "duration_seconds" => duration, "server_version" => server_version(ctx.db)
      }.merge(extra)
      manifest = Manifest.for_artifact(final, attrs)
      manifest.write(Manifest.path_for(final))
      manifest
    end

    # Upload the artifact + its manifest sidecar to every destination, tracking
    # each independently. A folder-per-database remote layout keeps listings
    # tidy.
    def distribute(final, _manifest, ctx)
      remote = "#{ctx.db.slug}/#{File.basename(final)}"
      manifest_path = Manifest.path_for(final)

      @adapters.map do |adapter|
        adapter.upload(final, remote)
        adapter.upload(manifest_path, Manifest.path_for(remote))
        ctx.log.debug("stored", destination: adapter.name, remote: remote)
        Destination.new(name: adapter.name, status: :ok)
      rescue StorageError => e
        ctx.log.error("destination failed", destination: adapter.name, error: e.message)
        Destination.new(name: adapter.name, status: :failed, error: e.message)
      end
    end

    def server_version(db)
      out, _err, status = Subprocess.capture3(db.libpq_env, "psql", "-XtAc", "SHOW server_version",
                                              timeout: @config.timeout(:query))
      status.success? ? out.strip : nil
    rescue EnvironmentError, TimeoutError
      nil
    end

    def timed
      started = monotonic
      yield
      (monotonic - started).round(3)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def run_id
      format("%<time>s-%<pid>d", time: @clock.now.utc.strftime("%Y%m%dT%H%M%SZ"), pid: Process.pid)
    end
  end
end
