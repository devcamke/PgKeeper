# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"

module PgKeeper
  class TestStorageLocal < Minitest::Test
    include TestHelpers
    include StorageContract

    def setup
      @root = Dir.mktmpdir("pgkeeper-local-")
    end

    def teardown
      FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    end

    def build_adapter
      Storage::Local.new(root: @root, logger: null_logger)
    end

    def test_uploaded_file_has_owner_only_permissions
      with_local_file("secret dump") do |src, _dir|
        adapter.upload(src, "db/app.dump")
        stored = File.join(@root, "db/app.dump")

        assert_equal "600", format("%o", File.stat(stored).mode & 0o777)
      end
    end

    def test_upload_is_atomic_no_tmp_left_behind
      with_local_file("data") do |src, _dir|
        adapter.upload(src, "db/app.dump")
        leftover = Dir.glob(File.join(@root, "**", "*.tmp"))

        assert_empty leftover, "no temp files should remain after upload"
      end
    end

    def test_factory_builds_local
      adapter = Storage.build({ "type" => "local", "path" => @root }, logger: null_logger)

      assert_instance_of Storage::Local, adapter
    end

    def test_name_includes_root
      assert_includes build_adapter.name, @root
    end
  end
end
