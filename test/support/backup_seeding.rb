# frozen_string_literal: true

require "json"

module PgKeeper
  # Test helper: writes realistic backup artifacts + manifests into a storage
  # root, so Catalog/Pruner tests can run without a database.
  module BackupSeeding
    # Seed one artifact (and its manifest) for a database at a given time.
    # Returns the remote artifact path.
    def seed_backup(root, database, started_at, kind: "database", verified_at: nil,
                    compression: "none", encryption: "none", dump_format: "custom")
      adapter = Storage::Local.new(root: root, logger: null_logger)
      label = started_at.utc.strftime("%Y-%m-%dT%H%M%SZ")
      suffix = kind == "globals" ? "-globals" : ""
      remote = "#{database}/#{database}#{suffix}-#{label}.dump"

      Dir.mktmpdir("pgkeeper-seed-") do |dir|
        artifact = File.join(dir, "artifact")
        File.binwrite(artifact, "dump-bytes-#{kind}-#{label}")
        adapter.upload(artifact, remote)

        manifest = File.join(dir, "manifest.json")
        data = manifest_data(database: database, kind: kind, started_at: started_at, artifact: artifact,
                             verified_at: verified_at, compression: compression,
                             encryption: encryption, dump_format: dump_format)
        File.write(manifest, JSON.generate(data))
        adapter.upload(manifest, "#{remote}#{Manifest::SUFFIX}")
      end
      remote
    end

    def manifest_data(database:, kind:, started_at:, artifact:, verified_at:, compression:, encryption:, dump_format:)
      data = {
        "schema_version" => 1, "database" => database, "kind" => kind,
        "started_at" => started_at.utc.iso8601, "finished_at" => started_at.utc.iso8601,
        "size_bytes" => File.size(artifact),
        "checksum" => { "algorithm" => "sha256", "value" => Manifest.sha256(artifact) },
        "compression" => compression, "encryption" => encryption, "dump_format" => dump_format
      }
      if verified_at
        data["verified_at"] = verified_at.utc.iso8601
        data["verified_tier"] = "structural"
      end
      data
    end
  end
end
