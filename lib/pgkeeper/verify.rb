# frozen_string_literal: true

require "open3"
require "tmpdir"
require "json"
require "fileutils"

module PgKeeper
  # Verifies that stored backups are actually good — because a backup you haven't
  # restored is not a backup. Three escalating tiers:
  #
  #   Tier 1 (checksum):   re-hash every artifact and compare to its manifest.
  #   Tier 2 (structural): reverse the pipeline and prove the archive is readable
  #                        (pg_restore --list for custom/directory; non-empty SQL
  #                        for plain).
  #   Tier 3 (deep):       restore into a throwaway scratch database, run a sanity
  #                        query, then drop it. Enabled with +deep: true+.
  #
  # On success the backup's manifest is stamped with +verified_at+/+verified_tier+
  # (re-uploaded to the destination), which feeds `list` and the retention
  # "don't prune newer than the last verified backup" safety rail.
  class Verifier
    Result = Struct.new(:database, :label, :tier, :status, :detail, keyword_init: true) do
      def ok? = status == :ok
    end

    TIER_NAME = { 1 => "checksum", 2 => "structural", 3 => "deep" }.freeze

    def initialize(config, logger: PgKeeper.logger, clock: Time)
      @config = config
      @logger = logger
      @clock = clock
      @restorer = Restorer.new(config, logger: logger)
    end

    # Verify selected backups on the primary destination. +selector+ is "latest"
    # (default), "all", or a timestamp label / prefix.
    def verify(selector: "latest", deep: false, only: nil)
      adapter = primary_adapter
      catalog = Catalog.new(adapter)
      sets = select_sets(catalog, selector, only)
      raise Error, "no matching backups found to verify" if sets.empty?

      sets.map { |set| verify_set(adapter, set, deep) }
    end

    private

    # Prefer a local destination (fast, no egress); otherwise the first one.
    def primary_adapter
      target = @config.storage.find { |t| t["type"] == "local" } || @config.storage.first
      Storage.build(target, logger: @logger)
    end

    def select_sets(catalog, selector, only)
      databases = only && !only.empty? ? Array(only) : catalog.databases
      databases.flat_map do |database|
        sets = catalog.backup_sets(database: database)
        case selector.to_s
        when "latest", "" then [sets.last].compact
        when "all" then sets
        else sets.select { |s| s.label == selector || s.label.start_with?(selector.to_s) }
        end
      end
    end

    def verify_set(adapter, set, deep)
      FileUtils.mkdir_p(@config.workdir)
      Dir.mktmpdir("pgkeeper-verify-", @config.workdir) do |workdir|
        tier1 = tier1_checksum(adapter, set, workdir)
        return result(set, 1, :fail, tier1) unless tier1 == :ok

        materialized = @restorer.materialize(set.primary, adapter, workdir)
        tier2 = tier2_structural(materialized)
        return result(set, 2, :fail, tier2) unless tier2 == :ok

        tier = 2
        if deep
          tier3 = tier3_deep_restore(set, materialized)
          return result(set, 3, :fail, tier3) unless tier3 == :ok

          tier = 3
        end

        mark_verified(adapter, set, tier)
        result(set, tier, :ok, "verified")
      end
    end

    # Tier 1: re-hash every artifact and compare to the recorded checksum.
    def tier1_checksum(adapter, set, workdir)
      set.artifacts.each do |artifact|
        next if artifact.checksum.nil?

        local = File.join(workdir, "check-#{File.basename(artifact.remote_path)}")
        adapter.download(artifact.remote_path, local)
        actual = Manifest.sha256(local)
        return "checksum mismatch for #{File.basename(artifact.remote_path)}" unless actual == artifact.checksum
      ensure
        FileUtils.rm_f(local) if local
      end
      :ok
    end

    # Tier 2: prove the materialized dump is a readable archive.
    def tier2_structural(materialized)
      case materialized[:format]
      when "plain"
        body = File.read(materialized[:path], 4096)
        body.strip.empty? ? "plain dump is empty" : :ok
      else
        _out, err, status = Open3.capture3("pg_restore", "--list", materialized[:path])
        status.success? ? :ok : "pg_restore --list failed: #{err.strip.lines.last&.strip}"
      end
    end

    # Tier 3: restore into a scratch database, sanity-check, drop it.
    def tier3_deep_restore(set, materialized)
      connection = @config.database(set.database)
      return "no connection config for #{set.database}; cannot deep-verify" if connection.nil?

      scratch = "pgkeeper_verify_#{@clock.now.to_i}_#{rand(1000)}"
      admin = connection.libpq_env
      create_scratch(admin, scratch)
      begin
        restore_into(connection, scratch, materialized)
        sanity_query(admin, scratch)
      ensure
        drop_scratch(admin, scratch)
      end
    rescue Error => e
      e.message
    end

    def create_scratch(admin, scratch)
      run_sql!(admin, "CREATE DATABASE #{scratch}")
    end

    def drop_scratch(admin, scratch)
      run_sql!(admin.merge("PGDATABASE" => "postgres"), "DROP DATABASE IF EXISTS #{scratch}")
    rescue StandardError
      nil
    end

    def restore_into(connection, scratch, materialized)
      env = connection.libpq_env.merge("PGDATABASE" => scratch)
      if materialized[:format] == "plain"
        capture!(env, "psql", "--no-password", "-v", "ON_ERROR_STOP=1", "-f", materialized[:path])
      else
        capture!(env, "pg_restore", "--no-password", "--dbname=#{scratch}", materialized[:path])
      end
    end

    # Confirm the freshly restored database is functional by querying it. The
    # restore step itself proves the archive applies cleanly; this proves the
    # result is a live, queryable database. An empty source (zero user tables)
    # is a perfectly valid backup, so table count is logged, not required.
    def sanity_query(admin, scratch)
      out, status = Open3.capture2e(admin.merge("PGDATABASE" => scratch), "psql", "-XtAc", <<~SQL)
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
      SQL
      return "restored database is not queryable" unless status.success?

      @logger.debug("deep verify sanity query", scratch: scratch, user_tables: out.strip.to_i)
      :ok
    end

    def mark_verified(adapter, set, tier)
      verified_at = @clock.now.utc.iso8601
      set.artifacts.each do |artifact|
        update_manifest(adapter, artifact.manifest_path) do |data|
          data.merge("verified_at" => verified_at, "verified_tier" => TIER_NAME[tier])
        end
      end
      @logger.info("marked verified", database: set.database, label: set.label, tier: TIER_NAME[tier])
    end

    def update_manifest(adapter, manifest_path)
      Dir.mktmpdir("pgkeeper-verify-mark-") do |dir|
        local = File.join(dir, "manifest.json")
        adapter.download(manifest_path, local)
        data = yield(JSON.parse(File.read(local)))
        File.write(local, "#{JSON.pretty_generate(data)}\n")
        adapter.upload(local, manifest_path)
      end
    end

    def run_sql!(env, sql)
      capture!(env.merge("PGDATABASE" => env["PGDATABASE"] || "postgres"), "psql", "-XtAc", sql)
    end

    def capture!(env, tool, *)
      _out, err, status = Open3.capture3(env, tool, *)
      raise Error, "#{tool} failed: #{err.strip.lines.last&.strip}" unless status.success?
    rescue Errno::ENOENT
      raise EnvironmentError, "#{tool} not found on PATH"
    end

    def result(set, tier, status, detail)
      Result.new(database: set.database, label: set.label, tier: TIER_NAME[tier], status: status, detail: detail)
    end
  end
end
