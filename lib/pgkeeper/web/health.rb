# frozen_string_literal: true

module PgKeeper
  module Web
    # Unauthenticated liveness/readiness endpoints for container orchestrators
    # and load balancers, sitting *outside* the auth middleware so a probe never
    # needs a credential. They expose no backup data — only whether the process
    # is up and whether it can reach its own state.
    #
    #   GET /healthz  -> 200 always (the process is running)
    #   GET /readyz   -> 200 when the workdir is usable and the history store is
    #                    readable; 503 otherwise (so traffic is held back until
    #                    the instance can actually serve)
    class Health
      HEADERS = { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }.freeze

      def initialize(app, config, logger: PgKeeper.logger)
        @app = app
        @config = config
        @logger = logger
      end

      def call(env)
        case env["PATH_INFO"]
        when "/healthz" then [200, HEADERS.dup, ["ok\n"]]
        when "/readyz" then readiness
        else @app.call(env)
        end
      end

      private

      def readiness
        ok, detail = check_ready
        [ok ? 200 : 503, HEADERS.dup, ["#{ok ? 'ready' : 'not ready'}: #{detail}\n"]]
      end

      # Ready means the two things the dashboard depends on are usable: the
      # workdir exists and is writable, and the run-history store (if it exists
      # yet) can be opened. A brand-new install with no history is still ready —
      # there is simply nothing recorded.
      def check_ready
        dir = @config.workdir
        return [false, "workdir #{dir} is missing"] unless File.directory?(dir)
        return [false, "workdir #{dir} is not writable"] unless File.writable?(dir)

        history_readiness
      end

      def history_readiness
        path = File.join(@config.workdir, "history.sqlite3")
        return [true, "no history yet"] unless File.exist?(path)

        History.new(path, logger: @logger).last_per_database
        [true, "ok"]
      rescue StandardError => e
        [false, "history unreadable: #{e.message}"]
      end
    end
  end
end
