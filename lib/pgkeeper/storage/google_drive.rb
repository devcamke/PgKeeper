# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "fileutils"

require "pgkeeper/storage/google_drive/service_account"

module PgKeeper
  module Storage
    # Google Drive storage via the Drive REST API v3 — no SDK, just Net::HTTP and
    # a service-account JWT signed with OpenSSL. Drive is ID-based rather than
    # path-based, so PgKeeper stores each artifact as a file whose *name* is the
    # full remote path ("db/app-2026.dump") inside one configured folder; that
    # maps the flat, prefix-listed key space the storage contract expects onto
    # Drive without a folder tree. Large artifacts stream through a resumable
    # upload session, so multi-gigabyte dumps upload with flat memory.
    #
    # Auth is a service account (`credentials_json` inline or a `credentials_file`
    # path); share the target folder with the service account's email and grant
    # it Editor. See docs/PROVIDERS.md#google-drive.
    class GoogleDrive < Base
      API_BASE = "https://www.googleapis.com"
      UPLOAD_URI = "https://www.googleapis.com/upload/drive/v3/files"
      CHUNK = 8 * 1024 * 1024 # multiple of 256 KiB, as resumable uploads require
      TIMEOUT = 60

      # A non-2xx Drive response. Carries the HTTP status so {#transient_error?}
      # can decide whether the operation is worth retrying.
      class ApiError < StorageError
        attr_reader :status

        def initialize(message, status:, destination: nil)
          @status = status
          super(message, destination: destination)
        end
      end

      def initialize(folder_id:, credentials_json: nil, credentials_file: nil,
                     chunk_size: CHUNK, timeout: TIMEOUT, **)
        super(**)
        raise ConfigError, "google_drive storage requires a `folder_id`" if folder_id.to_s.empty?

        @folder_id = folder_id
        @chunk_size = chunk_size
        @timeout = timeout
        @credentials = ServiceAccount.from_config(json: credentials_json, file: credentials_file, timeout: timeout)
      end

      def default_name = "google_drive:#{@folder_id}"

      def healthcheck
        api_get("/drive/v3/files/#{@folder_id}", { "fields" => "id", "supportsAllDrives" => "true" })
        true
      rescue ApiError => e
        raise StorageError.new("#{name}: folder #{@folder_id} not reachable: #{e.message}", destination: name)
      end

      private

      # Upload with overwrite semantics: reuse the existing file's id if this path
      # was uploaded before, otherwise create a new file in the folder.
      def do_upload(local_path, remote_path)
        existing = find_id(remote_path)
        session_uri = existing ? resumable_update(existing, remote_path) : resumable_create(remote_path)
        upload_media(session_uri, local_path)
      end

      def do_download(remote_path, local_path)
        id = find_id(remote_path)
        raise StorageError.new("#{name}: #{remote_path} not found", destination: name) if id.nil?

        FileUtils.mkdir_p(File.dirname(local_path))
        uri = drive_uri("/drive/v3/files/#{id}", { "alt" => "media", "supportsAllDrives" => "true" })
        http_for(uri).start do |http|
          http.request(authorized(Net::HTTP::Get.new(uri))) { |response| stream_to_file(response, local_path, remote_path) }
        end
      end

      def do_delete(remote_path)
        id = find_id(remote_path)
        return if id.nil? # deletion is idempotent

        uri = drive_uri("/drive/v3/files/#{id}", { "supportsAllDrives" => "true" })
        response = perform(uri, authorized(Net::HTTP::Delete.new(uri)))
        code = response.code.to_i
        return if [200, 204].include?(code)

        raise ApiError.new("#{name}: delete of #{remote_path} failed: HTTP #{code} #{response.body}",
                           status: code, destination: name)
      end

      def do_list(prefix)
        entries = []
        page = nil
        loop do
          result = list_page(page)
          result.fetch("files", []).each { |f| entries << Entry.new(path: f["name"], size_bytes: f["size"].to_i) }
          page = result["nextPageToken"]
          break unless page
        end
        entries.select { |e| e.path.start_with?(prefix) }.sort_by(&:path)
      end

      def remote_size(remote_path)
        id = find_id(remote_path)
        return nil if id.nil?

        api_get("/drive/v3/files/#{id}", { "fields" => "size", "supportsAllDrives" => "true" })["size"]&.to_i
      rescue ApiError
        nil
      end

      def transient_error?(error)
        return true if error.is_a?(ApiError) && [429, 500, 502, 503].include?(error.status)

        error.is_a?(Timeout::Error) || error.is_a?(SystemCallError) ||
          error.is_a?(SocketError) || error.is_a?(IOError)
      end

      # -- Drive queries -----------------------------------------------------

      def list_page(page_token)
        params = {
          "q" => "'#{@folder_id}' in parents and trashed = false",
          "fields" => "nextPageToken, files(name, size)",
          "pageSize" => "1000", "spaces" => "drive",
          "supportsAllDrives" => "true", "includeItemsFromAllDrives" => "true"
        }
        params["pageToken"] = page_token if page_token
        api_get("/drive/v3/files", params)
      end

      # Resolve a remote path (stored as the Drive file name) to its file id.
      def find_id(remote_path)
        params = {
          "q" => "name = '#{escape_query(remote_path)}' and '#{@folder_id}' in parents and trashed = false",
          "fields" => "files(id)", "pageSize" => "1", "spaces" => "drive",
          "supportsAllDrives" => "true", "includeItemsFromAllDrives" => "true"
        }
        api_get("/drive/v3/files", params).fetch("files", []).first&.fetch("id", nil)
      end

      def escape_query(value)
        value.gsub(/(['\\])/) { "\\#{Regexp.last_match(1)}" }
      end

      # -- resumable upload --------------------------------------------------

      def resumable_create(remote_path)
        metadata = { "name" => remote_path, "parents" => [@folder_id] }
        initiate_resumable(Net::HTTP::Post.new(resumable_uri), metadata)
      end

      def resumable_update(id, remote_path)
        uri = URI("#{UPLOAD_URI}/#{id}?uploadType=resumable&supportsAllDrives=true")
        initiate_resumable(Net::HTTP::Patch.new(uri), { "name" => remote_path })
      end

      def resumable_uri = URI("#{UPLOAD_URI}?uploadType=resumable&supportsAllDrives=true")

      def initiate_resumable(request, metadata)
        request["Content-Type"] = "application/json; charset=UTF-8"
        request.body = JSON.generate(metadata)
        response = perform(URI(request.uri.to_s), authorized(request))
        code = response.code.to_i
        location = response["location"]
        return location if code.between?(200, 299) && location

        raise ApiError.new("#{name}: could not start upload: HTTP #{code} #{response.body}",
                           status: code, destination: name)
      end

      # Stream the file to the session URI in bounded chunks so memory never
      # holds more than one chunk, however large the dump.
      def upload_media(session_uri, local_path)
        size = File.size(local_path)
        return finalize_empty(session_uri) if size.zero?

        File.open(local_path, "rb") do |io|
          offset = 0
          while offset < size
            chunk = io.read(@chunk_size)
            put_chunk(session_uri, chunk, offset, size)
            offset += chunk.bytesize
          end
        end
      end

      def put_chunk(session_uri, chunk, offset, total)
        uri = URI(session_uri)
        request = Net::HTTP::Put.new(uri)
        request["Content-Range"] = "bytes #{offset}-#{offset + chunk.bytesize - 1}/#{total}"
        request.body = chunk
        response = perform(uri, request)
        code = response.code.to_i
        last = offset + chunk.bytesize >= total
        return if code == 308 && !last
        return if last && code.between?(200, 299)

        raise ApiError.new("#{name}: upload chunk failed: HTTP #{code} #{response.body}",
                           status: code, destination: name)
      end

      def finalize_empty(session_uri)
        uri = URI(session_uri)
        request = Net::HTTP::Put.new(uri)
        request["Content-Range"] = "bytes */0"
        response = perform(uri, request)
        code = response.code.to_i
        return if code.between?(200, 299)

        raise ApiError.new("#{name}: empty upload failed: HTTP #{code}", status: code, destination: name)
      end

      # -- HTTP --------------------------------------------------------------

      def api_get(path, params)
        uri = drive_uri(path, params)
        parse_json(perform(uri, authorized(Net::HTTP::Get.new(uri))), path)
      end

      def drive_uri(path, params)
        uri = URI("#{API_BASE}#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?
        uri
      end

      def authorized(request)
        request["Authorization"] = "Bearer #{@credentials.access_token}"
        request
      end

      def stream_to_file(response, local_path, remote_path)
        code = response.code.to_i
        unless code.between?(200, 299)
          raise ApiError.new("#{name}: download of #{remote_path} failed: HTTP #{code} #{response.read_body}",
                             status: code, destination: name)
        end
        File.open(local_path, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
      end

      def perform(uri, request)
        http_for(uri).start { |http| http.request(request) }
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http
      end

      def parse_json(response, path)
        code = response.code.to_i
        raise ApiError.new("#{name}: #{path} failed: HTTP #{code} #{response.body}", status: code, destination: name) \
          unless code.between?(200, 299)

        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end
    end
  end
end
