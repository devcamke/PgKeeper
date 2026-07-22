# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Named destinations and the selector that scopes a run's fan-out.
  class TestStorageSelect < Minitest::Test
    include TestHelpers

    def targets
      [
        { "type" => "local", "name" => "nas", "path" => "/mnt/nas" },
        { "type" => "google_drive", "name" => "gdrive", "folder_id" => "x", "credentials_file" => "/c.json" },
        { "type" => "memory" }
      ]
    end

    def test_build_uses_friendly_name_as_the_adapter_name
      adapter = Storage.build({ "type" => "local", "name" => "nas", "path" => "/mnt/nas" }, logger: null_logger)

      assert_equal "nas", adapter.name
    end

    def test_build_falls_back_to_default_name_without_a_friendly_name
      adapter = Storage.build({ "type" => "local", "path" => "/mnt/nas" }, logger: null_logger)

      assert_equal "local:/mnt/nas", adapter.name
    end

    def test_blank_name_falls_back_to_default_name
      adapter = Storage.build({ "type" => "memory", "name" => "  " }, logger: null_logger)

      assert_equal "memory", adapter.name
    end

    def test_select_nil_returns_every_target
      assert_equal targets, Storage.select(targets, nil)
      assert_equal targets, Storage.select(targets, [])
    end

    def test_select_by_friendly_name
      chosen = Storage.select(targets, ["gdrive"])

      assert_equal(["gdrive"], chosen.map { |t| t["name"] })
    end

    def test_select_by_type
      chosen = Storage.select(targets, ["memory"])

      assert_equal(["memory"], chosen.map { |t| t["type"] })
    end

    def test_select_accepts_comma_separated_and_arrays
      by_comma = Storage.select(targets, "nas,gdrive")
      by_array = Storage.select(targets, %w[nas gdrive])

      assert_equal(%w[nas gdrive], by_comma.map { |t| t["name"] })
      assert_equal by_comma, by_array
    end

    def test_select_dedups_repeats
      chosen = Storage.select(targets, %w[nas nas])

      assert_equal 1, chosen.length
    end

    def test_unknown_selector_raises_and_lists_available_tokens
      error = assert_raises(Error) { Storage.select(targets, ["typo"]) }

      assert_match(/unknown destination "typo"/, error.message)
      assert_match(/nas, gdrive, memory/, error.message)
    end

    def test_tokens_prefers_name_then_type
      assert_equal %w[nas gdrive memory], Storage.tokens(targets)
    end
  end
end
