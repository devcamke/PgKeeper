# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestPreflight < Minitest::Test
    include TestHelpers

    def db
      Config.parse("databases:\n  - name: app\n").databases.first
    end

    def test_raises_when_free_space_is_below_the_floor
      in_tmpdir do |dir|
        preflight = Preflight.new(min_free_bytes: 1 << 62)
        assert_raises(PreflightError) { preflight.check!(db, dir) }
      end
    end

    def test_passes_on_a_normal_filesystem_when_size_is_unknown
      in_tmpdir do |dir|
        # No reachable database → size unknown → only the (tiny) floor applies.
        Preflight.new(min_free_bytes: 1024).check!(db, dir)
      end
    end

    def test_reserves_a_multiple_of_the_database_size
      # A zero floor alone would pass, but the estimated database size dwarfs the
      # free space once the scratch multiplier is applied, so the run is refused
      # before it can fill the disk mid-dump.
      preflight = Preflight.new(min_free_bytes: 0, scratch_factor: 2.0)
      preflight.define_singleton_method(:estimated_database_bytes) { |_db| 1 << 40 }
      preflight.define_singleton_method(:free_bytes) { |_path| 1 << 20 }
      assert_raises(PreflightError) { preflight.check!(db, "/anywhere") }
    end

    def test_passes_when_free_space_exceeds_the_reservation
      preflight = Preflight.new(min_free_bytes: 0, scratch_factor: 2.0)
      preflight.define_singleton_method(:estimated_database_bytes) { |_db| 1 << 20 }
      preflight.define_singleton_method(:free_bytes) { |_path| 1 << 40 }
      # 1 TiB free comfortably covers 2 × 1 MiB.
      preflight.check!(db, "/anywhere")
    end

    def test_does_not_block_when_free_space_is_unmeasurable
      preflight = Preflight.new(min_free_bytes: 1 << 62)
      preflight.define_singleton_method(:free_bytes) { |_path| nil }
      # df unavailable → can't tell → don't block the run.
      preflight.check!(db, "/anywhere")
    end
  end
end
