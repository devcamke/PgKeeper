# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"

module PgKeeper
  # The health/readiness probes and the metrics endpoint, exercised against the
  # fully-built stack (Health -> Auth -> App) so the auth boundary is real.
  class TestWebHealth < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    def setup
      @dir = Dir.mktmpdir("pgkeeper-health-")
      @config = web_config(@dir)
      @app = Web.build(@config, logger: null_logger)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    def bearer(token)
      { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    end

    def test_healthz_is_unauthenticated_and_ok
      get "/healthz"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "ok"
    end

    def test_readyz_ok_when_workdir_usable
      get "/readyz"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "ready"
    end

    def test_readyz_503_when_workdir_missing
      FileUtils.remove_entry(@dir)

      get "/readyz"

      assert_equal 503, last_response.status
      assert_includes last_response.body, "not ready"
    ensure
      FileUtils.mkdir_p(@dir) # so teardown's cleanup is a no-op-safe path
    end

    def test_readyz_503_when_history_is_corrupt
      File.write(File.join(@dir, "history.sqlite3"), "not a database")

      get "/readyz"

      assert_equal 503, last_response.status
      assert_includes last_response.body, "history unreadable"
    end

    def test_metrics_requires_auth
      get "/metrics"

      assert_equal 401, last_response.status
    end

    def test_metrics_served_with_valid_token
      seed_history(@config)

      get "/metrics", {}, bearer(WebHelpers::TOKEN)

      assert_equal 200, last_response.status
      assert_includes last_response.headers["content-type"], "version=0.0.4"
      assert_includes last_response.body, "pgkeeper_up 1"
      assert_includes last_response.body, %(pgkeeper_last_run_success{database="app"})
    end

    def test_other_paths_still_require_auth
      get "/"

      assert_equal 401, last_response.status
    end
  end
end
