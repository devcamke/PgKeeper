# frozen_string_literal: true

require "fileutils"
require "pgkeeper/compress/gzip"
require "pgkeeper/compress/zip"
require "pgkeeper/compress/zstd"

module PgKeeper
  # Compression backends. Every compressor implements the same tiny interface so
  # the backup pipeline can treat them interchangeably:
  #
  #   compressor.compress(source_path, dest_path) # => dest_path
  #   compressor.decompress(source_path, dest_path)
  #   compressor.extension                         # filename suffix, e.g. "gz"
  #   compressor.name                              # "gzip" / "zip" / "zstd" / "none"
  #
  # +none+ is the identity transform, used when compression is disabled or when
  # the dump format (custom/directory) is already compressed by pg_dump.
  module Compress
    # Compressor names in the order we advertise them.
    NAMES = %w[none gzip zip zstd].freeze

    module_function

    # Build a compressor by name. Raises {ConfigError} for unknown names and
    # {EnvironmentError} if the backend's tooling isn't available.
    def for(name)
      case name.to_s
      when "none" then None.new
      when "gzip" then Gzip.new
      when "zip"  then Zip.new
      when "zstd" then Zstd.new
      else
        raise ConfigError, "unknown compression: #{name.inspect} (expected one of #{NAMES.join(', ')})"
      end
    end

    # Whether the named compressor can actually run in this environment (zstd
    # needs its binary; the others are always available).
    def available?(name)
      self.for(name).available?
    rescue ConfigError
      false
    end

    # The no-op compressor: hands the bytes through untouched.
    class None
      def name = "none"
      def extension = nil
      def available? = true

      def compress(source, dest)
        FileUtils.cp(source, dest)
        dest
      end

      def decompress(source, dest)
        FileUtils.cp(source, dest)
        dest
      end
    end
  end
end
