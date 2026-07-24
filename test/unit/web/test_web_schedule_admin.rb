# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"

module PgKeeper
  # The set-a-schedule-from-the-web flow: validate the expression, splice the
  # `schedule:` key into the config file (per database or global), re-validate
  # the whole file, write atomically. Browser-only.
  class TestWebScheduleAdmin < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    def setup
      @dir = Dir.mktmpdir("pgkeeper-web-")
      @path = write_file_config
      @config = Config.load(@path)
      @app = Web::App.new(@config, logger: null_logger, actions: FakeActions.new)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    # A real config *file*, with a comment and an ERB interpolation that the
    # edit must preserve verbatim, and one pre-existing per-db override.
    def write_file_config
      path = File.join(@dir, "pgkeeper.yml")
      File.write(path, <<~YAML)
        # hand-written comment that must survive edits
        workdir: #{@dir}
        schedule: "daily at 03:15"
        databases:
          - name: app
            host: localhost
          - name: analytics
            host: localhost
            schedule: "hourly"
        storage:
          - type: local
            path: #{@dir}/backups
        web:
          auth:
            token: <%= ENV["PGKEEPER_TEST_WEB_TOKEN"] || #{WebHelpers::TOKEN.inspect} %>
      YAML
      path
    end

    def set_params(overrides = {})
      { "_csrf" => @app.csrf_token, "confirm" => "on",
        "database" => "app", "expression" => "0 13 * * *" }.merge(overrides)
    end

    def flash_location
      Rack::Utils.unescape(last_response.headers["location"])
    end

    def test_sets_a_per_database_schedule
      post "/schedule/set", set_params

      assert_equal 303, last_response.status
      assert_match %r{\A/schedule\?msg=set app's schedule to "0 13 \* \* \*"}, flash_location
      assert_match(/cron: 0 13 \* \* \*/, flash_location)
      assert_match(/restart pgkeeper/, flash_location)

      text = File.read(@path)

      assert_includes text, "  - name: app\n    host: localhost\n    schedule: 0 13 * * *\n"
      assert_includes text, "# hand-written comment that must survive edits"
      assert_includes text, %(<%= ENV["PGKEEPER_TEST_WEB_TOKEN"]), "ERB must survive the edit"
      assert_includes text, %(schedule: "hourly"), "the other entry must be untouched"
    end

    def test_replaces_an_existing_override_and_the_global_default
      post "/schedule/set", set_params("database" => "analytics", "expression" => "daily at 02:30")

      assert_includes File.read(@path), "    schedule: daily at 02:30\n"
      refute_includes File.read(@path), "hourly"

      post "/schedule/set", set_params("database" => "", "expression" => "0 4 * * *")

      text = File.read(@path)

      assert_includes text, "schedule: 0 4 * * *\n"
      refute_includes text, %("daily at 03:15")
      assert_match(/set the global schedule/, flash_location)
    end

    def test_blank_expression_removes_an_override
      post "/schedule/set", set_params("database" => "analytics", "expression" => "")

      assert_match(/removed analytics's schedule override/, flash_location)
      refute_includes File.read(@path), "hourly"
    end

    def test_blank_expression_with_no_override_is_a_no_op
      original = File.read(@path)
      post "/schedule/set", set_params("expression" => "")

      assert_match(%r{\A/schedule\?msg=nothing was written}, flash_location)
      assert_match(/app has no schedule override/, flash_location)
      assert_equal original, File.read(@path)
    end

    def test_rejects_an_unparseable_expression_and_writes_nothing
      original = File.read(@path)
      post "/schedule/set", set_params("expression" => "whenever I feel like it")

      assert_match(%r{\A/schedule\?msg=nothing was written}, flash_location)
      assert_match(/unrecognized schedule/, flash_location)
      assert_equal original, File.read(@path)
    end

    def test_rejects_an_unknown_database
      post "/schedule/set", set_params("database" => "nope")

      assert_match(/no database named "nope"/, flash_location)
    end

    def test_requires_the_confirmation_toggle
      original = File.read(@path)
      post("/schedule/set", set_params.tap { |p| p.delete("confirm") })

      assert_equal 303, last_response.status
      assert_match(/confirmation checkbox is required/, flash_location)
      assert_match(%r{\A/schedule\?}, flash_location, "the flash must land back on the schedule page")
      assert_equal original, File.read(@path)
    end

    def test_requires_a_csrf_token
      post "/schedule/set", set_params("_csrf" => "forged")

      assert_equal 403, last_response.status
      refute_includes File.read(@path), "0 13 * * *"
    end

    def test_is_not_exposed_on_the_bearer_api
      header "Authorization", "Bearer #{WebHelpers::TOKEN}"
      post "/api/schedule/set", set_params

      assert_equal 404, last_response.status
      refute_includes File.read(@path), "0 13 * * *"
    end

    def test_schedule_page_renders_the_editor_for_a_file_config
      get "/schedule"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Set a schedule"
      assert_includes last_response.body, "inherits the global default"
      assert_includes last_response.body, "currently: hourly"
    end

    def test_schedule_page_disables_the_editor_for_a_non_file_config
      config = web_config(@dir)
      app = Web::App.new(config, logger: null_logger, actions: FakeActions.new)
      session = Rack::Test::Session.new(app)
      session.get "/schedule"

      assert_includes session.last_response.body, "Editing from the web is disabled"
    end
  end
end
