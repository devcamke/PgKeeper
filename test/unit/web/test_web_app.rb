# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"
require "json"
require "zip"
require "stringio"

module PgKeeper
  # Request specs for the dashboard pages, the JSON API, CSRF enforcement, and
  # the catalog-allowlisted download endpoint. Auth is exercised separately in
  # TestWebAuth; here the App is driven bare.
  class TestWebApp < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    def setup
      @dir = Dir.mktmpdir("pgkeeper-web-")
      @config = web_config(@dir)
      @actions = FakeActions.new
      @app = Web::App.new(@config, logger: null_logger, actions: @actions)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    def seed_backups
      root = File.join(@dir, "backups")
      old = seed_backup(root, "app", Time.utc(2026, 7, 20, 3, 15), verified_at: Time.utc(2026, 7, 20, 4))
      new = seed_backup(root, "app", Time.utc(2026, 7, 21, 3, 15))
      [root, old, new]
    end

    def post_action(path, params = {})
      post path, { "_csrf" => @app.csrf_token, "confirm" => "on" }.merge(params)
    end

    def test_overview_shows_traffic_lights_history_and_destinations
      seed_backups
      seed_history(@config)

      get "/"

      assert_equal 200, last_response.status
      body = last_response.body

      assert_includes body, "app"
      assert_includes body, "analytics"
      assert_includes body, "dot-green", "successful last run renders a green light"
      assert_includes body, "never run", "database with no history is called out"
      assert_includes body, "local:", "destination grid names the destination"
      assert_includes body, "20260721T031500Z-42", "recent runs link to the run"
    end

    def test_runs_page_lists_and_filters_by_database
      seed_history(@config, run_id: "r-app", database: "app")
      seed_history(@config, run_id: "r-analytics", database: "analytics",
                            at: Time.utc(2026, 7, 21, 4))

      get "/runs"

      assert_includes last_response.body, "r-app"
      assert_includes last_response.body, "r-analytics"

      get "/runs", "database" => "app"

      assert_includes last_response.body, "r-app"
      refute_includes last_response.body, "r-analytics"
    end

    def test_run_detail_shows_error_and_unknown_run_404s
      seed_history(@config, run_id: "r-bad", status: :failure, error: "pg_dump exploded")

      get "/runs/r-bad"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "pg_dump exploded"

      get "/runs/nope"

      assert_equal 404, last_response.status
    end

    def test_retention_page_previews_next_prune
      root = File.join(@dir, "backups")
      # An older, unverified backup that the policy will prune; plus a verified
      # backup and a newer one, both of which the safety rails protect.
      seed_backup(root, "app", Time.utc(2026, 7, 19, 3, 15))
      seed_backup(root, "app", Time.utc(2026, 7, 20, 3, 15), verified_at: Time.utc(2026, 7, 20, 4))
      seed_backup(root, "app", Time.utc(2026, 7, 21, 3, 15))

      get "/retention"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "keep_last"
      # keep_last: 1 → the oldest, unverified set is slated for deletion.
      assert_includes last_response.body, "2026-07-19T031500Z"
      # ...but the last verified backup itself is never pruned (safety rail).
      refute_includes last_response.body, "2026-07-20T031500Z"
    end

    def test_backups_page_lists_artifacts_with_verification_and_download_links
      seed_backups

      get "/backups"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2026-07-21T031500Z"
      assert_includes last_response.body, "structural", "verified tier is shown"
      assert_includes last_response.body, "/download?destination="
      assert_includes last_response.body, "/download-set?destination=",
                      "each set offers a zip-everything download"
    end

    def test_download_streams_cataloged_artifacts_only
      _root, old, = seed_backups
      destination = "local:#{File.join(@dir, 'backups')}"

      get "/download", "destination" => destination, "path" => old

      assert_equal 200, last_response.status
      assert_match(/attachment/, last_response.headers["content-disposition"])
      assert_includes last_response.body, "dump-bytes-database"

      get "/download", "destination" => destination, "path" => "../../../etc/passwd"

      assert_equal 404, last_response.status, "paths outside the catalog must 404"

      get "/download", "destination" => "bogus", "path" => old

      assert_equal 404, last_response.status, "unknown destinations must 404"
    end

    def test_download_set_zips_every_artifact_and_manifest_in_the_set
      root = File.join(@dir, "backups")
      started = Time.utc(2026, 7, 22, 3, 15)
      # A database dump and its cluster globals share a timestamp → one set.
      seed_backup(root, "app", started, kind: "database")
      seed_backup(root, "app", started, kind: "globals")
      destination = "local:#{root}"

      get "/download-set", "destination" => destination, "database" => "app",
                           "timestamp" => "2026-07-22T031500Z"

      assert_equal 200, last_response.status
      assert_equal "application/zip", last_response.headers["content-type"]
      assert_match(/filename="app-2026-07-22T031500Z\.zip"/, last_response.headers["content-disposition"])

      names = zip_entry_names(last_response.body)

      assert_includes names, "app-2026-07-22T031500Z.dump"
      assert_includes names, "app-2026-07-22T031500Z.dump#{Manifest::SUFFIX}"
      assert_includes names, "app-globals-2026-07-22T031500Z.dump"
      assert_includes names, "app-globals-2026-07-22T031500Z.dump#{Manifest::SUFFIX}"
    end

    def test_download_set_rejects_unknown_sets_and_destinations
      seed_backups
      destination = "local:#{File.join(@dir, 'backups')}"

      get "/download-set", "destination" => destination, "database" => "app",
                           "timestamp" => "1999-01-01T000000Z"

      assert_equal 404, last_response.status, "an unknown timestamp must 404"

      get "/download-set", "destination" => "bogus", "database" => "app",
                           "timestamp" => "2026-07-21T031500Z"

      assert_equal 404, last_response.status, "unknown destinations must 404"
    end

    def test_schedule_page_lists_the_backup_plan_with_cron_and_next_runs
      get "/schedule"

      assert_equal 200, last_response.status
      body = last_response.body

      assert_includes body, "backup"
      assert_includes body, "all databases"
      assert_includes body, "daily at 03:15", "the human cadence is shown"
      assert_includes body, "15 3 * * *", "the global daily 03:15 schedule renders its cron"
      assert_match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z/, body, "a next-run timestamp is shown")
      assert_includes body, "/schedule", "the Schedule nav link is present"
      # Each row has a CSRF-guarded "Run now" form posting to the action endpoint.
      assert_includes body, %(action="/actions/backup"), "the backup row can be run now"
      assert_includes body, %(name="_csrf"), "run-now is CSRF-guarded"
      assert_includes body, "Run now"
      assert_includes body, "pgkConfirm", "run-now confirms before firing"
    end

    def test_schedule_page_shows_maintenance_verify_and_prune_jobs
      maint = <<~YAML
        maintenance:
          verify:
            schedule: weekly on sunday at 04:00
            deep: true
          prune:
            schedule: daily at 05:00
            apply: true
      YAML
      maint_app = Web::App.new(web_config(@dir, maint), logger: null_logger, actions: FakeActions.new)

      response = Rack::Test::Session.new(maint_app).get("/schedule")

      assert_equal 200, response.status
      body = response.body

      assert_includes body, "verify"
      assert_includes body, "--deep"
      assert_includes body, "0 4 * * 0", "weekly Sunday 04:00 verify cron"
      assert_includes body, "prune"
      assert_includes body, "--apply"
      assert_includes body, "0 5 * * *", "daily 05:00 prune cron"
      # Run-now forms carry the flags that match each scheduled job.
      assert_includes body, %(action="/actions/verify")
      assert_includes body, %(name="deep" value="on"), "verify runs deep, matching the schedule"
      assert_includes body, %(action="/actions/prune")
      assert_includes body, %(name="apply" value="on"), "prune applies, matching the schedule"
    end

    def test_schedule_run_now_reaches_the_action_endpoint_with_matching_flags
      maint = <<~YAML
        maintenance:
          prune:
            schedule: daily at 05:00
            apply: true
      YAML
      maint_app = Web::App.new(web_config(@dir, maint), logger: null_logger, actions: @actions)
      session = Rack::Test::Session.new(maint_app)

      # Mirror exactly what the Schedule page's prune "Run now" form submits.
      session.post("/actions/prune", "_csrf" => maint_app.csrf_token, "confirm" => "on", "apply" => "on")

      assert_equal 303, session.last_response.status
      wait_for_jobs(maint_app)

      assert_includes @actions.calls, [:prune, { apply: true }]
    end

    def test_schedule_page_reports_when_nothing_is_scheduled
      config = Config.parse(<<~YAML, source: "test")
        workdir: #{@dir}
        databases:
          - name: app
        storage:
          - type: local
            path: #{@dir}/backups
        web:
          auth:
            token: #{WebHelpers::TOKEN}
      YAML
      unscheduled = Web::App.new(config, logger: null_logger, actions: FakeActions.new)

      response = Rack::Test::Session.new(unscheduled).get("/schedule")

      assert_equal 200, response.status
      assert_includes response.body, "No schedule configured"
    end

    def test_api_status_contract
      seed_backups
      seed_history(@config)

      get "/api/status"

      assert_equal 200, last_response.status
      assert_equal "application/json", last_response.headers["content-type"]
      payload = JSON.parse(last_response.body)

      db = payload["databases"].find { |d| d["name"] == "app" }

      assert_equal "green", db["light"]
      assert_equal "success", db.dig("last_run", "status")
      assert db["next_run_at"], "scheduled database exposes its next run time"
      assert db["last_verified_at"], "verified backup surfaces in the API"
      dest = payload["destinations"].first

      assert dest["healthy"]
      assert_equal 2, dest["backup_sets"]
    end

    def test_api_runs_contract_with_filter_and_limit
      seed_history(@config, run_id: "r1", database: "app")
      seed_history(@config, run_id: "r2", database: "analytics", at: Time.utc(2026, 7, 21, 4))

      get "/api/runs", "database" => "analytics", "limit" => "10"

      runs = JSON.parse(last_response.body).fetch("runs")

      assert_equal(["r2"], runs.map { |r| r["run_id"] })
      assert_equal %w[run_id database status started_at finished_at duration_seconds
                      artifact_count total_bytes destinations error].sort, runs.first.keys.sort
    end

    def test_post_without_csrf_token_is_forbidden
      post "/actions/backup", "confirm" => "on"

      assert_equal 403, last_response.status
      assert_empty @actions.calls, "action must not run without a CSRF token"

      post "/actions/backup", "_csrf" => "forged", "confirm" => "on"

      assert_equal 403, last_response.status
      assert_empty @actions.calls
    end

    def test_post_without_confirmation_does_not_start_anything
      post "/actions/prune", "_csrf" => @app.csrf_token, "apply" => "on"

      assert_equal 303, last_response.status
      assert_match(/confirmation/, Rack::Utils.unescape(last_response.headers["location"]))
      assert_empty @actions.calls
    end

    def test_backup_action_runs_in_background_and_scopes_to_one_database
      post_action "/actions/backup", "database" => "app"

      assert_equal 303, last_response.status
      wait_for_jobs(@app)

      assert_equal [[:backup, { only: ["app"], destinations: nil }]], @actions.calls
      job = @app.jobs.all.first

      assert_predicate job, :done?
      assert_equal "backup ok", job.detail
    end

    def test_verify_prune_notification_and_doctor_actions_dispatch
      post_action "/actions/verify", "deep" => "on"
      post_action "/actions/prune", "apply" => "on"
      post_action "/actions/test-notification"
      post_action "/actions/doctor"
      wait_for_jobs(@app)

      assert_includes @actions.calls, [:verify, { deep: true }]
      assert_includes @actions.calls, [:prune, { apply: true }]
      assert_includes @actions.calls, [:test_notification, {}]
      assert_includes @actions.calls, [:doctor, {}]
      assert(@app.jobs.all.all?(&:done?))
    end

    def test_action_colliding_with_the_run_lock_fails_loudly
      colliding = FakeActions.new(error: LockError.new("another PgKeeper run holds the lock"))
      locked = Web::App.new(@config, logger: null_logger, actions: colliding)
      post_to(locked, "/actions/backup")
      wait_for_jobs(locked)

      job = locked.jobs.all.first

      assert_predicate job, :failed?
      assert_match(/holds the lock/, job.detail)
    end

    def test_actions_page_shows_job_outcomes
      post_action "/actions/doctor"
      wait_for_jobs(@app)

      get "/actions"

      assert_includes last_response.body, "doctor"
      assert_includes last_response.body, "doctor ok"
    end

    def test_unknown_routes_and_methods
      get "/nope"

      assert_equal 404, last_response.status

      delete "/"

      assert_equal 405, last_response.status
    end

    private

    # Entry names inside a zip delivered as a response body.
    def zip_entry_names(bytes)
      Zip::File.open_buffer(StringIO.new(bytes)).entries.map(&:name)
    end

    # Drive a different App instance than the fixture (rack-test's `app` is
    # fixed per session).
    def post_to(rack_app, path)
      Rack::Test::Session.new(rack_app)
                         .post(path, { "_csrf" => rack_app.csrf_token, "confirm" => "on" })
    end
  end
end
