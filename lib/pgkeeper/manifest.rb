# frozen_string_literal: true

require "json"
require "digest"
require "time"
require "socket"

module PgKeeper
  # A per-backup metadata sidecar written next to the artifact as
  # +<artifact>.manifest.json+. It records everything a human (or a restore
  # tool) needs to trust and reconstruct a backup: what was dumped, with which
  # tool versions, how big it is, and its SHA-256 checksum.
  #
  # The checksum is the anchor of verification (Phase 6): re-hashing the artifact
  # and comparing against the manifest proves the bytes are intact.
  class Manifest
    SCHEMA_VERSION = 1
    SUFFIX = ".manifest.json"

    attr_reader :data

    def initialize(data = {})
      @data = data
    end

    # Build a manifest for a freshly written artifact, computing its size and
    # checksum from disk.
    def self.for_artifact(artifact_path, attributes = {})
      stat = File.stat(artifact_path)
      new(
        {
          "schema_version" => SCHEMA_VERSION,
          "pgkeeper_version" => PgKeeper::VERSION,
          "hostname" => safe_hostname,
          "artifact" => File.basename(artifact_path),
          "size_bytes" => stat.size,
          "checksum" => { "algorithm" => "sha256", "value" => sha256(artifact_path) }
        }.merge(stringify(attributes))
      )
    end

    def self.sha256(path)
      digest = Digest::SHA256.new
      File.open(path, "rb") { |f| digest.update(f.read(1 << 20)) until f.eof? }
      digest.hexdigest
    end

    def self.safe_hostname
      Socket.gethostname
    rescue StandardError
      "unknown"
    end

    def self.stringify(hash)
      JSON.parse(JSON.generate(hash))
    end

    # Path where this manifest should live, given the artifact path.
    def self.path_for(artifact_path)
      "#{artifact_path}#{SUFFIX}"
    end

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def checksum
      data.dig("checksum", "value")
    end

    def size_bytes
      data["size_bytes"]
    end

    def artifact
      data["artifact"]
    end

    # Whether a file on disk still matches the recorded checksum.
    def checksum_valid?(artifact_path)
      recorded = checksum
      return false if recorded.nil?

      self.class.sha256(artifact_path) == recorded
    end

    def write(path)
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, path)
      path
    end

    def to_h
      data
    end
  end
end
