# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"
require "webmock/minitest"
require "openssl"
require "cgi"

module PgKeeper
  # Exercises the real Google Drive adapter against a stateful, in-memory WebMock
  # store modelling Drive's file API — token exchange, resumable upload sessions,
  # media download, name-scoped listing, and delete — so every code path runs
  # without a network or credentials, and the adapter must satisfy the same
  # storage contract as Local, S3, Dropbox, and Memory.
  class TestStorageGoogleDrive < Minitest::Test
    include TestHelpers
    include StorageContract

    # One RSA key for the whole case: generating per test is needlessly slow, and
    # the stub never verifies the JWT signature.
    KEY = OpenSSL::PKey::RSA.new(2048)

    def setup
      WebMock.disable_net_connect!
      @files = {}    # name => { id:, bytes: }
      @sessions = {} # session token => { name:, id:, buffer: }
      @seq = 0
      stub_google
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def credentials_json
      JSON.generate("client_email" => "sa@proj.iam.gserviceaccount.com", "private_key" => KEY.to_pem)
    end

    def build_adapter
      Storage::GoogleDrive.new(folder_id: "FOLDER", credentials_json: credentials_json, logger: null_logger)
    end

    def test_name_reflects_the_folder
      assert_equal "google_drive:FOLDER", build_adapter.name
    end

    def test_reupload_overwrites_the_existing_file
      with_local_file("first") { |src, _| adapter.upload(src, "db/app.dump") }
      original_id = @files["db/app.dump"][:id]
      with_local_file("second") { |src, _| adapter.upload(src, "db/app.dump") }

      assert_equal "second", @files["db/app.dump"][:bytes]
      assert_equal original_id, @files["db/app.dump"][:id], "overwrite reuses the file id"
      assert_equal 1, @files.size
    end

    def test_large_files_upload_through_a_resumable_session
      # A 20-byte payload with 8-byte chunks forces the resumable path to send
      # multiple Content-Range chunks (308 → 308 → 200) that reassemble in
      # order — the mechanism that streams multi-gigabyte dumps with flat memory.
      adapter = Storage::GoogleDrive.new(folder_id: "FOLDER", credentials_json: credentials_json,
                                         logger: null_logger, chunk_size: 8)
      payload = "0123456789abcdefghij" # 20 bytes
      with_local_file(payload) do |src, dir|
        adapter.upload(src, "db/big.dump")

        assert_equal payload, @files["db/big.dump"][:bytes]

        out = File.join(dir, "restored.bin")
        adapter.download("db/big.dump", out)

        assert_equal payload, File.binread(out)
      end
    end

    def test_credentials_can_come_from_a_file
      in_tmpdir do |dir|
        path = File.join(dir, "sa.json")
        File.write(path, credentials_json)
        adapter = Storage::GoogleDrive.new(folder_id: "FOLDER", credentials_file: path, logger: null_logger)

        assert adapter.healthcheck
      end
    end

    def test_expired_token_is_reminted_before_reuse
      # expires_in below the refresh margin makes each minted token immediately
      # stale, so every use must exchange the JWT again.
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(json_ok("access_token" => "gd-token", "expires_in" => 30, "token_type" => "Bearer"))

      2.times { adapter.healthcheck }

      assert_requested :post, "https://oauth2.googleapis.com/token", times: 2
    end

    def test_fresh_token_is_reused_across_operations
      2.times { adapter.healthcheck }

      assert_requested :post, "https://oauth2.googleapis.com/token", times: 1
    end

    def test_upload_succeeds_when_the_size_check_gets_a_5xx
      # A transient 5xx on the post-upload size check must degrade to "size
      # unknown" (verification skipped), not fail a fully-successful upload.
      stub_request(:get, %r{https://www\.googleapis\.com/drive/v3/files/[^/?]+})
        .to_return(status: 500, body: "boom")
      with_local_file("data") do |src, _dir|
        result = adapter.upload(src, "db/app.dump")

        assert_equal 4, result.size_bytes
        assert_equal "data", @files["db/app.dump"][:bytes]
      end
    end

    def test_missing_credentials_rejected
      assert_raises(ConfigError) { Storage::GoogleDrive.new(folder_id: "FOLDER", logger: null_logger) }
    end

    def test_missing_folder_rejected
      assert_raises(ConfigError) { Storage::GoogleDrive.new(folder_id: "", credentials_json: credentials_json) }
    end

    private

    def stub_google
      files = @files
      sessions = @sessions

      stub_token
      stub_resumable_initiate(sessions, files)
      stub_resumable_put(sessions, files)
      stub_files_query(files)
      stub_file_by_id(files)
    end

    def stub_token
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(json_ok("access_token" => "gd-token", "expires_in" => 3600, "token_type" => "Bearer"))
    end

    def stub_resumable_initiate(sessions, files)
      stub_request(:post, %r{https://www\.googleapis\.com/upload/drive/v3/files\?})
        .to_return { |req| open_session(sessions, files, JSON.parse(req.body)["name"], new_id) }
      stub_request(:patch, %r{https://www\.googleapis\.com/upload/drive/v3/files/[^/?]+\?})
        .to_return do |req|
          id = req.uri.path.split("/").last
          open_session(sessions, files, JSON.parse(req.body)["name"], id)
        end
    end

    def stub_resumable_put(sessions, files)
      stub_request(:put, %r{https://www\.googleapis\.com/upload/session/}).to_return do |req|
        token = req.uri.path.split("/").last
        session = sessions.fetch(token)
        session[:buffer] << req.body.to_s.b
        if final_chunk?(req.headers["Content-Range"])
          files[session[:name]] = { id: session[:id], bytes: session[:buffer] }
          json_ok("id" => session[:id], "name" => session[:name], "size" => session[:buffer].bytesize.to_s)
        else
          { status: 308, headers: {} }
        end
      end
    end

    def stub_files_query(files)
      stub_request(:get, %r{https://www\.googleapis\.com/drive/v3/files\?}).to_return do |req|
        query = CGI.parse(req.uri.query)["q"].first.to_s
        if (name = query[/name = '([^']*)'/, 1])
          hit = files[name]
          json_ok("files" => hit ? [{ "id" => hit[:id] }] : [])
        else
          json_ok("files" => files.map { |n, v| { "name" => n, "size" => v[:bytes].bytesize.to_s } })
        end
      end
    end

    def stub_file_by_id(files)
      stub_request(:get, %r{https://www\.googleapis\.com/drive/v3/files/[^/?]+}).to_return do |req|
        respond_by_id(files, req)
      end
      stub_request(:delete, %r{https://www\.googleapis\.com/drive/v3/files/[^/?]+}).to_return do |req|
        id = req.uri.path.split("/").last
        files.delete(files.keys.find { |k| files[k][:id] == id })
        { status: 204, headers: {} }
      end
    end

    def respond_by_id(files, req)
      id = req.uri.path.split("/").last
      query = CGI.parse(req.uri.query.to_s)
      return json_ok("id" => id) unless query.key?("alt") || query["fields"].first.to_s.include?("size")

      name = files.keys.find { |k| files[k][:id] == id }
      return { status: 404, headers: {}, body: JSON.generate("error" => { "code" => 404 }) } if name.nil?
      return { status: 200, body: files[name][:bytes] } if query.key?("alt")

      json_ok("size" => files[name][:bytes].bytesize.to_s)
    end

    def open_session(sessions, _files, name, id)
      token = "sess-#{sessions.size + 1}"
      sessions[token] = { name: name, id: id, buffer: +"" }
      { status: 200, headers: { "Location" => "https://www.googleapis.com/upload/session/#{token}" } }
    end

    def final_chunk?(content_range)
      return true if content_range.nil? || content_range == "bytes */0"

      range, total = content_range.sub("bytes ", "").split("/")
      total.to_i.zero? || (range.split("-").last.to_i + 1 >= total.to_i)
    end

    def new_id
      @seq += 1
      "file-#{@seq}"
    end

    def json_ok(hash)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(hash) }
    end
  end
end
