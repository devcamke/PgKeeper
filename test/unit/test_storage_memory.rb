# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"

module PgKeeper
  class TestStorageMemory < Minitest::Test
    include TestHelpers
    include StorageContract

    def build_adapter
      # The contract's `adapter` helper memoizes this, so a single in-memory
      # instance (and its store) is shared across a test's steps.
      Storage::Memory.new(logger: null_logger)
    end

    def test_factory_builds_memory
      assert_instance_of Storage::Memory, Storage.build({ "type" => "memory" }, logger: null_logger)
    end

    def test_unknown_type_raises
      assert_raises(ConfigError) { Storage.build({ "type" => "ftp" }, logger: null_logger) }
    end
  end
end
