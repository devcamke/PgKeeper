# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "erb"
require "fileutils"

require "pgkeeper/storage/sharepoint/app_token"

module PgKeeper
  module Storage
    # SharePoint / OneDrive storage via the Microsoft Graph API — no SDK, just
    # Net::HTTP and an OAuth2 client-credentials token. Graph addresses items by
    # path (`/drives/{id}/root:/db/app.dump:`), so PgKeeper's flat, prefix-listed
    # keys map straight onto a drive with no id-resolution dance. Small artifacts
    # go in a single PUT; anything above the simple-upload limit streams through
    # a Graph upload session, so multi-gigabyte dumps upload with flat memory.
    #
    # +drive_id+ names the target document library (SharePoint) or user drive
    # (OneDrive); the app registration behind +tenant_id+/+client_id+/
    # +client_secret+ needs `Files.ReadWrite.All` application permission with
    # admin consent. See docs/PROVIDERS.md#sharepoint--onedrive.
    class SharePoint < Base
      GRAPH = "https://graph.microsoft.com/v1.0"
      # Microsoft recommends an upload session above ~4 MB; below it a single PUT
      # is fine.
      SIMPLE_UPLOAD_LIMIT = 4 * 1024 * 1024
      CHUNK = 10 * 1024 * 1024 # multiple of 320 KiB, as Graph upload sessions require
      TIMEOUT = 60

      # A non-2xx Graph response. Carries the HTTP status so {#transient_error?}
      # can decide whether the operation is worth retrying.
      class ApiError < StorageError
        attr_reader :status

        def initialize(message, status:, destination: nil)
          @status = status
          super(message, destination: destination)
        end
      end

      def initialize(drive_id:, tenant_id: nil, client_id: nil, client_secret: nil, root: "",
                     simple_upload_limit: SIMPLE_UPLOAD_LIMIT, chunk_size: CHUNK, timeout: TIMEOUT, **)
        super(**)
        raise ConfigError, "sharepoint storage requires a `drive_id`" if drive_id.to_s.empty?

        @drive_id = drive_id
        @root = normalize_root(root)
        @simple_upload_limit = simple_upload_limit
        @chunk_size = chunk_size
        @timeout = timeout
        @auth = AppToken.new(tenant_id: tenant_id, client_id: client_id, client_secret: client_secret, timeout: timeout)
      end

      def default_name = "sharepoint:#{@drive_id}"

      def healthcheck
        graph_get("#{drive_base}/root", { "$select" => "id" })
        true
      rescue ApiError => e
        raise StorageError.new("#{name}: drive #{@drive_id} not reachable: #{e.message}", destination: name)
      end

      private

      def do_upload(local_path, remote_path)
        size = File.size(local_path)
        if size <= @simple_upload_limit
          simple_upload(local_path, remote_path)
        else
          session_upload(local_path, remote_path, size)
        end
      end

      def do_download(remote_path, local_path)
        url = get_item(remote_path)["@microsoft.graph.downloadUrl"]
        raise StorageError.new("#{name}: #{remote_path} has no download URL", destination: name) if url.nil?

        FileUtils.mkdir_p(File.dirname(local_path))
        uri = URI(url) # pre-authenticated, transient download URL — no auth header
        http_for(uri).start { |http| http.request(Net::HTTP::Get.new(uri)) { |r| stream_to_file(r, local_path, remote_path) } }
      rescue ApiError => e
        raise StorageError.new("#{name}: #{remote_path} not found", destination: name) if e.status == 404

        raise
      end

      def do_delete(remote_path)
        uri = URI(item_ref(remote_path))
        response = perform(uri, authorized(Net::HTTP::Delete.new(uri)))
        code = response.code.to_i
        return if [200, 204, 404].include?(code) # deletion is idempotent

        raise ApiError.new("#{name}: delete of #{remote_path} failed: HTTP #{code} #{response.body}",
                           status: code, destination: name)
      end

      # Graph has no flat prefix listing, so enumerate the whole drive with a
      # delta query (recursive, paginated) and reconstruct each file's path.
      def do_list(prefix)
        entries = []
        url = "#{drive_base}/root/delta"
        while url
          body = graph_get(url)
          body.fetch("value", []).each do |item|
            path = relative_path(item)
            entries << Entry.new(path: path, size_bytes: item["size"].to_i) if item["file"] && path
          end
          url = body["@odata.nextLink"]
        end
        entries.select { |e| e.path.start_with?(prefix) }.sort_by(&:path)
      end

      def remote_size(remote_path)
        get_item(remote_path)["size"]
      rescue StandardError
        nil
      end

      def transient_error?(error)
        return true if error.is_a?(ApiError) && [429, 500, 502, 503].include?(error.status)

        error.is_a?(Timeout::Error) || error.is_a?(SystemCallError) ||
          error.is_a?(SocketError) || error.is_a?(IOError)
      end

      # -- uploads -----------------------------------------------------------

      def simple_upload(local_path, remote_path)
        uri = URI("#{item_ref(remote_path)}:/content")
        request = Net::HTTP::Put.new(uri)
        request["Content-Type"] = "application/octet-stream"
        File.open(local_path, "rb") do |io|
          request.body_stream = io
          request.content_length = File.size(local_path)
          parse_json(perform(uri, authorized(request)), "upload")
        end
      end

      def session_upload(local_path, remote_path, size)
        session_url = create_upload_session(remote_path)
        File.open(local_path, "rb") do |io|
          offset = 0
          while offset < size
            chunk = io.read(@chunk_size)
            put_session_chunk(session_url, chunk, offset, size)
            offset += chunk.bytesize
          end
        end
      end

      def create_upload_session(remote_path)
        uri = URI("#{item_ref(remote_path)}:/createUploadSession")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate("item" => { "@microsoft.graph.conflictBehavior" => "replace" })
        parse_json(perform(uri, authorized(request)), "createUploadSession").fetch("uploadUrl")
      end

      def put_session_chunk(session_url, chunk, offset, total)
        uri = URI(session_url)
        request = Net::HTTP::Put.new(uri)
        request["Content-Length"] = chunk.bytesize.to_s
        request["Content-Range"] = "bytes #{offset}-#{offset + chunk.bytesize - 1}/#{total}"
        request.body = chunk
        response = perform(uri, request) # session URL is pre-authenticated
        code = response.code.to_i
        return if code.between?(200, 299) # 202 for intermediate chunks, 200/201 on the last

        raise ApiError.new("#{name}: upload chunk failed: HTTP #{code} #{response.body}",
                           status: code, destination: name)
      end

      # -- path mapping ------------------------------------------------------

      def get_item(remote_path)
        graph_get(item_ref(remote_path))
      end

      def item_ref(remote_path)
        "#{drive_base}/root:/#{encode(drive_path(remote_path))}"
      end

      def drive_base = "#{GRAPH}/drives/#{@drive_id}"

      def drive_path(remote_path)
        [@root, remote_path].reject { |part| part.to_s.empty? }.join("/")
      end

      def encode(path)
        path.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
      end

      # Rebuild a file's key from a delta item's parent path + name, then strip
      # the configured root. Returns nil for items outside our root.
      def relative_path(item)
        parent = item.dig("parentReference", "path").to_s
        rel = parent.split("root:", 2)[1].to_s
        full = "#{rel}/#{item['name']}".gsub(%r{/{2,}}, "/").sub(%r{\A/}, "")
        strip_root(full)
      end

      def strip_root(full)
        return full if @root.empty?

        prefix = "#{@root}/"
        full.start_with?(prefix) ? full.delete_prefix(prefix) : nil
      end

      def normalize_root(root)
        root.to_s.strip.delete_prefix("/").chomp("/")
      end

      # -- HTTP --------------------------------------------------------------

      def graph_get(url, params = {})
        uri = URI(url)
        uri.query = URI.encode_www_form(params) unless params.empty?
        parse_json(perform(uri, authorized(Net::HTTP::Get.new(uri))), url)
      end

      def authorized(request)
        request["Authorization"] = "Bearer #{@auth.token}"
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

      def parse_json(response, context)
        code = response.code.to_i
        unless code.between?(200, 299)
          raise ApiError.new("#{name}: #{context} failed: HTTP #{code} #{response.body}",
                             status: code, destination: name)
        end

        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end
    end
  end
end
