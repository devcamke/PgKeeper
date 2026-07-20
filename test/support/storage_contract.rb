# frozen_string_literal: true

module PgKeeper
  # A single set of behavioral tests that EVERY storage adapter must satisfy, so
  # Local, S3, and Memory are provably interchangeable at the interface. A host
  # test case includes this module and provides {#build_adapter}.
  module StorageContract
    def adapter
      @adapter ||= build_adapter
    end

    def with_local_file(content)
      Dir.mktmpdir("pgkeeper-contract-") do |dir|
        path = File.join(dir, "artifact.bin")
        File.binwrite(path, content)
        yield path, dir
      end
    end

    def test_healthcheck_passes
      assert adapter.healthcheck
    end

    def test_upload_then_download_round_trips
      payload = "backup artifact bytes \x00\x01\x02 " * 500
      with_local_file(payload) do |src, dir|
        result = adapter.upload(src, "db/app-2026.dump")

        assert_equal "db/app-2026.dump", result.remote_path
        assert_equal payload.bytesize, result.size_bytes

        out = File.join(dir, "restored.bin")
        adapter.download("db/app-2026.dump", out)

        assert_equal payload, File.binread(out)
      end
    end

    def test_upload_appears_in_listing_with_size
      payload = "x" * 1234
      with_local_file(payload) do |src, _dir|
        adapter.upload(src, "db/one.dump")
        entry = adapter.list("db/").find { |e| e.path == "db/one.dump" }

        refute_nil entry, "uploaded object should appear in listing"
        assert_equal 1234, entry.size_bytes
      end
    end

    def test_list_prefix_filters
      with_local_file("a") { |src, _| adapter.upload(src, "alpha/one.dump") }
      with_local_file("bb") { |src, _| adapter.upload(src, "beta/two.dump") }

      alpha = adapter.list("alpha/").map(&:path)

      assert_includes alpha, "alpha/one.dump"
      refute_includes alpha, "beta/two.dump"
    end

    def test_delete_removes_object
      with_local_file("gone soon") do |src, _dir|
        adapter.upload(src, "db/temp.dump")
        adapter.delete("db/temp.dump")

        assert_empty(adapter.list("db/").select { |e| e.path == "db/temp.dump" })
      end
    end

    def test_download_missing_raises_storage_error
      assert_raises(StorageError) do
        Dir.mktmpdir { |dir| adapter.download("nope/missing.dump", File.join(dir, "x")) }
      end
    end
  end
end
