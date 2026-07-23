# frozen_string_literal: true

require "json"
require "time"
require "tmpdir"

module PgKeeper
  # Reads the backups stored on a single destination by loading their manifest
  # sidecars, and groups them into per-database backup sets.
  #
  # A "backup set" is one backup instance for a database: its dump plus, when
  # configured, the cluster globals captured in the same run (they share a
  # +started_at+ timestamp). Retention, verification, and listing all operate on
  # backup sets.
  class Catalog
    # A single stored artifact, hydrated from its manifest.
    Artifact = Struct.new(
      :database, :kind, :timestamp, :remote_path, :manifest_path,
      :size_bytes, :checksum, :compression, :encryption, :dump_format,
      :verified_at, :verified_tier,
      # PITR (Phase 12): a base backup records the LSN/segment its recovery
      # begins at; a WAL artifact records its own segment name.
      :start_lsn, :start_segment, :segment,
      keyword_init: true
    )

    # One backup instance for a database.
    BackupSet = Struct.new(:database, :timestamp, :artifacts, keyword_init: true) do
      # The main database dump (globals are secondary).
      def primary
        artifacts.find { |a| a.kind == "database" } || artifacts.first
      end

      def verified_at
        primary&.verified_at
      end

      def verified?
        !verified_at.nil?
      end

      def total_size
        artifacts.sum { |a| a.size_bytes.to_i }
      end

      # Stable label, e.g. 2026-07-21T031500Z.
      def label
        timestamp.strftime("%Y-%m-%dT%H%M%SZ")
      end
    end

    def initialize(adapter)
      @adapter = adapter
    end

    # All artifacts on the destination, optionally filtered to one database.
    def artifacts(database: nil)
      @adapter.list("")
              .select { |entry| entry.path.end_with?(Manifest::SUFFIX) }
              .filter_map { |entry| load_artifact(entry.path) }
              .select { |artifact| database.nil? || artifact.database == database }
    end

    # Backup sets, grouped by (database, timestamp), oldest first.
    def backup_sets(database: nil)
      artifacts(database: database)
        .group_by { |a| [a.database, a.timestamp] }
        .map { |(db, ts), arts| BackupSet.new(database: db, timestamp: ts, artifacts: arts.sort_by(&:kind)) }
        .sort_by(&:timestamp)
    end

    # Distinct database names present on the destination.
    def databases
      artifacts.map(&:database).compact.uniq.sort
    end

    private

    def load_artifact(manifest_path)
      data = read_manifest(manifest_path)
      return nil if data.nil?

      Artifact.new(
        database: data["database"], kind: data["kind"],
        timestamp: parse_time(data["started_at"]),
        remote_path: manifest_path.delete_suffix(Manifest::SUFFIX),
        manifest_path: manifest_path,
        size_bytes: data["size_bytes"], checksum: data.dig("checksum", "value"),
        compression: data["compression"], encryption: data["encryption"],
        dump_format: data["dump_format"],
        verified_at: parse_time(data["verified_at"]), verified_tier: data["verified_tier"],
        start_lsn: data["start_lsn"], start_segment: data["start_segment"], segment: data["segment"]
      )
    end

    def read_manifest(manifest_path)
      Dir.mktmpdir("pgkeeper-catalog-") do |dir|
        local = File.join(dir, "manifest.json")
        @adapter.download(manifest_path, local)
        JSON.parse(File.read(local))
      end
    rescue StandardError
      nil
    end

    def parse_time(value)
      value && Time.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
