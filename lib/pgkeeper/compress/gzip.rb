# frozen_string_literal: true

require "zlib"

module PgKeeper
  module Compress
    # gzip compression via the stdlib +zlib+. Streams in fixed-size chunks so a
    # large dump never has to be held in memory all at once.
    class Gzip
      CHUNK = 1 << 20 # 1 MiB

      def name = "gzip"
      def extension = "gz"
      def available? = true

      def compress(source, dest)
        File.open(source, "rb") do |input|
          Zlib::GzipWriter.open(dest) do |gz|
            gz.write(input.read(CHUNK)) until input.eof?
          end
        end
        dest
      end

      def decompress(source, dest)
        Zlib::GzipReader.open(source) do |gz|
          File.open(dest, "wb") do |out|
            while (chunk = gz.read(CHUNK))
              out.write(chunk)
            end
          end
        end
        dest
      end
    end
  end
end
