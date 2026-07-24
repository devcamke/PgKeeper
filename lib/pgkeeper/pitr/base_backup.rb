# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "time"
require "json"

module PgKeeper
  module PITR
    # Takes a physical base backup of a cluster with +pg_basebackup+, then runs
    # the result through the same package → compress → encrypt → manifest →
    # fan-out pipeline the logical dump uses — PITR is just another producer on
    # the existing conveyor.
    #
    # Stage 1 of Phase 12 (see docs/PITR-DESIGN.md). The base is captured with
    # +--wal-method=fetch+ so it is standalone-restorable on its own; continuous
    # WAL archiving (which unlocks point-in-time targets) arrives in Stage 2.
    class BaseBackup
      def initialize(config, logger: PgKeeper.logger, clock: Time)
        @config = config
        @logger = logger
        @clock = clock
      end

      # Take base backups for the selected clusters (every PITR cluster, or just
      # the one named), fanning out to the selected destinations. Returns an
      # {Orchestrator::RunReport} so it shares the CLI reporter and run-history.
      def run(only: nil, destinations: nil)
        clusters = select_clusters(only)
        started_at = @clock.now.utc
        identifier = run_id
        @adapters = Storage.build_all(Storage.select(@config.storage, destinations), logger: @logger)
        @encryptor = Crypto.build(@config.encryption)
        FileUtils.mkdir_p(@config.workdir)

        log = @logger.with(run: identifier)
        log.info("base backup run starting", clusters: clusters.map(&:name).join(","),
                                             destinations: @adapters.map(&:name).join(","),
                                             encryption: @encryptor&.name || "none")

        report = Lock.acquire(File.join(@config.workdir, ".pgkeeper.lock")) do
          Orchestrator::RunReport.new(results: clusters.map { |cluster| backup_cluster(cluster, log) })
        end
        record_history(report, identifier, started_at, @clock.now.utc, log)
        report
      end

      private

      def select_clusters(only)
        available = @config.pitr_clusters
        if available.empty?
          raise Error, "no PITR clusters configured (add a `clusters:` entry with `pitr.enabled: true`)"
        end
        return available if only.nil? || only.empty?

        Array(only).map do |name|
          cluster = @config.cluster(name)
          raise Error, "unknown or non-PITR cluster in --cluster: #{name}" unless cluster&.pitr?

          cluster
        end
      end

      def backup_cluster(cluster, run_log)
        log = run_log.with(cluster: cluster.name)
        started = monotonic
        began_at = @clock.now.utc
        log.info("base backup starting")

        staging = Dir.mktmpdir(".pgkeeper-base-", @config.workdir)
        artifact = capture_and_store(cluster, staging, began_at.strftime("%Y-%m-%dT%H%M%SZ"), began_at, log)
        succeeded_result(cluster, artifact, started, log)
      rescue StandardError => e
        failed_result(cluster, e, started, log)
      ensure
        FileUtils.remove_entry(staging) if staging && File.exist?(staging)
      end

      def succeeded_result(cluster, artifact, started, log)
        duration = (monotonic - started).round(3)
        status = artifact[:destinations].all?(&:ok?) ? :success : :partial
        log.info("base backup done", status: status, duration_s: duration)
        Orchestrator::Result.new(database: cluster.name, status: status,
                                 artifacts: [artifact], duration_seconds: duration)
      end

      def failed_result(cluster, error, started, log)
        duration = (monotonic - started).round(3)
        log.error("base backup failed", error: error.message, error_class: error.class.name)
        Orchestrator::Result.new(database: cluster.name, status: :failure, artifacts: [],
                                 error: error, duration_seconds: duration)
      end

      # pg_basebackup → bundle the output tree into one artifact → encrypt →
      # manifest → fan out. Compression is fixed to zip here: the bundle wraps
      # base.tar (already an archive) plus the backup_manifest, and zip is the
      # portable "one file a human can open anywhere" choice, matching how
      # directory-format dumps are packaged.
      def capture_and_store(cluster, staging, timestamp, began_at, log)
        datadir = File.join(staging, "base")
        run_pg_basebackup(cluster, datadir, timestamp, log)
        start = start_position(datadir)

        bundle = File.join(staging, "#{cluster.slug}-base-#{timestamp}.zip")
        Compress::Zip.new.compress_tree(datadir, bundle)
        final, encryption = maybe_encrypt(bundle, log)

        manifest = Manifest.for_artifact(final, base_manifest_attrs(cluster, encryption, began_at, start))
        manifest.write(Manifest.path_for(final))

        destinations = distribute(cluster, final, log)
        {
          artifact: File.basename(final), kind: "base",
          size_bytes: manifest.size_bytes, checksum: manifest.checksum,
          compression: "zip", encryption: encryption, destinations: destinations
        }
      end

      def base_manifest_attrs(cluster, encryption, began_at, start)
        {
          "kind" => "base", "database" => cluster.name, "dump_format" => "basebackup",
          "compression" => "zip", "encryption" => encryption,
          "started_at" => began_at.iso8601, "finished_at" => @clock.now.utc.iso8601,
          "server_version" => server_version(cluster), "timeline" => start[:timeline],
          "start_lsn" => start[:lsn], "start_segment" => start[:segment], "end_lsn" => start[:end_lsn]
        }
      end

      # The WAL range the base covers: the start position anchors coupled
      # retention (keep WAL from here), the end LSN is the consistency point —
      # the earliest instant recovery from this base can stop at, which base
      # selection compares against LSN targets. Read from the +backup_manifest+
      # pg_basebackup writes (its WAL-Ranges), so no separate query is needed.
      # Best-effort: a base without it simply won't drive WAL pruning.
      def start_position(datadir)
        data = JSON.parse(File.read(File.join(datadir, "backup_manifest")))
        range = Array(data["WAL-Ranges"]).first || {}
        lsn = range["Start-LSN"]
        timeline = range["Timeline"]
        { lsn: lsn, timeline: timeline, segment: Wal.lsn_to_segment(lsn, timeline), end_lsn: range["End-LSN"] }
      rescue StandardError => e
        @logger.warn("could not read base start position (WAL pruning disabled for this base)", error: e.message)
        {}
      end

      def run_pg_basebackup(cluster, datadir, timestamp, log)
        Dump::Runner.run!(
          "pg_basebackup",
          ["--pgdata=#{datadir}", "--format=tar", "--wal-method=fetch",
           "--checkpoint=fast", "--no-password", "--label=pgkeeper-#{timestamp}"],
          env: cluster.libpq_env, logger: log, label: "pg_basebackup",
          timeout: @config.timeout(:dump)
        )
      end

      def maybe_encrypt(path, log)
        return [path, "none"] if @encryptor.nil?

        dest = "#{path}.#{@encryptor.extension}"
        @encryptor.encrypt(path, dest)
        FileUtils.remove_entry(path)
        log.debug("encrypted base backup", type: @encryptor.name)
        [dest, @encryptor.name]
      end

      def distribute(cluster, final, log)
        remote = "#{cluster.slug}/base/#{File.basename(final)}"
        manifest_path = Manifest.path_for(final)

        @adapters.map do |adapter|
          adapter.upload(final, remote)
          adapter.upload(manifest_path, Manifest.path_for(remote))
          log.debug("stored", destination: adapter.name, remote: remote)
          Orchestrator::Destination.new(name: adapter.name, status: :ok)
        rescue StorageError => e
          log.error("destination failed", destination: adapter.name, error: e.message)
          Orchestrator::Destination.new(name: adapter.name, status: :failed, error: e.message)
        end
      end

      def server_version(cluster) = query(cluster, "SHOW server_version")
      def timeline(cluster) = query(cluster, "SELECT timeline_id FROM pg_control_checkpoint()")&.to_i

      def query(cluster, sql)
        out, _err, status = Subprocess.capture3(cluster.libpq_env, "psql", "-XtAc", sql,
                                                timeout: @config.timeout(:query))
        status.success? ? out.strip : nil
      rescue EnvironmentError, TimeoutError
        nil
      end

      def record_history(report, identifier, started_at, finished_at, log)
        History.new(File.join(@config.workdir, "history.sqlite3"), logger: log)
               .record(report, run_id: identifier, started_at: started_at, finished_at: finished_at)
      rescue StandardError => e
        log.warn("history unavailable (non-fatal)", error: e.message)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def run_id = format("%<t>s-%<pid>d", t: @clock.now.utc.strftime("%Y%m%dT%H%M%SZ"), pid: Process.pid)
    end
  end
end
