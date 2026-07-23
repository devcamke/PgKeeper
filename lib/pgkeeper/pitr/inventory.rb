# frozen_string_literal: true

module PgKeeper
  module PITR
    # Reads a cluster's PITR artifacts — base backups and archived WAL — from
    # every configured destination, deduped by remote path. This is the one
    # catalog read shared by `verify --pitr` (Stage 5) and the observability
    # surface (Stage 6): status, the dashboard PITR panel, and the WAL metrics
    # all see the same artifacts, so the terminal and the browser never disagree.
    #
    # A destination that can't be read (missing SDK, outage) contributes nothing
    # rather than failing the whole read — the point of these views is to show
    # trouble, not to go dark with a broken destination.
    module Inventory
      module_function

      def artifacts(cluster, adapters)
        seen = {}
        adapters.flat_map do |adapter|
          Catalog.new(adapter).artifacts(database: cluster.name).filter_map do |artifact|
            next if seen[artifact.remote_path]

            seen[artifact.remote_path] = true
            artifact
          end
        rescue EnvironmentError, StorageError
          []
        end
      end

      def bases(artifacts) = artifacts.select { |a| a.kind == "base" }

      def wal(artifacts) = artifacts.select { |a| a.kind == "wal" }
    end
  end
end
