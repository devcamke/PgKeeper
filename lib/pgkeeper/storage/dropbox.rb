# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"
require "stringio"

module PgKeeper
  module Storage
    # Dropbox storage via the HTTP API v2 — no SDK, just Net::HTTP and a bearer
    # token, so it needs no optional gem. Small artifacts go in a single
    # +/files/upload+; anything above Dropbox's 150 MB single-request ceiling
    # streams through an upload session (start → append → finish), so
    # multi-gigabyte dumps upload with flat memory.
    #
    # Auth is either a long-lived +access_token+, or a +refresh_token+ plus the
    # app's +app_key+/+app_secret+ — the modern short-lived-token flow, exchanged
    # for an access token on first use and cached for the process.
    class Dropbox < Base
      API_HOST = "api.dropboxapi.com"
      CONTENT_HOST = "content.dropboxapi.com"
      # Dropbox rejects a single /files/upload above 150 MB; larger files must go
      # through an upload session.
      SINGLE_UPLOAD_LIMIT = 150 * 1024 * 1024
      SESSION_CHUNK = 96 * 1024 * 1024
      TIMEOUT = 60

      # A non-2xx Dropbox response. Carries the HTTP status so {#transient_error?}
      # can decide whether the operation is worth retrying.
      class ApiError < StorageError
        attr_reader :status

        def initialize(message, status:, destination: nil)
          @status = status
          super(message, destination: destination)
        end
      end

      def initialize(root: "", access_token: nil, refresh_token: nil, app_key: nil, app_secret: nil,
                     single_upload_limit: SINGLE_UPLOAD_LIMIT, session_chunk: SESSION_CHUNK, timeout: TIMEOUT, **)
        super(**)
        @root = normalize_root(root)
        @access_token = access_token
        @refresh_token = refresh_token
        @app_key = app_key
        @app_secret = app_secret
        @single_upload_limit = single_upload_limit
        @session_chunk = session_chunk
        @timeout = timeout
        validate_credentials!
      end

      def default_name = "dropbox:#{@root.empty? ? '/' : @root}"

      # Cheap authenticated liveness probe: /check/user echoes its query back, so
      # a correct echo proves both connectivity and a valid token.
      def healthcheck
        body = rpc("/2/check/user", { "query" => "pgkeeper" })
        return true if body["result"] == "pgkeeper"

        raise StorageError.new("#{name}: unexpected check/user response", destination: name)
      end

      private

      def do_upload(local_path, remote_path)
        path = dropbox_path(remote_path)
        if File.size(local_path) <= @single_upload_limit
          upload_single(local_path, path)
        else
          upload_session(local_path, path)
        end
      end

      def do_download(remote_path, local_path)
        FileUtils.mkdir_p(File.dirname(local_path))
        arg = { "path" => dropbox_path(remote_path) }
        content_download("/2/files/download", arg, local_path, remote_path)
      end

      def do_delete(remote_path)
        rpc("/2/files/delete_v2", { "path" => dropbox_path(remote_path) })
      rescue ApiError => e
        # Deletion is idempotent — a path that's already gone is success.
        raise unless not_found?(e)
      end

      def do_list(prefix)
        entries = []
        result = list_folder
        loop do
          collect_files(result["entries"], entries)
          break unless result["has_more"]

          result = rpc("/2/files/list_folder/continue", { "cursor" => result["cursor"] })
        end
        entries.select { |e| e.path.start_with?(prefix) }.sort_by(&:path)
      end

      def remote_size(remote_path)
        rpc("/2/files/get_metadata", { "path" => dropbox_path(remote_path) })["size"]
      rescue ApiError
        nil
      end

      def transient_error?(error)
        return true if error.is_a?(ApiError) && [429, 500, 502, 503].include?(error.status)

        error.is_a?(Timeout::Error) || error.is_a?(SystemCallError) ||
          error.is_a?(SocketError) || error.is_a?(IOError)
      end

      # -- uploads -----------------------------------------------------------

      def upload_single(local_path, path)
        arg = { "path" => path, "mode" => "overwrite", "mute" => true }
        File.open(local_path, "rb") do |io|
          content_upload("/2/files/upload", arg, body_stream: io, length: File.size(local_path))
        end
      end

      # Stream the file to Dropbox in bounded chunks so memory never holds more
      # than one chunk, however large the dump.
      def upload_session(local_path, path)
        size = File.size(local_path)
        File.open(local_path, "rb") do |io|
          session_id = session_start(io.read(@session_chunk) || "")
          offset = io.pos
          while offset < size
            chunk = io.read(@session_chunk)
            break if chunk.nil?

            session_append(session_id, offset, chunk)
            offset += chunk.bytesize
          end
          session_finish(session_id, offset, path)
        end
      end

      def session_start(chunk)
        body = content_upload("/2/files/upload_session/start", { "close" => false },
                              body_stream: StringIO.new(chunk), length: chunk.bytesize)
        body.fetch("session_id")
      end

      def session_append(session_id, offset, chunk)
        arg = { "cursor" => { "session_id" => session_id, "offset" => offset }, "close" => false }
        content_upload("/2/files/upload_session/append_v2", arg,
                       body_stream: StringIO.new(chunk), length: chunk.bytesize)
      end

      def session_finish(session_id, offset, path)
        arg = {
          "cursor" => { "session_id" => session_id, "offset" => offset },
          "commit" => { "path" => path, "mode" => "overwrite", "mute" => true }
        }
        content_upload("/2/files/upload_session/finish", arg, body_stream: StringIO.new(+""), length: 0)
      end

      # -- listing helpers ---------------------------------------------------

      def list_folder
        rpc("/2/files/list_folder", { "path" => @root, "recursive" => true })
      rescue ApiError => e
        # A root folder that's never been written to doesn't exist yet — an
        # empty listing, not an error.
        raise unless not_found?(e)

        { "entries" => [], "has_more" => false }
      end

      def collect_files(dropbox_entries, into)
        Array(dropbox_entries).each do |entry|
          next unless entry[".tag"] == "file"

          remote = remote_from_dropbox(entry["path_display"])
          into << Entry.new(path: remote, size_bytes: entry["size"]) if remote
        end
      end

      # -- HTTP --------------------------------------------------------------

      # JSON-in, JSON-out RPC endpoint on the API host.
      def rpc(path, params)
        uri = URI("https://#{API_HOST}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{bearer_token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(params)
        parse_json(perform(uri, request), path)
      end

      # Upload content endpoint: args ride in the Dropbox-API-Arg header, the
      # body carries the bytes.
      def content_upload(path, arg, body_stream:, length:)
        uri = URI("https://#{CONTENT_HOST}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{bearer_token}"
        request["Dropbox-API-Arg"] = JSON.generate(arg)
        request["Content-Type"] = "application/octet-stream"
        request.body_stream = body_stream
        request.content_length = length
        parse_json(perform(uri, request), path)
      end

      # Download content endpoint, streamed straight to disk so large restores
      # never buffer the whole artifact in memory.
      def content_download(path, arg, local_path, remote_path)
        uri = URI("https://#{CONTENT_HOST}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{bearer_token}"
        request["Dropbox-API-Arg"] = JSON.generate(arg)
        http_for(uri).start do |http|
          http.request(request) do |response|
            stream_to_file(response, local_path, remote_path)
          end
        end
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

      # -- auth --------------------------------------------------------------

      def bearer_token
        @bearer_token ||= @access_token || fetch_access_token
      end

      # Exchange a long-lived refresh token for a short-lived access token.
      def fetch_access_token
        uri = URI("https://#{API_HOST}/oauth2/token")
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(@app_key, @app_secret)
        request.set_form_data("grant_type" => "refresh_token", "refresh_token" => @refresh_token)
        body = parse_json(perform(uri, request), "oauth2/token")
        body.fetch("access_token")
      end

      # -- path mapping ------------------------------------------------------

      # Dropbox uses "" for the app root (not "/"); everything else is an
      # absolute, slash-prefixed folder path with no trailing slash.
      def normalize_root(root)
        value = root.to_s.strip
        return "" if value.empty? || value == "/"

        value = "/#{value}" unless value.start_with?("/")
        value.chomp("/")
      end

      def dropbox_path(remote_path)
        "#{@root}/#{remote_path}".gsub(%r{/{2,}}, "/")
      end

      def remote_from_dropbox(path_display)
        prefix = @root.empty? ? "/" : "#{@root}/"
        return nil unless path_display.to_s.start_with?(prefix)

        path_display.delete_prefix(prefix)
      end

      def not_found?(error)
        error.status == 409 && error.message.include?("not_found")
      end

      def validate_credentials!
        return if @access_token
        return if @refresh_token && @app_key && @app_secret

        raise ConfigError,
              "dropbox storage requires `access_token`, or `refresh_token` + `app_key` + `app_secret`"
      end
    end
  end
end
