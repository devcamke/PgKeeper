# frozen_string_literal: true

require "time"

module PgKeeper
  module PITR
    # A point-in-time view of one cluster's recovery readiness, computed from the
    # catalog alone — no live server. It answers the two questions PITR silently
    # fails on between restores:
    #
    #   * **WAL lag** — how old is the newest archived segment? If archiving has
    #     stalled, every second widens the gap between "last safe point" and now,
    #     and nothing says so until a restore comes up short.
    #   * **Recovery window** — how far back could a restore actually reach? The
    #     span from the oldest base backup to now. If it has shrunk below the
    #     window the cluster promises, the promise is already broken.
    #
    # This is the data behind `status`, the dashboard PITR panel, and the
    # Prometheus WAL metrics — one computation, three surfaces, so they can never
    # disagree. The dead-man's switch is {Snapshot#stalled?}: lag past the
    # cluster's +max_lag+ threshold.
    class Health
      Snapshot = Struct.new(
        :cluster, :base_count, :wal_count,
        :last_base_at, :oldest_base_at,
        :last_wal_at, :last_wal_segment,
        :lag_seconds, :max_lag_seconds,
        :recovery_window_seconds, :promised_window_seconds,
        keyword_init: true
      ) do
        def base? = !last_base_at.nil?
        def wal? = !last_wal_at.nil?

        # The dead-man's switch. False (not firing) when there's no threshold to
        # cross or no WAL yet to measure — an unconfigured or brand-new cluster
        # isn't "stalled", it's just unmonitored (see {#monitored?}).
        def stalled?
          return false if max_lag_seconds.nil? || lag_seconds.nil?

          lag_seconds > max_lag_seconds
        end

        # A dead-man's switch is armed only when a threshold is set.
        def monitored? = !max_lag_seconds.nil?

        # The reachable window has fallen below what the cluster promises.
        def window_short?
          return false if promised_window_seconds.nil? || recovery_window_seconds.nil?

          recovery_window_seconds < promised_window_seconds
        end

        # Green only when there's a base, archived WAL, no stall, and the window
        # holds. Anything less is yellow/red for the caller to color.
        def ok? = base? && wal? && !stalled? && !window_short?

        # Traffic light shared by the terminal, the dashboard, and the API: red
        # when stalled or missing a base/WAL, yellow when the reachable window is
        # below its promise, green otherwise.
        def light
          return "red" if stalled? || !base? || !wal?
          return "yellow" if window_short?

          "green"
        end
      end

      EPOCH = Time.at(0).utc

      def initialize(config, logger: PgKeeper.logger)
        @config = config
        @logger = logger
        @adapters = Storage.build_all(@config.storage, logger: @logger)
      end

      # A snapshot per PITR-enabled cluster, in config order.
      def snapshots(now: Time.now.utc)
        @config.pitr_clusters.map { |cluster| snapshot(cluster, now: now) }
      end

      def snapshot(cluster, now: Time.now.utc)
        artifacts = Inventory.artifacts(cluster, @adapters)
        bases = Inventory.bases(artifacts).sort_by { |a| a.timestamp || EPOCH }
        wals = Inventory.wal(artifacts)
        newest_wal = wals.max_by { |a| a.timestamp || EPOCH }
        oldest_base = bases.first
        last_base = bases.last

        Snapshot.new(
          cluster: cluster.name, base_count: bases.length, wal_count: wals.length,
          last_base_at: last_base&.timestamp, oldest_base_at: oldest_base&.timestamp,
          last_wal_at: newest_wal&.timestamp, last_wal_segment: newest_wal&.segment,
          lag_seconds: age(newest_wal&.timestamp, now), max_lag_seconds: cluster.pitr.max_lag_seconds,
          recovery_window_seconds: age(oldest_base&.timestamp, now),
          promised_window_seconds: cluster.pitr.recovery_window_seconds
        )
      end

      private

      def age(time, now)
        return nil if time.nil?

        [(now - time).to_i, 0].max
      end
    end
  end
end
