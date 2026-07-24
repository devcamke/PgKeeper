# frozen_string_literal: true

require "securerandom"
require "tempfile"
require "tmpdir"
require "zip"

module PgKeeper
  module Web
    # The artifact download endpoints, mixed into {App}: stream one cataloged
    # artifact, or zip a whole backup set. Both resolve their target against
    # the destination's catalog — arbitrary paths 404 — so only objects
    # PgKeeper itself wrote are ever served.
    #
    # Relies on the host object's @dashboard and the not_found helper.
    module Downloads
      # Read size when folding a downloaded file into a set zip.
      ZIP_CHUNK = 1 << 20 # 1 MiB

      # Stream one artifact (or manifest) to the browser. The path must name an
      # object the destination's catalog knows about — arbitrary paths 404.
      def download(request)
        found = @dashboard.find_artifact(request.params["destination"].to_s, request.params["path"].to_s)
        return not_found if found.nil?

        adapter, _artifact = found
        path = request.params["path"].to_s
        tmp = Tempfile.create("pgkeeper-download-")
        tmp.close
        adapter.download(path, tmp.path)
        [200, download_headers(path, File.size(tmp.path)), FileBody.new(tmp.path)]
      end

      def download_headers(path, size)
        {
          "content-type" => "application/octet-stream",
          "content-length" => size.to_s,
          "content-disposition" => %(attachment; filename="#{File.basename(path).gsub(/["\\]/, '')}")
        }
      end

      # Stream every artifact in one backup set — each dump plus its manifest —
      # zipped into a single download. Like {#download}, the set is resolved
      # against the catalog, so only cataloged objects are ever served.
      def download_set(request)
        found = @dashboard.find_backup_set(
          request.params["destination"].to_s,
          request.params["database"].to_s,
          request.params["timestamp"].to_s
        )
        return not_found if found.nil?

        adapter, set = found
        zip_path = build_set_zip(adapter, set)
        [200, zip_headers("#{set.database}-#{set.label}.zip", File.size(zip_path)), FileBody.new(zip_path)]
      end

      # Download each of the set's files and stream them into a fresh zip, one
      # entry per file (basenames are unique within a set). Each source is
      # unlinked as soon as it is folded in, so only the finished zip lingers —
      # and {FileBody} deletes that once the response is flushed.
      def build_set_zip(adapter, set)
        zip_path = File.join(Dir.tmpdir, "pgkeeper-set-#{SecureRandom.hex(8)}.zip")
        ::Zip::File.open(zip_path, create: true) do |zip|
          set.artifacts.flat_map { |a| [a.remote_path, a.manifest_path] }.compact.each do |remote_path|
            stream_into_zip(zip, adapter, remote_path)
          end
        end
        zip_path
      end

      def stream_into_zip(zip, adapter, remote_path)
        tmp = Tempfile.create("pgkeeper-zip-src-")
        tmp.close
        adapter.download(remote_path, tmp.path)
        zip.get_output_stream(File.basename(remote_path)) do |out|
          File.open(tmp.path, "rb") { |io| out.write(io.read(ZIP_CHUNK)) until io.eof? }
        end
      ensure
        File.unlink(tmp.path) if tmp
      end

      def zip_headers(filename, size)
        {
          "content-type" => "application/zip",
          "content-length" => size.to_s,
          "content-disposition" => %(attachment; filename="#{filename.gsub(/["\\]/, '')}")
        }
      end

      # Rack body that streams a temp file in chunks and deletes it when the
      # server closes the response, so multi-GB dumps never load into memory.
      class FileBody
        CHUNK = 64 * 1024

        def initialize(path)
          @path = path
        end

        def each
          File.open(@path, "rb") do |io|
            while (chunk = io.read(CHUNK))
              yield chunk
            end
          end
        end

        def close
          File.unlink(@path)
        rescue StandardError
          nil
        end
      end
    end
  end
end
