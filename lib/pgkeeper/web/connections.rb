# frozen_string_literal: true

module PgKeeper
  module Web
    # Live connectivity assembly for the Connections page and
    # +GET /api/connections+. Probes every configured database and PITR
    # cluster with the same bounded +psql+ round-trip `pgkeeper doctor` and
    # the wizard use, and pairs the outcome with the connection facts the
    # dashboard may safely show — endpoint, user, TLS mode — never a
    # credential.
    #
    # Probes run concurrently (each is its own subprocess; the threads only
    # overlap the waiting), so one unreachable host delays the page by a
    # single connect timeout rather than the sum of them.
    class Connections
      # One probed endpoint: config facts plus the live probe outcome.
      # +kind+ is "database" (logical, pg_dump) or "cluster" (physical, PITR).
      Row = Struct.new(:name, :kind, :host, :port, :database, :username, :sslmode,
                       :connect_timeout, :auth, :ok, :server_version, :latency_ms, :error,
                       keyword_init: true) do
        def light = ok ? "green" : "red"

        # "host:port/database", spelling out libpq's defaults when the config
        # leaves them unset.
        def endpoint = "#{host || 'local socket'}:#{port || 5432}/#{database}"
      end

      # +probe+ is injectable for tests: a callable taking a libpq env hash and
      # returning { ok:, server_version:, latency_ms:, error: }.
      def initialize(config, logger: PgKeeper.logger, probe: nil)
        @config = config
        @logger = logger
        @probe = probe || method(:psql_probe)
      end

      def database_rows
        probe_all(@config.databases, "database")
      end

      def cluster_rows
        probe_all(@config.pitr_clusters, "cluster")
      end

      private

      def probe_all(targets, kind)
        targets.map { |target| Thread.new { row_for(target, kind) } }.map(&:value)
      end

      def row_for(target, kind)
        result = @probe.call(target.libpq_env)
        Row.new(
          name: target.name, kind: kind, host: target.host, port: target.port,
          database: target.database, username: target.username,
          sslmode: target.sslmode, connect_timeout: target.connect_timeout,
          auth: auth_source(target),
          ok: !!result[:ok], server_version: result[:server_version],
          latency_ms: result[:latency_ms], error: result[:error]
        )
      end

      # How the connection authenticates — named, never echoed. Inspecting the
      # libpq env (rather than the raw config) keeps this truthful for the
      # `pgpass: true` case, where a configured password is deliberately unused.
      def auth_source(target)
        target.libpq_env.key?("PGPASSWORD") ? "password (config)" : "pgpass / ambient libpq"
      end

      # Default prober: `SELECT version()` under the config's query deadline,
      # timing the round trip. Any failure — bad credentials, unreachable host,
      # missing psql, deadline expiry — becomes a not-ok row, never an
      # exception: the page's job is to show an endpoint is down, not to go
      # down with it.
      def psql_probe(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out, err, status = Subprocess.capture3(env, "psql", "-XtAc", "SELECT version()",
                                               timeout: @config.timeout(:query))
        latency = elapsed_ms(started)
        return { ok: true, server_version: out.strip.split(" on ").first, latency_ms: latency } if status.success?

        { ok: false, latency_ms: latency, error: probe_error(out, err) }
      rescue StandardError => e
        @logger.warn("connection probe failed", error: e.message, error_class: e.class.name)
        { ok: false, latency_ms: elapsed_ms(started), error: e.message }
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end

      # libpq writes its diagnostics to stderr; the last line is the specific
      # cause ("connection refused", "password authentication failed", ...).
      def probe_error(out, err)
        "#{err}\n#{out}".strip.lines.map(&:strip).reject(&:empty?).last || "connection failed"
      end
    end
  end
end
