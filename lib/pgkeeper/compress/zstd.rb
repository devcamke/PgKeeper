# frozen_string_literal: true

require "open3"

module PgKeeper
  module Compress
    # Zstandard compression by shelling out to the +zstd+ binary — the same
    # "don't reimplement, drive the real tool" philosophy as the dump engine. It
    # gives the best size/speed trade-off for large dumps, but only when the
    # binary is installed; {#available?} reports whether it is.
    class Zstd
      def name = "zstd"
      def extension = "zst"

      def available?
        !which("zstd").nil?
      end

      def compress(source, dest)
        ensure_available!
        run!("zstd", "-q", "-f", "-o", dest, source)
        dest
      end

      def decompress(source, dest)
        ensure_available!
        run!("zstd", "-d", "-q", "-f", "-o", dest, source)
        dest
      end

      private

      def ensure_available!
        return if available?

        raise EnvironmentError, "zstd binary not found on PATH; install zstd or choose a different compression"
      end

      def run!(*argv)
        _out, err, status = Open3.capture3(*argv)
        return if status.success?

        raise Error, "#{argv.first} failed (#{status.exitstatus}): #{err.strip}"
      end

      def which(tool)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).find do |dir|
          path = File.join(dir, tool)
          File.executable?(path) && File.file?(path)
        end
      end
    end
  end
end
