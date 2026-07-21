# frozen_string_literal: true

require "zip"
require "fileutils"

module PgKeeper
  module Compress
    # zip compression via +rubyzip+. Produces a single-entry archive whose entry
    # name is the source filename with the +.zip+ suffix removed — so
    # +app.dump.zip+ contains one entry, +app.dump+. A zip artifact is the
    # friendliest for a human to open on any OS without extra tools.
    class Zip
      CHUNK = 1 << 20 # 1 MiB

      def name = "zip"
      def extension = "zip"
      def available? = true

      def compress(source, dest)
        entry_name = File.basename(source)
        ::Zip::File.open(dest, create: true) do |zip|
          zip.get_output_stream(entry_name) do |out|
            File.open(source, "rb") do |input|
              out.write(input.read(CHUNK)) until input.eof?
            end
          end
        end
        dest
      end

      def decompress(source, dest)
        ::Zip::File.open(source) do |zip|
          entry = zip.entries.first
          raise Error, "zip archive #{source} is empty" if entry.nil?

          entry.extract(dest) { true } # overwrite if present
        end
        dest
      end

      # Package a whole directory into a single zip file, preserving relative
      # paths. Used to turn a +pg_dump --format=directory+ output (a directory)
      # into one uploadable/encryptable artifact.
      def compress_tree(dir, dest)
        dir = File.expand_path(dir)
        ::Zip::File.open(dest, create: true) do |zip|
          Dir.glob(File.join(dir, "**", "**")).each do |path|
            rel = path.delete_prefix("#{dir}/")
            if File.directory?(path)
              zip.mkdir(rel) unless zip.find_entry(rel)
            else
              zip.add(rel, path)
            end
          end
        end
        dest
      end

      # Reverse {#compress_tree}: extract a zip archive into +dest_dir+,
      # recreating the directory structure. Used to restore a directory-format
      # dump before handing it to pg_restore.
      def decompress_tree(source, dest_dir)
        FileUtils.mkdir_p(dest_dir)
        ::Zip::File.open(source) do |zip|
          zip.each do |entry|
            target = File.join(dest_dir, entry.name)
            if entry.directory?
              FileUtils.mkdir_p(target)
            else
              FileUtils.mkdir_p(File.dirname(target))
              entry.extract(target) { true }
            end
          end
        end
        dest_dir
      end
    end
  end
end
