# frozen_string_literal: true

require "test_helper"
require "support/backup_seeding"

module PgKeeper
  class TestCatalog < Minitest::Test
    include TestHelpers
    include BackupSeeding

    def setup
      @root = Dir.mktmpdir("pgkeeper-catalog-test-")
      @adapter = Storage::Local.new(root: @root, logger: null_logger)
    end

    def teardown
      FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    end

    def catalog = Catalog.new(@adapter)

    def test_lists_databases
      seed_backup(@root, "app", Time.utc(2026, 1, 1))
      seed_backup(@root, "analytics", Time.utc(2026, 1, 1))

      assert_equal %w[analytics app], catalog.databases
    end

    def test_groups_artifacts_into_sets_by_database_and_time
      seed_backup(@root, "app", Time.utc(2026, 1, 1))
      seed_backup(@root, "app", Time.utc(2026, 1, 2))
      seed_backup(@root, "app", Time.utc(2026, 1, 3))

      sets = catalog.backup_sets(database: "app")

      assert_equal 3, sets.length
      assert_equal %w[2026-01-01T000000Z 2026-01-02T000000Z 2026-01-03T000000Z], sets.map(&:label)
    end

    def test_globals_join_the_same_set_as_the_database_dump
      t = Time.utc(2026, 2, 1, 3, 15)
      seed_backup(@root, "app", t, kind: "database")
      seed_backup(@root, "app", t, kind: "globals")

      sets = catalog.backup_sets(database: "app")

      assert_equal 1, sets.length
      assert_equal 2, sets.first.artifacts.length
      assert_equal "database", sets.first.primary.kind
    end

    def test_verified_state_is_read_from_manifest
      seed_backup(@root, "app", Time.utc(2026, 3, 1), verified_at: Time.utc(2026, 3, 2))
      set = catalog.backup_sets(database: "app").first

      assert_predicate set, :verified?
      assert_equal "structural", set.primary.verified_tier
    end

    def test_unverified_by_default
      seed_backup(@root, "app", Time.utc(2026, 3, 1))

      refute_predicate catalog.backup_sets(database: "app").first, :verified?
    end

    def test_total_size_sums_artifacts
      t = Time.utc(2026, 4, 1)
      seed_backup(@root, "app", t, kind: "database")
      seed_backup(@root, "app", t, kind: "globals")

      assert_operator catalog.backup_sets(database: "app").first.total_size, :>, 0
    end
  end
end
