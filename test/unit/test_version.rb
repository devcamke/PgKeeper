# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestVersion < Minitest::Test
    def test_version_is_a_semver_string
      assert_match(/\A\d+\.\d+\.\d+\z/, PgKeeper::VERSION)
    end
  end
end
