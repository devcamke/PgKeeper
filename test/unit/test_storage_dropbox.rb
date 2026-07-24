# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"
require "webmock/minitest"

module PgKeeper
  # Exercises the real Dropbox adapter against a stateful, in-memory WebMock
  # store so every code path — single upload, chunked upload session, download,
  # list, delete, metadata — runs without a network or credentials, and the
  # adapter must satisfy the same storage contract as Local, S3, and Memory.
  class TestStorageDropbox < Minitest::Test
    include TestHelpers
    include StorageContract

    def setup
      WebMock.disable_net_connect!
      @store = {}
      @sessions = {}
      stub_dropbox
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def build_adapter
      Storage::Dropbox.new(root: "pgk", access_token: "test-token", logger: null_logger)
    end

    def test_name_reflects_the_root_folder
      assert_equal "dropbox:/pgk", build_adapter.name
    end

    def test_large_files_upload_through_a_chunked_session
      # A 30-byte payload with a 10-byte single-upload limit and 8-byte chunks
      # forces the session path (start → append → append → finish) and proves
      # the chunks reassemble in order — the mechanism that lifts Dropbox's
      # 150 MB single-request ceiling for multi-gigabyte dumps.
      adapter = Storage::Dropbox.new(root: "pgk", access_token: "test-token", logger: null_logger,
                                     single_upload_limit: 10, session_chunk: 8)
      payload = "0123456789abcdefghijklmnopqrst" # 30 bytes
      with_local_file(payload) do |src, dir|
        adapter.upload(src, "db/big.dump")

        assert_equal payload.b, @store["/pgk/db/big.dump"]

        out = File.join(dir, "restored.bin")
        adapter.download("db/big.dump", out)

        assert_equal payload, File.binread(out)
      end
    end

    def test_refresh_token_is_exchanged_for_an_access_token
      stub_request(:post, "https://api.dropboxapi.com/oauth2/token")
        .to_return(json_ok("access_token" => "minted-token"))
      adapter = Storage::Dropbox.new(root: "pgk", refresh_token: "rt", app_key: "ak", app_secret: "as",
                                     logger: null_logger)

      assert adapter.healthcheck
      assert_requested :post, "https://api.dropboxapi.com/oauth2/token"
    end

    def test_expired_access_token_is_reminted_before_reuse
      # expires_in below the refresh margin makes each minted token immediately
      # stale, so every use must exchange the refresh token again.
      stub_request(:post, "https://api.dropboxapi.com/oauth2/token")
        .to_return(json_ok("access_token" => "tok", "expires_in" => 30))
      adapter = Storage::Dropbox.new(root: "pgk", refresh_token: "rt", app_key: "ak", app_secret: "as",
                                     logger: null_logger)

      2.times { adapter.healthcheck }

      assert_requested :post, "https://api.dropboxapi.com/oauth2/token", times: 2
    end

    def test_fresh_access_token_is_reused_across_operations
      stub_request(:post, "https://api.dropboxapi.com/oauth2/token")
        .to_return(json_ok("access_token" => "tok", "expires_in" => 14_400))
      adapter = Storage::Dropbox.new(root: "pgk", refresh_token: "rt", app_key: "ak", app_secret: "as",
                                     logger: null_logger)

      2.times { adapter.healthcheck }

      assert_requested :post, "https://api.dropboxapi.com/oauth2/token", times: 1
    end

    def test_construction_requires_credentials
      assert_raises(ConfigError) { Storage::Dropbox.new(root: "pgk", logger: null_logger) }
    end

    private

    def stub_dropbox
      store = @store
      sessions = @sessions

      stub_content_uploads(store, sessions)
      stub_content_download(store)
      stub_metadata_endpoints(store)
      stub_check_user
    end

    def stub_content_uploads(store, sessions)
      stub_request(:post, "https://content.dropboxapi.com/2/files/upload").to_return do |req|
        path = arg(req)["path"]
        store[path] = req.body.b
        json_ok(file_meta(path, store[path].bytesize))
      end
      stub_request(:post, "https://content.dropboxapi.com/2/files/upload_session/start").to_return do |req|
        id = "sess-#{sessions.size + 1}"
        sessions[id] = req.body.b.dup
        json_ok("session_id" => id)
      end
      stub_request(:post, "https://content.dropboxapi.com/2/files/upload_session/append_v2").to_return do |req|
        sessions[arg(req)["cursor"]["session_id"]] << req.body.b
        json_ok({})
      end
      stub_request(:post, "https://content.dropboxapi.com/2/files/upload_session/finish").to_return do |req|
        a = arg(req)
        path = a["commit"]["path"]
        store[path] = sessions.delete(a["cursor"]["session_id"])
        json_ok(file_meta(path, store[path].bytesize))
      end
    end

    def stub_content_download(store)
      stub_request(:post, "https://content.dropboxapi.com/2/files/download").to_return do |req|
        data = store[arg(req)["path"]]
        data ? { status: 200, body: data } : conflict("path/not_found/")
      end
    end

    def stub_metadata_endpoints(store)
      stub_request(:post, "https://api.dropboxapi.com/2/files/delete_v2").to_return do |req|
        path = JSON.parse(req.body)["path"]
        store.key?(path) ? json_ok(file_meta(path, store.delete(path).bytesize)) : conflict("path_lookup/not_found/")
      end
      stub_request(:post, "https://api.dropboxapi.com/2/files/get_metadata").to_return do |req|
        path = JSON.parse(req.body)["path"]
        store.key?(path) ? json_ok(file_meta(path, store[path].bytesize)) : conflict("path/not_found/")
      end
      stub_request(:post, "https://api.dropboxapi.com/2/files/list_folder").to_return do |_req|
        json_ok("entries" => store.map { |path, bytes| file_meta(path, bytes.bytesize) },
                "has_more" => false, "cursor" => "")
      end
      stub_request(:post, "https://api.dropboxapi.com/2/files/list_folder/continue")
        .to_return(json_ok("entries" => [], "has_more" => false))
    end

    def stub_check_user
      stub_request(:post, "https://api.dropboxapi.com/2/check/user")
        .to_return { |req| json_ok("result" => JSON.parse(req.body)["query"]) }
    end

    def arg(request)
      JSON.parse(request.headers["Dropbox-Api-Arg"])
    end

    def json_ok(hash)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(hash) }
    end

    def file_meta(path, size)
      { ".tag" => "file", "name" => File.basename(path), "path_display" => path, "size" => size }
    end

    def conflict(summary)
      { status: 409, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("error_summary" => summary, "error" => {}) }
    end
  end
end
