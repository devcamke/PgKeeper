# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"
require "json"

module PgKeeper
  # Request specs for the remote-trigger JSON API: Bearer-only auth (which
  # stands in for CSRF), destination selection, and job polling. Token
  # verification itself lives in the Auth middleware (TestWebAuth); here the App
  # is driven bare, so a Bearer header just marks the request as non-browser.
  class TestWebApiActions < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    def setup
      @dir = Dir.mktmpdir("pgkeeper-api-")
      @config = web_config(@dir, <<~YAML)
        # named destinations so selection has something to resolve
      YAML
      @actions = FakeActions.new
      @app = Web::App.new(@config, logger: null_logger, actions: @actions)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    def bearer!
      header "Authorization", "Bearer #{WebHelpers::TOKEN}"
    end

    def post_json(path, payload)
      bearer!
      post path, JSON.generate(payload), "CONTENT_TYPE" => "application/json"
    end

    def test_backup_requires_a_bearer_credential
      post "/api/actions/backup", JSON.generate({}), "CONTENT_TYPE" => "application/json"

      assert_equal 403, last_response.status
      assert_empty @actions.calls, "no action may run without a Bearer token"
      assert_equal "application/json", last_response.headers["content-type"]
    end

    def test_backup_triggers_a_job_and_returns_its_id
      post_json "/api/actions/backup", { "database" => "app", "destinations" => %w[local] }

      assert_equal 202, last_response.status
      body = JSON.parse(last_response.body)

      assert_operator body.dig("job", "id"), :>, 0
      assert_equal "backup app → local", body.dig("job", "action")

      wait_for_jobs(@app)

      assert_equal [[:backup, { only: ["app"], destinations: ["local"] }]], @actions.calls
    end

    def test_backup_without_a_body_backs_up_everything_everywhere
      bearer!
      post "/api/actions/backup"
      wait_for_jobs(@app)

      assert_equal [[:backup, { only: nil, destinations: nil }]], @actions.calls
    end

    def test_backup_accepts_form_encoded_params_too
      bearer!
      post "/api/actions/backup", "database" => "analytics", "destinations" => "local"
      wait_for_jobs(@app)

      assert_equal [[:backup, { only: ["analytics"], destinations: ["local"] }]], @actions.calls
    end

    def test_api_does_not_require_csrf_or_confirmation
      # No _csrf, no confirm checkbox — the browser-form guards must not apply.
      post_json "/api/actions/backup", {}

      assert_equal 202, last_response.status
    end

    def test_verify_and_prune_flags
      post_json "/api/actions/verify", { "deep" => true }
      post_json "/api/actions/prune", { "apply" => true }
      wait_for_jobs(@app)

      assert_includes @actions.calls, [:verify, { deep: true }]
      assert_includes @actions.calls, [:prune, { apply: true }]
    end

    def test_unknown_api_action_404s
      post_json "/api/actions/nope", {}

      assert_equal 404, last_response.status
    end

    def test_jobs_can_be_listed_and_fetched
      post_json "/api/actions/backup", {}
      wait_for_jobs(@app)

      bearer!
      get "/api/jobs"

      jobs = JSON.parse(last_response.body).fetch("jobs")

      assert_equal 1, jobs.length
      id = jobs.first["id"]

      bearer!
      get "/api/jobs/#{id}"

      job = JSON.parse(last_response.body).fetch("job")

      assert_equal "done", job["status"]
      assert_equal "backup ok", job["detail"]
      assert job["finished_at"], "a finished job reports finished_at"
    end

    def test_unknown_job_404s
      bearer!
      get "/api/jobs/999"

      assert_equal 404, last_response.status
    end

    def test_destinations_endpoint_lists_selectable_tokens
      bearer!
      get "/api/destinations"

      dests = JSON.parse(last_response.body).fetch("destinations")

      assert_equal "local", dests.first["type"]
      assert dests.first["token"], "each destination exposes a selection token"
    end
  end
end
