# frozen_string_literal: true

module PgKeeper
  # Applies the retention policy to every destination, deleting backup sets the
  # policy doesn't keep. Defaults to a dry run — nothing is deleted unless
  # +apply: true+ — so a new policy can be previewed before it removes anything.
  #
  # Retention is enforced independently per destination (you might keep 7 days
  # locally but 30 in the cloud) and per database. The policy's safety rails
  # (never delete the newest backup, never prune to zero, never delete the last
  # verified backup or anything newer than it) are applied here via the
  # catalog's verification state.
  class Pruner
    # One backup set slated for deletion (or deleted, when applied).
    Deletion = Struct.new(:destination, :database, :label, :size_bytes, :objects, keyword_init: true)

    Report = Struct.new(:deletions, :applied, :configured, keyword_init: true) do
      def count = deletions.length
      def total_bytes = deletions.sum { |d| d.size_bytes.to_i }
      def any? = !deletions.empty?
    end

    def initialize(config, logger: PgKeeper.logger)
      @config = config
      @logger = logger
    end

    def prune(apply: false, only: nil)
      policy = Retention.build(@config.retention)
      adapters = Storage.build_all(@config.storage, logger: @logger)

      deletions = adapters.flat_map do |adapter|
        prune_destination(adapter, policy, only, apply) + prune_pitr(adapter, only, apply)
      end
      Report.new(deletions: deletions, applied: apply, configured: policy.configured?)
    end

    private

    def prune_destination(adapter, policy, only, apply)
      catalog = Catalog.new(adapter)
      # PITR clusters have their own coupled retention below; keep base/WAL
      # artifacts out of the logical-dump GFS policy entirely.
      cluster_names = @config.pitr_clusters.map(&:name)
      databases = filter(catalog.databases, only) - cluster_names

      databases.flat_map do |database|
        sets = catalog.backup_sets(database: database)
        protected_after = sets.select(&:verified?).map(&:timestamp).max
        plan = policy.partition(sets, protected_after: protected_after)
        plan.delete.map { |set| delete_or_preview(adapter, database, set, apply) }
      end
    end

    # Coupled base + WAL retention per PITR cluster: never strand a base or the
    # WAL a surviving base needs, never prune below the recovery window.
    def prune_pitr(adapter, only, apply)
      catalog = Catalog.new(adapter)
      clusters(only).flat_map do |cluster|
        artifacts = catalog.artifacts(database: cluster.name)
        plan = PITR::Retention.plan(
          bases: artifacts.select { |a| a.kind == "base" },
          wals: artifacts.select { |a| a.kind == "wal" },
          window_seconds: cluster.pitr.recovery_window_seconds, now: Time.now.utc
        )
        (plan.bases + plan.wals).map { |artifact| delete_pitr(adapter, cluster.name, artifact, apply) }
      end
    end

    def clusters(only)
      pitr = @config.pitr_clusters
      return pitr if only.nil? || only.empty?

      pitr.select { |cluster| Array(only).include?(cluster.name) }
    end

    def delete_pitr(adapter, cluster, artifact, apply)
      objects = [artifact.remote_path, artifact.manifest_path]
      if apply
        objects.each { |object| adapter.delete(object) }
        @logger.info("pruned #{artifact.kind}", destination: adapter.name, cluster: cluster,
                                                label: pitr_label(artifact))
      end
      Deletion.new(destination: adapter.name, database: cluster, label: pitr_label(artifact),
                   size_bytes: artifact.size_bytes, objects: objects)
    end

    def pitr_label(artifact)
      return "wal #{artifact.segment}" if artifact.kind == "wal"

      "base #{artifact.timestamp.strftime('%Y-%m-%dT%H%M%SZ')}"
    end

    def delete_or_preview(adapter, database, set, apply)
      objects = set.artifacts.flat_map { |a| [a.remote_path, a.manifest_path] }
      if apply
        objects.each { |obj| adapter.delete(obj) }
        @logger.info("pruned backup", destination: adapter.name, database: database, label: set.label)
      end
      Deletion.new(destination: adapter.name, database: database, label: set.label,
                   size_bytes: set.total_size, objects: objects)
    end

    def filter(databases, only)
      return databases if only.nil? || only.empty?

      databases & Array(only)
    end
  end
end
