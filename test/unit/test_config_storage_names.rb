# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Validation and exposure of friendly storage `name:` aliases.
  class TestConfigStorageNames < Minitest::Test
    include TestHelpers

    def parse(storage_yaml)
      Config.parse(<<~YAML)
        databases:
          - name: app
        storage:
        #{storage_yaml}
      YAML
    end

    def test_named_targets_are_accepted_and_exposed_as_destinations
      config = parse(<<~YAML)
        - type: local
          name: nas
          path: /mnt/nas
        - type: memory
      YAML

      tokens = config.destinations.map(&:token)
      labels = config.destinations.map(&:label)

      assert_equal %w[nas memory], tokens
      assert_includes labels, "nas (local)"
      assert_includes labels, "memory"
    end

    def test_duplicate_names_are_rejected
      err = assert_raises(ConfigError) do
        parse(<<~YAML)
          - type: local
            name: dup
            path: /a
          - type: memory
            name: dup
        YAML
      end

      assert(err.problems.any? { |p| p.include?("duplicate storage name") })
    end

    def test_name_colliding_with_a_type_is_rejected
      err = assert_raises(ConfigError) do
        parse(<<~YAML)
          - type: local
            name: s3
            path: /a
        YAML
      end

      assert(err.problems.any? { |p| p.include?("collides with a storage type") })
    end

    def test_blank_name_is_rejected
      err = assert_raises(ConfigError) do
        parse(<<~YAML)
          - type: local
            name: "  "
            path: /a
        YAML
      end

      assert(err.problems.any? { |p| p.include?("`name` must be a non-empty string") })
    end
  end
end
