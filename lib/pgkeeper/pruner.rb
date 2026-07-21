# frozen_string_literal: true

module PgKeeper
  # Applies the retention policy to every destination, deleting backup sets the
  # policy doesn't keep. Defaults to a dry run — nothing is deleted unless
  # +apply: true+ — so a new policy can be previewed before it removes anything.
  #
  # Retention is enforced independently per destination (you might keep 7 days
  # locally but 30 in the cloud) and per database. The policy's safety rails
  # (never delete the newest backup, never prune to zero, never delete anything
  # newer than the last verified backup) are applied here via the catalog's
  # verification state.
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

      deletions = adapters.flat_map { |adapter| prune_destination(adapter, policy, only, apply) }
      Report.new(deletions: deletions, applied: apply, configured: policy.configured?)
    end

    private

    def prune_destination(adapter, policy, only, apply)
      catalog = Catalog.new(adapter)
      databases = filter(catalog.databases, only)

      databases.flat_map do |database|
        sets = catalog.backup_sets(database: database)
        protected_after = sets.select(&:verified?).map(&:timestamp).max
        plan = policy.partition(sets, protected_after: protected_after)
        plan.delete.map { |set| delete_or_preview(adapter, database, set, apply) }
      end
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
