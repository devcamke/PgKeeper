# frozen_string_literal: true

require "test_helper"
require "pgkeeper/cli"

module PgKeeper
  # The CLI is a thin Thor dispatch layer; these lock its command aliases so a
  # rename of the underlying command can't silently break the shorthand.
  class TestCli < Minitest::Test
    def aliases
      CLI.instance_variable_get(:@map)
    end

    def test_run_is_an_alias_for_backup
      assert_equal :backup, aliases["run"], "`pgkeeper run` should dispatch to backup"
    end

    def test_onboard_is_an_alias_for_connect
      assert_equal :connect, aliases["onboard"], "`pgkeeper onboard` should dispatch to connect"
    end
  end
end
