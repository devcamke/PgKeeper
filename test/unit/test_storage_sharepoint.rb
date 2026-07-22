# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"
require "webmock/minitest"
require "cgi"

module PgKeeper
  # Exercises the real SharePoint/OneDrive adapter against a stateful, in-memory
  # WebMock store modelling the Microsoft Graph drive API — token exchange,
  # simple upload, chunked upload session, download via the item's transient
  # URL, delta listing, and delete — so every code path runs without a network
  # or credentials, and the adapter must satisfy the same storage contract as
  # Local, S3, Dropbox, Google Drive, and Memory.
  class TestStorageSharePoint < Minitest::Test
    include TestHelpers
    include StorageContract

    DRIVE = "DRV"
    ROOT = "pgk"

    def setup
      WebMock.disable_net_connect!
      @store = {}    # drive-relative path ("pgk/db/app.dump") => bytes
      @sessions = {} # upload token => { path:, buffer: }
      stub_graph
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def build_adapter
      Storage::SharePoint.new(drive_id: DRIVE, tenant_id: "t", client_id: "c", client_secret: "s",
                              root: ROOT, logger: null_logger)
    end

    def test_name_reflects_the_drive
      assert_equal "sharepoint:DRV", build_adapter.name
    end

    def test_large_files_upload_through_a_chunked_session
      # A 30-byte payload with a 10-byte simple-upload limit and 8-byte chunks
      # forces the upload-session path (createUploadSession → chunked PUTs) and
      # proves the chunks reassemble in order — the mechanism that streams
      # multi-gigabyte dumps with flat memory.
      adapter = Storage::SharePoint.new(drive_id: DRIVE, tenant_id: "t", client_id: "c", client_secret: "s",
                                        root: ROOT, logger: null_logger, simple_upload_limit: 10, chunk_size: 8)
      payload = "0123456789abcdefghijklmnopqrst" # 30 bytes
      with_local_file(payload) do |src, dir|
        adapter.upload(src, "db/big.dump")

        assert_equal payload, @store["pgk/db/big.dump"]

        out = File.join(dir, "restored.bin")
        adapter.download("db/big.dump", out)

        assert_equal payload, File.binread(out)
      end
    end

    def test_missing_credentials_rejected
      assert_raises(ConfigError) { Storage::SharePoint.new(drive_id: DRIVE, logger: null_logger) }
    end

    private

    def stub_graph
      store = @store
      sessions = @sessions

      stub_token
      stub_simple_upload(store)
      stub_create_session
      stub_session_put(store, sessions)
      stub_download(store)
      stub_item_metadata(store)
      stub_delta(store)
      stub_delete(store)
      stub_healthcheck
    end

    def stub_token
      stub_request(:post, %r{https://login\.microsoftonline\.com/.+/oauth2/v2\.0/token})
        .to_return(json_ok("access_token" => "graph-token", "expires_in" => 3600, "token_type" => "Bearer"))
    end

    def stub_simple_upload(store)
      stub_request(:put, %r{/drives/#{DRIVE}/root:/.+:/content\z}).to_return do |req|
        path = item_path(req.uri)
        store[path] = req.body.to_s.b
        json_ok(item_body(path, store[path].bytesize))
      end
    end

    def stub_create_session
      stub_request(:post, %r{/drives/#{DRIVE}/root:/.+:/createUploadSession\z}).to_return do |req|
        token = "up-#{@sessions.size + 1}"
        @sessions[token] = { path: item_path(req.uri), buffer: +"" }
        json_ok("uploadUrl" => "https://graph.microsoft.com/uploadsession/#{token}")
      end
    end

    def stub_session_put(store, sessions)
      stub_request(:put, %r{https://graph\.microsoft\.com/uploadsession/}).to_return do |req|
        token = req.uri.path.split("/").last
        session = sessions.fetch(token)
        session[:buffer] << req.body.to_s.b
        if final_chunk?(req.headers["Content-Range"])
          store[session[:path]] = session[:buffer]
          json_ok(item_body(session[:path], session[:buffer].bytesize))
        else
          { status: 202, headers: {} }
        end
      end
    end

    def stub_download(store)
      stub_request(:get, %r{https://graph\.microsoft\.com/download/}).to_return do |req|
        path = CGI.unescape(req.uri.path.split("/").last)
        data = store[path]
        data ? { status: 200, body: data } : { status: 404, headers: {} }
      end
    end

    def stub_item_metadata(store)
      stub_request(:get, %r{/drives/#{DRIVE}/root:/[^:?]+(\?.*)?\z}).to_return do |req|
        path = item_path(req.uri)
        store.key?(path) ? json_ok(item_body(path, store[path].bytesize, download: true)) : not_found
      end
    end

    def stub_delta(store)
      stub_request(:get, %r{/drives/#{DRIVE}/root/delta}).to_return do |_req|
        json_ok("value" => store.map { |path, bytes| delta_item(path, bytes.bytesize) })
      end
    end

    def stub_delete(store)
      stub_request(:delete, %r{/drives/#{DRIVE}/root:/[^:?]+\z}).to_return do |req|
        path = item_path(req.uri)
        store.key?(path) ? store.delete(path) && { status: 204, headers: {} } : not_found
      end
    end

    def stub_healthcheck
      stub_request(:get, %r{/drives/#{DRIVE}/root(\?.*)?\z}).to_return(json_ok("id" => "root"))
    end

    # -- helpers -----------------------------------------------------------

    # Extract the drive-relative path from a Graph item URL of the form
    # `.../root:/<path>[:/relationship][?query]`.
    def item_path(uri)
      raw = uri.to_s[%r{/root:/(.+?)(?::/[^?]+)?(?:\?.*)?\z}, 1]
      raw.split("/").map { |segment| CGI.unescape(segment) }.join("/")
    end

    def item_body(path, size, download: false)
      body = { "id" => "item-#{path.hash.abs}", "name" => File.basename(path), "size" => size,
               "file" => { "mimeType" => "application/octet-stream" } }
      body["@microsoft.graph.downloadUrl"] = "https://graph.microsoft.com/download/#{CGI.escape(path)}" if download
      body
    end

    def delta_item(path, size)
      dir = File.dirname(path)
      parent = dir == "." ? "/drive/root:" : "/drive/root:/#{dir}"
      { "name" => File.basename(path), "size" => size,
        "file" => { "mimeType" => "application/octet-stream" },
        "parentReference" => { "path" => parent } }
    end

    def final_chunk?(content_range)
      return true if content_range.nil?

      range, total = content_range.sub("bytes ", "").split("/")
      range.split("-").last.to_i + 1 >= total.to_i
    end

    def json_ok(hash)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(hash) }
    end

    def not_found
      { status: 404, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("error" => { "code" => "itemNotFound" }) }
    end
  end
end
