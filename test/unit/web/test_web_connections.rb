# frozen_string_literal: true

require "test_helper"
require "support/web_helpers"
require "rack/test"
require "json"

module PgKeeper
  # The Connections page and GET /api/connections: live-probed database and
  # PITR-cluster reachability plus storage health — with credentials never
  # rendered anywhere.
  class TestWebConnections < Minitest::Test
    include TestHelpers
    include WebHelpers
    include Rack::Test::Methods

    OK_PROBE = ->(_env) { { ok: true, server_version: "PostgreSQL 17.2", latency_ms: 12 } }
    FAIL_PROBE = lambda { |_env|
      { ok: false, latency_ms: 3000, error: "connection to server failed: Connection refused" }
    }

    def setup
      @dir = Dir.mktmpdir("pgkeeper-web-")
      @config = web_config(@dir)
      @app = connections_app(@config)
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    attr_reader :app

    def connections_app(config, probe: OK_PROBE)
      probed = Web::Connections.new(config, logger: null_logger, probe: probe)
      Web::App.new(config, logger: null_logger, actions: FakeActions.new, connections: probed)
    end

    # A config whose database carries a full credential set — what must never
    # leak into a page or API payload.
    def secret_config
      Config.parse(<<~YAML, source: "test")
        workdir: #{@dir}
        databases:
          - name: app
            host: db.internal
            port: 5433
            username: backup_role
            password: "s3kr3t-pw"
            sslmode: require
        storage:
          - type: local
            path: #{@dir}/backups
        web:
          auth:
            token: #{WebHelpers::TOKEN}
      YAML
    end

    def test_connections_page_lists_probed_databases_and_destinations
      get "/connections"

      assert_equal 200, last_response.status
      body = last_response.body

      assert_includes body, "app"
      assert_includes body, "analytics"
      assert_includes body, "dot-green", "a reachable database renders a green light"
      assert_includes body, "PostgreSQL 17.2", "the probed server version is shown"
      assert_includes body, "12 ms", "round-trip latency is shown"
      assert_match(%r{2<span class="stat-of">/2</span>}, body, "the stat tile counts reachable databases")
      assert_includes body, "local:", "storage destinations are listed"
      assert_includes body, %(href="/connections"), "the nav links to the page"
    end

    def test_connections_page_shows_probe_failures
      response = Rack::MockRequest.new(connections_app(@config, probe: FAIL_PROBE)).get("/connections")

      assert_equal 200, response.status
      body = response.body

      assert_includes body, "dot-red", "an unreachable database renders a red light"
      assert_includes body, "Connection refused", "the libpq error is surfaced"
      assert_match(%r{0<span class="stat-of">/2</span>}, body, "the stat tile counts the failures")
    end

    def test_connections_page_never_renders_credentials
      response = Rack::MockRequest.new(connections_app(secret_config)).get("/connections")

      body = response.body

      assert_includes body, "db.internal:5433/app", "endpoint facts are shown"
      assert_includes body, "backup_role"
      assert_includes body, "require", "TLS mode is shown"
      assert_includes body, "password (config)", "the auth *source* is named"
      refute_includes body, "s3kr3t-pw", "the password itself must never appear"
    end

    def test_connections_page_includes_pitr_clusters_when_configured
      config = web_config(@dir, "clusters:\n  - name: pgc\n    host: h\n    pitr: { enabled: true }\n")
      response = Rack::MockRequest.new(connections_app(config)).get("/connections")

      body = response.body

      assert_includes body, "PITR clusters"
      assert_includes body, "pgc"
      assert_includes body, "h:5432/postgres", "the cluster's maintenance-db endpoint is shown"
    end

    def test_api_connections_contract
      response = Rack::MockRequest.new(connections_app(secret_config)).get("/api/connections")

      assert_equal 200, response.status
      refute_includes response.body, "s3kr3t-pw", "the API payload must never carry a credential"
      payload = JSON.parse(response.body)

      db = payload.fetch("databases").first

      assert_equal "app", db["name"]
      assert_equal "database", db["kind"]
      assert_equal "green", db["light"]
      assert_equal "db.internal", db["host"]
      assert_equal 5433, db["port"]
      assert db["connected"]
      assert_equal "PostgreSQL 17.2", db["server_version"]
      assert_equal 12, db["latency_ms"]
      assert_empty payload.fetch("clusters")
      assert payload.fetch("destinations").first["healthy"]
      assert payload["generated_at"]
    end

    def test_probe_receives_the_database_libpq_env
      envs = []
      recorder = lambda { |env|
        envs << env
        { ok: true }
      }
      Web::Connections.new(secret_config, logger: null_logger, probe: recorder).database_rows

      assert_equal 1, envs.length
      assert_equal "db.internal", envs.first["PGHOST"]
      assert_equal "s3kr3t-pw", envs.first["PGPASSWORD"], "the probe itself authenticates for real"
    end

    def test_default_probe_round_trips_psql_and_times_it
      with_fake_psql(<<~SCRIPT) do
        echo "PostgreSQL 17.2 on x86_64-pc-linux-gnu, compiled by gcc"
        exit 0
      SCRIPT
        rows = Web::Connections.new(@config, logger: null_logger).database_rows

        assert(rows.all?(&:ok))
        assert_equal "PostgreSQL 17.2", rows.first.server_version
        assert_operator rows.first.latency_ms, :>=, 0
      end
    end

    def test_default_probe_reports_the_last_error_line_on_failure
      with_fake_psql(<<~SCRIPT) do
        echo "psql: error: connection to server at \\"db\\" failed: Connection refused" 1>&2
        exit 2
      SCRIPT
        rows = Web::Connections.new(@config, logger: null_logger).database_rows

        refute(rows.any?(&:ok))
        assert_match(/Connection refused/, rows.first.error)
      end
    end

    def test_default_probe_survives_a_missing_psql
      empty = File.join(@dir, "empty-path")
      FileUtils.mkdir_p(empty)
      rows = with_path(empty) { Web::Connections.new(@config, logger: null_logger).database_rows }

      refute(rows.any?(&:ok))
      assert_match(/not found on PATH/, rows.first.error)
    end

    private

    # Put a fake `psql` (a shell script with the given body) first on PATH.
    def with_fake_psql(body, &)
      bin = File.join(@dir, "fake-bin")
      FileUtils.mkdir_p(bin)
      psql = File.join(bin, "psql")
      File.write(psql, "#!/bin/sh\n#{body}")
      FileUtils.chmod(0o755, psql)
      with_path("#{bin}:#{ENV.fetch('PATH', nil)}", &)
    end

    def with_path(path)
      original = ENV.fetch("PATH", nil)
      ENV["PATH"] = path
      yield
    ensure
      ENV["PATH"] = original
    end
  end
end
