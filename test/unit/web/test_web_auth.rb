# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"

module PgKeeper
  class TestWebAuth < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    OK_APP = ->(_env) { [200, { "content-type" => "text/plain" }, ["inner"]] }

    attr_reader :app

    def test_refuses_to_boot_without_any_credentials
      error = assert_raises(EnvironmentError) { Web::Auth.new(OK_APP) }

      assert_match(/auth is not configured/, error.message)
    end

    def test_refuses_password_without_username
      assert_raises(EnvironmentError) { Web::Auth.new(OK_APP, password: "p") }
    end

    def test_token_via_bearer_header
      @app = Web::Auth.new(OK_APP, token: "sekrit")

      get "/"

      assert_equal 401, last_response.status
      assert_match(/Basic realm/, last_response.headers["www-authenticate"])

      header "Authorization", "Bearer sekrit"
      get "/"

      assert_equal 200, last_response.status
    end

    def test_token_rejects_wrong_or_malformed_credentials
      @app = Web::Auth.new(OK_APP, token: "sekrit")

      header "Authorization", "Bearer wrong"
      get "/"

      assert_equal 401, last_response.status

      header "Authorization", "Nonsense"
      get "/"

      assert_equal 401, last_response.status
    end

    def test_token_works_as_basic_auth_password_for_browsers
      @app = Web::Auth.new(OK_APP, token: "sekrit")

      basic_authorize "anything", "sekrit"
      get "/"

      assert_equal 200, last_response.status

      basic_authorize "anything", "wrong"
      get "/"

      assert_equal 401, last_response.status
    end

    def test_username_and_password_basic_auth
      @app = Web::Auth.new(OK_APP, username: "ops", password: "hunter2")

      get "/"

      assert_equal 401, last_response.status

      basic_authorize "ops", "hunter2"
      get "/"

      assert_equal 200, last_response.status

      basic_authorize "ops", "wrong"
      get "/"

      assert_equal 401, last_response.status

      basic_authorize "eve", "hunter2"
      get "/"

      assert_equal 401, last_response.status
    end

    def test_named_tokens_each_authorize_independently
      @app = Web::Auth.new(OK_APP, tokens: { "ci" => "tok-ci", "bot" => "tok-bot" })

      header "Authorization", "Bearer tok-ci"
      get "/"

      assert_equal 200, last_response.status

      header "Authorization", "Bearer tok-bot"
      get "/"

      assert_equal 200, last_response.status

      header "Authorization", "Bearer tok-revoked"
      get "/"

      assert_equal 401, last_response.status
    end

    def test_named_token_records_the_caller_for_audit
      captured = nil
      spy = lambda do |env|
        captured = env[Web::Auth::CALLER_KEY]
        [200, {}, [""]]
      end
      @app = Web::Auth.new(spy, tokens: { "ci" => "tok-ci" })

      header "Authorization", "Bearer tok-ci"
      get "/"

      assert_equal "ci", captured, "the authenticating token's name is recorded on the request"
    end

    def test_single_token_and_named_tokens_coexist
      @app = Web::Auth.new(OK_APP, token: "legacy", tokens: { "ci" => "tok-ci" })

      header "Authorization", "Bearer legacy"
      get "/"

      assert_equal 200, last_response.status

      header "Authorization", "Bearer tok-ci"
      get "/"

      assert_equal 200, last_response.status
    end

    def test_revoking_a_token_is_dropping_its_entry
      # "bot" is gone from config; its holder can no longer authenticate while
      # "ci" keeps working — the whole point of per-caller tokens.
      @app = Web::Auth.new(OK_APP, tokens: { "ci" => "tok-ci" })

      header "Authorization", "Bearer tok-bot"
      get "/"

      assert_equal 401, last_response.status

      header "Authorization", "Bearer tok-ci"
      get "/"

      assert_equal 200, last_response.status
    end

    def test_named_token_works_as_basic_auth_password_too
      @app = Web::Auth.new(OK_APP, tokens: { "ci" => "tok-ci" })

      basic_authorize "anything", "tok-ci"
      get "/"

      assert_equal 200, last_response.status
    end

    def test_boots_with_only_named_tokens
      # No single token, no basic-auth pair — a tokens map alone is enough.
      Web::Auth.new(OK_APP, tokens: { "ci" => "tok-ci" })
    end

    def test_refuses_to_boot_with_an_empty_tokens_map
      assert_raises(EnvironmentError) { Web::Auth.new(OK_APP, tokens: {}) }
    end

    # The full matrix: every dashboard route — pages, API, and actions —
    # 401s without credentials. No unauthenticated surface, ever.
    def test_every_route_requires_auth
      in_tmpdir do |dir|
        @app = Web.build(web_config(dir), logger: null_logger)

        %w[/ /runs /runs/x /retention /backups /download /actions /api/status /api/runs].each do |path|
          get path

          assert_equal 401, last_response.status, "expected GET #{path} to 401 without credentials"
        end

        %w[/actions/backup /actions/verify /actions/prune /actions/test-notification /actions/doctor].each do |path|
          post path

          assert_equal 401, last_response.status, "expected POST #{path} to 401 without credentials"
        end
      end
    end

    def test_build_wires_named_tokens_and_drops_blank_secrets
      in_tmpdir do |dir|
        config = Config.parse(<<~YAML)
          workdir: #{dir}
          databases:
            - name: app
          web:
            auth:
              tokens:
                ci: real-token
                unset: ""
        YAML
        @app = Web.build(config, logger: null_logger)

        header "Authorization", "Bearer real-token"
        get "/"

        assert_equal 200, last_response.status

        # An unset env var collapses to a blank secret; it must never authorize.
        header "Authorization", "Bearer "
        get "/"

        assert_equal 401, last_response.status
      end
    end

    def test_configured_token_authorizes_the_real_dashboard
      in_tmpdir do |dir|
        @app = Web.build(web_config(dir), logger: null_logger)

        header "Authorization", "Bearer #{TOKEN}"
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "PgKeeper"
      end
    end
  end
end
