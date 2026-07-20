# frozen_string_literal: true

require "test_helper"
require "digest"

module PgKeeper
  class TestManifest < Minitest::Test
    include TestHelpers

    def test_for_artifact_records_size_and_checksum
      in_tmpdir do |dir|
        path = File.join(dir, "app.dump")
        contents = "PGDMP fake dump body"
        File.binwrite(path, contents)

        manifest = Manifest.for_artifact(path, "database" => "app", "kind" => "database")

        assert_equal contents.bytesize, manifest.size_bytes
        assert_equal Digest::SHA256.hexdigest(contents), manifest.checksum
        assert_equal "app.dump", manifest.artifact
        assert_equal "app", manifest.data["database"]
        assert_equal Manifest::SCHEMA_VERSION, manifest.data["schema_version"]
        assert_equal PgKeeper::VERSION, manifest.data["pgkeeper_version"]
      end
    end

    def test_verify_checksum_detects_tampering
      in_tmpdir do |dir|
        path = File.join(dir, "app.dump")
        File.binwrite(path, "original")
        manifest = Manifest.for_artifact(path)

        assert manifest.checksum_valid?(path)

        File.binwrite(path, "tampered")

        refute manifest.checksum_valid?(path), "checksum must fail after modification"
      end
    end

    def test_write_and_load_round_trip
      in_tmpdir do |dir|
        path = File.join(dir, "app.dump")
        File.binwrite(path, "body")
        manifest = Manifest.for_artifact(path, "kind" => "database")

        manifest_path = Manifest.path_for(path)
        manifest.write(manifest_path)

        assert_path_exists manifest_path
        loaded = Manifest.load(manifest_path)

        assert_equal manifest.checksum, loaded.checksum
        assert_equal manifest.size_bytes, loaded.size_bytes
        assert_equal "database", loaded.data["kind"]
      end
    end

    def test_path_for_appends_suffix
      assert_equal "/x/app.dump#{Manifest::SUFFIX}", Manifest.path_for("/x/app.dump")
    end

    def test_checksum_of_large_file_is_streamed
      in_tmpdir do |dir|
        path = File.join(dir, "big.dump")
        # 3 MiB forces multiple read chunks through the streaming digest.
        File.binwrite(path, "a" * (3 * 1024 * 1024))
        manifest = Manifest.for_artifact(path)

        assert_equal Digest::SHA256.file(path).hexdigest, manifest.checksum
      end
    end
  end
end
