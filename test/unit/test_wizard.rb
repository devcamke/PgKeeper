# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestWizard < Minitest::Test
    include TestHelpers

    OK = ->(_env) { Wizard::Probe.new(ok: true, detail: "PostgreSQL 16.2") }
    FAIL = ->(_env) { Wizard::Probe.new(ok: false, detail: "could not connect to server") }

    # Drive the wizard with a canned script of answers and a stub prober.
    def run_wizard(script, path:, prober: OK)
      out = StringIO.new
      prompt = Prompt.new(input: StringIO.new(script), output: out, color: false)
      result = Wizard.new(config_path: path, prompt: prompt, logger: null_logger, prober: prober).run
      [result, out.string]
    end

    # Answers for a straight-through fresh-config run. Trailing answers:
    # schedule, use-schedule?, enable-web?, web-port(blank=default), write?
    def fresh_script(name: "orders", schedule: "daily at 03:15", password: "pw")
      answers = [name, "db.internal", "5432", "", "backup_user", password, schedule, "y", "y", "", "y"]
      "#{answers.join("\n")}\n"
    end

    def load(path)
      ENV["PGKEEPER_ORDERS_PASSWORD"] = "x"
      Config.load(path)
    ensure
      ENV.delete("PGKEEPER_ORDERS_PASSWORD")
    end

    def test_creates_a_fresh_valid_config
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        result, = run_wizard(fresh_script, path: path)

        assert result.created
        assert_equal "orders", result.database
        assert_equal "PGKEEPER_ORDERS_PASSWORD", result.password_env
        config = load(path)

        assert_equal ["orders"], config.databases.map(&:name)
        assert_equal "daily at 03:15", config.schedule
        assert_nil config.databases.first.schedule, "fresh config schedules globally, not per-db"
      end
    end

    def test_sets_up_the_web_dashboard
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        result, output = run_wizard(fresh_script, path: path)

        assert_equal "PGKEEPER_WEB_TOKEN", result.web_token_env
        assert result.web_token, "a dashboard token is generated to export"
        assert_includes output, "export PGKEEPER_WEB_TOKEN="
        # The token is an ENV reference in the file, never the literal secret.
        assert_includes File.read(path), %(token: <%= ENV["PGKEEPER_WEB_TOKEN"] %>)
        refute_includes File.read(path), result.web_token

        config = load(path)

        assert_equal "127.0.0.1", config.web["bind"]
        assert_equal 8321, config.web["port"]
      end
    end

    def test_declining_the_web_dashboard_writes_no_web_block
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        # schedule, use?, web? -> n, write?
        script = "#{['orders', 'db', '5432', '', 'u', 'pw', 'hourly', 'y', 'n', 'y'].join("\n")}\n"
        result, = run_wizard(script, path: path)

        assert_nil result.web_token_env
        refute_includes File.read(path), "web:"
      end
    end

    def test_existing_web_block_is_preserved_and_not_reprompted
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        run_wizard(fresh_script, path: path) # creates it WITH a web block

        # Appending a second database: the wizard sees the existing web block and
        # never asks again, so this script carries no web answer.
        script = "#{['reporting', 'db2', '5433', '', 'ro', 'pw2', '0 2 * * *', 'y', 'y'].join("\n")}\n"
        _result, output = run_wizard(script, path: path)

        refute_includes output, "Enable the web dashboard?"
        webs = File.read(path, encoding: "UTF-8").scan(/^web:/).length

        assert_equal 1, webs, "still exactly one web block"
      end
    end

    def test_blank_password_omits_env_reference
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        result, = run_wizard(fresh_script(password: ""), path: path)

        assert_nil result.password_env
        refute_includes File.read(path), "password:"
      end
    end

    def test_appends_to_existing_config_with_per_database_schedule
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        run_wizard(fresh_script, path: path) # creates it with a global schedule

        script = "#{['reporting', 'db2', '5433', 'reporting_db', 'ro', 'pw2', '0 2 * * *', 'y', 'y'].join("\n")}\n"
        result, = run_wizard(script, path: path)

        refute result.created
        ENV["PGKEEPER_ORDERS_PASSWORD"] = "x"
        ENV["PGKEEPER_REPORTING_PASSWORD"] = "y"
        config = Config.load(path)

        assert_equal %w[reporting orders], config.databases.map(&:name)
        assert_equal "0 2 * * *", config.database("reporting").schedule
        # The pre-existing global schedule is untouched, so `orders` still uses it.
        assert_equal "daily at 03:15", config.schedule
      ensure
        ENV.delete("PGKEEPER_ORDERS_PASSWORD")
        ENV.delete("PGKEEPER_REPORTING_PASSWORD")
      end
    end

    def test_rejects_a_duplicate_database_name
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        run_wizard(fresh_script, path: path)

        # First answer "orders" collides; the wizard re-asks and we give "orders2".
        script = "#{['orders', 'orders2', 'db', '5432', '', 'u', 'pw', 'hourly', 'y', 'y'].join("\n")}\n"
        _result, output = run_wizard(script, path: path)

        assert_includes output, "already exists"
        ENV["PGKEEPER_ORDERS_PASSWORD"] = "x"
        ENV["PGKEEPER_ORDERS2_PASSWORD"] = "y"

        assert_equal %w[orders2 orders], Config.load(path).databases.map(&:name)
      ensure
        ENV.delete("PGKEEPER_ORDERS_PASSWORD")
        ENV.delete("PGKEEPER_ORDERS2_PASSWORD")
      end
    end

    def test_reprompts_on_an_invalid_schedule
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        answers = ["orders", "db", "5432", "", "u", "pw", "not a schedule", "daily at 03:15", "y", "n", "y"]
        _result, output = run_wizard("#{answers.join("\n")}\n", path: path)

        assert_includes output, "unrecognized schedule"
        assert_equal "daily at 03:15", load(path).schedule
      end
    end

    def test_reprompts_on_an_invalid_port
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        script = "#{['orders', 'db', '99999', '5432', '', 'u', 'pw', 'hourly', 'y', 'n', 'y'].join("\n")}\n"
        _result, output = run_wizard(script, path: path)

        assert_includes output, "port must be an integer between 1 and 65535"
        assert_equal 5432, load(path).databases.first.port
      end
    end

    def test_previews_the_next_runs
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        _result, output = run_wizard(fresh_script(schedule: "hourly"), path: path)

        assert_includes output, "normalized cron: 0 * * * *"
        assert_includes output, "next run:"
      end
    end

    def test_connection_failure_can_be_overridden_to_save_anyway
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        # name, host, port, db, user, pw, [retry? -> n], [save anyway? -> y], schedule, use?, web?, write?
        script = "#{['orders', 'db', '5432', '', 'u', 'pw', 'n', 'y', 'hourly', 'y', 'n', 'y'].join("\n")}\n"
        result, output = run_wizard(script, path: path, prober: FAIL)

        assert_includes output, "connection failed"
        assert result.created
        assert_path_exists path
      end
    end

    def test_connection_failure_then_abort_writes_nothing
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        # retry? -> n, save anyway? -> n  => abort
        script = "#{['orders', 'db', '5432', '', 'u', 'pw', 'n', 'n'].join("\n")}\n"
        assert_raises(Prompt::Aborted) { run_wizard(script, path: path, prober: FAIL) }
        refute_path_exists path
      end
    end

    def test_connection_retry_then_success
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        calls = 0
        flaky = lambda do |_env|
          calls += 1
          calls == 1 ? Wizard::Probe.new(ok: false, detail: "down") : Wizard::Probe.new(ok: true, detail: "up")
        end
        # ..., pw, [retry? -> y], schedule, use?, web?, write?
        script = "#{['orders', 'db', '5432', '', 'u', 'pw', 'y', 'hourly', 'y', 'n', 'y'].join("\n")}\n"
        result, output = run_wizard(script, path: path, prober: flaky)

        assert_equal 2, calls
        assert_includes output, "connected"
        assert result.created
      end
    end

    def test_declining_the_write_leaves_no_file
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        # schedule, use?, web? (declined), write? (declined)
        script = "#{['orders', 'db', '5432', '', 'u', 'pw', 'hourly', 'y', 'n', 'n'].join("\n")}\n"
        result, output = run_wizard(script, path: path)

        assert_nil result
        refute_path_exists path
        assert_includes output, "Nothing written"
      end
    end

    def test_refuses_to_touch_an_invalid_existing_config
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        File.write(path, "databases: not-a-list\n")
        assert_raises(ConfigError) { run_wizard(fresh_script, path: path) }
      end
    end
  end
end
