# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"

module PgKeeper
  # The add-a-database-from-the-web flow: probe first, append to the config
  # file only on success, secrets written as ENV references, browser-only.
  class TestWebAddDatabase < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    OK_PROBE = ->(_env) { { ok: true, server_version: "PostgreSQL 17.2", latency_ms: 9 } }

    def setup
      @dir = Dir.mktmpdir("pgkeeper-web-")
      @path = write_file_config
      @config = Config.load(@path)
      @probed_envs = []
      @app = app_for(@config)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    # A real config *file*, with a comment and an ERB interpolation that the
    # append must preserve verbatim.
    def write_file_config
      path = File.join(@dir, "pgkeeper.yml")
      File.write(path, <<~YAML)
        # hand-written comment that must survive edits
        workdir: #{@dir}
        schedule: "daily at 03:15"
        databases:
          - name: app
            host: localhost
        storage:
          - type: local
            path: #{@dir}/backups
        web:
          auth:
            token: <%= ENV["PGKEEPER_TEST_WEB_TOKEN"] || #{WebHelpers::TOKEN.inspect} %>
      YAML
      path
    end

    def app_for(config, probe: nil)
      recorder = lambda { |env|
        @probed_envs << env
        (probe || OK_PROBE).call(env)
      }
      probed = Web::Connections.new(config, logger: null_logger, probe: recorder)
      Web::App.new(config, logger: null_logger, actions: FakeActions.new, connections: probed)
    end

    def add_params(overrides = {})
      { "_csrf" => @app.csrf_token, "confirm" => "on",
        "name" => "reporting", "host" => "db2.internal", "port" => "5433",
        "username" => "ro", "password" => "pw-secret", "sslmode" => "require" }.merge(overrides)
    end

    def test_probe_then_append_with_password_as_env_reference
      post "/connections/add", add_params

      assert_equal 303, last_response.status
      location = Rack::Utils.unescape(last_response.headers["location"])

      assert_match %r{\A/connections\?msg=added reporting}, location
      assert_match(/export PGKEEPER_REPORTING_PASSWORD/, location)
      assert_match(/restart pgkeeper/, location)

      text = File.read(@path)

      assert_includes text, "- name: reporting"
      assert_includes text, "sslmode: require"
      assert_includes text, %(password: <%= ENV["PGKEEPER_REPORTING_PASSWORD"] %>)
      refute_includes text, "pw-secret", "the submitted password must never reach the file"
      assert_includes text, "hand-written comment that must survive edits"
      assert_includes text, %(ENV["PGKEEPER_TEST_WEB_TOKEN"]), "existing ERB survives verbatim"

      reloaded = Config.load(@path)
      db = reloaded.database("reporting")

      assert_equal "db2.internal", db.host
      assert_equal 5433, db.port
      assert_equal "reporting", db.database, "database defaults to the name"
      assert reloaded.database("app"), "the existing entry is untouched"
    end

    def test_probe_uses_the_submitted_credentials_with_a_bounded_connect_deadline
      post "/connections/add", add_params

      env = @probed_envs.first

      assert_equal "db2.internal", env["PGHOST"]
      assert_equal "5433", env["PGPORT"]
      assert_equal "pw-secret", env["PGPASSWORD"], "the probe itself authenticates for real"
      assert_equal "require", env["PGSSLMODE"]
      assert_equal "10", env["PGCONNECT_TIMEOUT"], "a dead host must answer in seconds"
    end

    def test_blank_password_writes_no_password_line
      post "/connections/add", add_params("password" => "")

      text = File.read(@path)

      assert_includes text, "- name: reporting"
      refute_includes text, "PGKEEPER_REPORTING_PASSWORD"
      refute_match(/reporting.*\n(?:.*\n)? *password:/, text.split("- name: app").first)
      refute_includes last_response.headers["location"], "export",
                      "no env var to export when relying on .pgpass/ambient credentials"
      refute @probed_envs.first.key?("PGPASSWORD")
    end

    def test_probe_failure_writes_nothing
      failing = ->(_env) { { ok: false, error: "password authentication failed for user \"ro\"" } }
      failing_app = app_for(@config, probe: failing)
      before = File.read(@path)

      response = post_to(failing_app, add_params("_csrf" => failing_app.csrf_token))

      location = Rack::Utils.unescape(response.headers["location"])

      assert_match(/nothing was written/, location)
      assert_match(/password authentication failed/, location)
      assert_equal before, File.read(@path), "a failed probe must not touch the file"
    end

    def test_duplicate_and_invalid_input_are_rejected_without_probing
      before = File.read(@path)

      post "/connections/add", add_params("name" => "app")

      assert_match(/already exists/, Rack::Utils.unescape(last_response.headers["location"]))

      post "/connections/add", add_params("name" => "bad name!")

      assert_match(/name may only contain/, Rack::Utils.unescape(last_response.headers["location"]))

      post "/connections/add", add_params("port" => "70000")

      assert_match(/port must be/, Rack::Utils.unescape(last_response.headers["location"]))

      post "/connections/add", add_params("sslmode" => "yolo")

      assert_match(/sslmode must be/, Rack::Utils.unescape(last_response.headers["location"]))

      assert_empty @probed_envs, "invalid input must be rejected before any probe runs"
      assert_equal before, File.read(@path)
    end

    def test_csrf_and_confirmation_gates_hold
      before = File.read(@path)

      post "/connections/add", add_params("_csrf" => "forged")

      assert_equal 403, last_response.status

      unconfirmed = add_params.tap { |p| p.delete("confirm") }
      post "/connections/add", unconfirmed

      assert_equal 303, last_response.status
      location = Rack::Utils.unescape(last_response.headers["location"])

      assert_match %r{\A/connections\?msg=confirmation}, location, "the flash lands back on Connections"

      assert_empty @probed_envs
      assert_equal before, File.read(@path)
    end

    def test_string_backed_config_disables_the_flow
      config = web_config(@dir) # parsed from a string; source is not a file
      string_app = app_for(config)

      response = Rack::MockRequest.new(string_app).get("/connections")

      assert_includes response.body, "Adding from the web is disabled"
      refute_includes response.body, %(action="/connections/add")

      @probed_envs.clear
      post_response = post_to(string_app, add_params("_csrf" => string_app.csrf_token))

      assert_match(/not an editable file/, Rack::Utils.unescape(post_response.headers["location"]))
      assert_empty @probed_envs
    end

    def test_connections_page_renders_the_form_and_flash
      get "/connections", "msg" => "added reporting to #{@path}; restart pgkeeper to load it"

      body = last_response.body

      assert_includes body, %(action="/connections/add")
      assert_includes body, %(name="_csrf"), "the form is CSRF-guarded"
      assert_includes body, %(type="password")
      assert_includes body, "notice-ok", "the added flash renders as a success notice"
    end

    def test_add_is_not_reachable_through_the_bearer_api
      header "Authorization", "Bearer #{WebHelpers::TOKEN}"
      post "/api/connections/add", { "name" => "sneaky" }

      assert_equal 404, last_response.status, "config writes are browser-only by design"
      refute_includes File.read(@path), "sneaky"
    end

    private

    def post_to(rack_app, params)
      Rack::Test::Session.new(rack_app).post("/connections/add", params)
    end
  end
end
