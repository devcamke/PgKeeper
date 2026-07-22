# frozen_string_literal: true

require "time"

module PgKeeper
  module Web
    # Read-only data assembly for the dashboard pages and the JSON API. Reads
    # exactly what the CLI writes — the SQLite run-history and the manifest
    # sidecars on the storage destinations — so the browser and the terminal
    # can never disagree.
    #
    # Destination reads are individually rescued: the dashboard's job is to
    # show that a destination is down, not to go down with it.
    class Dashboard
      # One overview row per configured database.
      DatabaseStatus = Struct.new(:name, :last_run, :next_run_at, :last_verified_at,
                                  :verified_tier, :size_trend, keyword_init: true) do
        # Traffic light: green (last run succeeded), yellow (partial or never
        # run), red (last run failed).
        def light
          return "yellow" if last_run.nil?

          { "success" => "green", "partial" => "yellow", "failure" => "red" }.fetch(last_run.status, "yellow")
        end
      end

      # One row per storage destination.
      DestinationStatus = Struct.new(:name, :type, :healthy, :error, :set_count, :total_bytes,
                                     keyword_init: true)

      def initialize(config, logger: PgKeeper.logger)
        @config = config
        @logger = logger
      end

      def history
        History.new(File.join(@config.workdir, "history.sqlite3"), logger: @logger)
      end

      def overview_rows
        last = history.last_per_database.to_h { |row| [row.database, row] }
        verified = verified_by_database
        @config.databases.map do |db|
          DatabaseStatus.new(
            name: db.name, last_run: last[db.name],
            next_run_at: next_run_for(db),
            last_verified_at: verified.dig(db.name, :at), verified_tier: verified.dig(db.name, :tier),
            size_trend: history.recent(limit: 24, database: db.name).map(&:total_bytes).reverse
          )
        end
      end

      def destination_rows
        @config.storage.map { |target| destination_row(target) }
      end

      def recent_runs(database: nil, limit: 50)
        history.recent(limit: limit, database: database)
      end

      def run_detail(run_id)
        history.runs_for(run_id)
      end

      # Backup sets grouped per destination: [[adapter_name, sets], ...].
      # Destinations that can't be read (missing SDK, outage) yield an empty
      # set list plus an error message.
      def sets_by_destination
        @config.storage.map do |target|
          adapter = Storage.build(target, logger: @logger)
          [adapter.name, Catalog.new(adapter).backup_sets.sort_by(&:timestamp).reverse, nil]
        rescue EnvironmentError, StorageError => e
          ["#{target['type']}:?", [], e.message]
        end
      end

      def retention_preview
        Pruner.new(@config, logger: @logger).prune(apply: false)
      end

      # Locate one artifact by destination name + remote path, returning
      # [adapter, artifact] — or nil unless the path names a cataloged artifact
      # or its manifest. Downloads are allowlisted against the catalog so the
      # endpoint can never be steered at an arbitrary path.
      def find_artifact(destination_name, path)
        @config.storage.each do |target|
          adapter = Storage.build(target, logger: @logger)
          next unless adapter.name == destination_name

          hit = Catalog.new(adapter).artifacts.find do |a|
            [a.remote_path, a.manifest_path].include?(path)
          end
          return [adapter, hit] if hit
        rescue EnvironmentError, StorageError
          next
        end
        nil
      end

      def api_status
        {
          "generated_at" => Time.now.utc.iso8601,
          "databases" => overview_rows.map { |row| api_database(row) },
          "destinations" => destination_rows.map { |d| api_destination(d) }
        }
      end

      def api_runs(database: nil, limit: 50)
        { "runs" => recent_runs(database: database, limit: limit).map { |row| api_run(row) } }
      end

      def api_run(row)
        {
          "run_id" => row.run_id, "database" => row.database, "status" => row.status,
          "started_at" => row.started_at, "finished_at" => row.finished_at,
          "duration_seconds" => row.duration_seconds, "artifact_count" => row.artifact_count,
          "total_bytes" => row.total_bytes, "destinations" => row.destinations, "error" => row.error
        }
      end

      private

      def api_database(row)
        {
          "name" => row.name, "light" => row.light,
          "last_run" => row.last_run && api_run(row.last_run),
          "next_run_at" => row.next_run_at&.iso8601,
          "last_verified_at" => row.last_verified_at&.iso8601,
          "verified_tier" => row.verified_tier
        }
      end

      def api_destination(dest)
        {
          "name" => dest.name, "type" => dest.type, "healthy" => dest.healthy,
          "error" => dest.error, "backup_sets" => dest.set_count, "total_bytes" => dest.total_bytes
        }
      end

      def destination_row(target)
        adapter = Storage.build(target, logger: @logger)
        sets = Catalog.new(adapter).backup_sets
        adapter.healthcheck
        DestinationStatus.new(name: adapter.name, type: target["type"], healthy: true,
                              set_count: sets.length, total_bytes: sets.sum(&:total_size))
      rescue EnvironmentError, StorageError => e
        DestinationStatus.new(name: adapter&.name || "#{target['type']}:?", type: target["type"],
                              healthy: false, error: e.message, set_count: 0, total_bytes: 0)
      end

      def next_run_for(db)
        entry = Scheduler.entries(@config).find { |e| e.only.nil? || e.only.include?(db.name) }
        entry&.schedule&.next_time
      rescue StandardError
        nil
      end

      # Latest verification state per database, read from the primary (local
      # preferred) destination's manifests.
      def verified_by_database
        target = @config.storage.find { |t| t["type"] == "local" } || @config.storage.first
        return {} if target.nil?

        adapter = Storage.build(target, logger: @logger)
        Catalog.new(adapter).backup_sets.each_with_object({}) do |set, acc|
          next unless set.verified?

          current = acc[set.database]
          next if current && current[:at] > set.verified_at

          acc[set.database] = { at: set.verified_at, tier: set.primary&.verified_tier }
        end
      rescue EnvironmentError, StorageError
        {}
      end
    end
  end
end
