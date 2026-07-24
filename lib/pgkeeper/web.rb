# frozen_string_literal: true

begin
  require "rack"
rescue LoadError
  raise PgKeeper::EnvironmentError,
        "the web dashboard requires the rack gem — install it with: gem install rack"
end

require "pgkeeper/web/auth"
require "pgkeeper/web/health"
require "pgkeeper/web/jobs"
require "pgkeeper/web/actions"
require "pgkeeper/web/dashboard"
require "pgkeeper/web/connections"
require "pgkeeper/web/app"

module PgKeeper
  # The optional web dashboard (`pgkeeper web`): a browser view of backup
  # health plus safe management actions. It reads the same SQLite run-history
  # and manifests the CLI writes, so there is no second data path to drift out
  # of sync, and management actions run through the same flock as cron — never
  # a second concurrent pipeline.
  #
  # Security posture (non-negotiable, per PLAN.md):
  #   * auth is required — {serve} refuses to start without credentials,
  #   * binds to 127.0.0.1 by default (reverse-proxy for remote access),
  #   * every POST carries a CSRF token,
  #   * restores stay CLI-only — too destructive for a web click.
  #
  # rack (and puma, for {serve}) are optional dependencies, lazy-required here
  # so headless installs never pay for the dashboard.
  module Web
    DEFAULT_BIND = "127.0.0.1"
    DEFAULT_PORT = 8321

    module_function

    # Build the Rack app: the dashboard wrapped in the auth middleware.
    # Credentials come from the config's `web.auth` block.
    def build(config, logger: PgKeeper.logger)
      auth = config.web["auth"] || {}
      authed = Auth.new(
        App.new(config, logger: logger),
        token: presence(auth["token"]),
        tokens: token_map(auth["tokens"]),
        username: presence(auth["username"]),
        password: presence(auth["password"])
      )
      # Health probes sit outside auth so an orchestrator can reach them with no
      # credential; everything else stays behind the auth middleware.
      Health.new(authed, config, logger: logger)
    end

    # Serve the dashboard with puma. Blocks until interrupted.
    def serve(config, logger: PgKeeper.logger, bind: nil, port: nil)
      app = build(config, logger: logger)
      bind ||= config.web["bind"] || DEFAULT_BIND
      port ||= config.web["port"] || DEFAULT_PORT

      logger.info("web dashboard starting", bind: bind, port: port)
      launcher(app, bind, port).run
    end

    def launcher(app, bind, port)
      require "puma"
      require "puma/configuration"
      require "puma/launcher"

      conf = Puma::Configuration.new do |c|
        c.bind "tcp://#{bind}:#{port}"
        c.app app
        c.environment "production"
      end
      Puma::Launcher.new(conf)
    rescue LoadError
      raise EnvironmentError,
            "serving the dashboard requires the puma gem — install it with: gem install puma"
    end

    def presence(value)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end

    # Presence-filter a `tokens:` map (name => secret), dropping blank secrets
    # so an unset environment variable never becomes a usable empty token.
    def token_map(raw)
      return nil unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(name, secret), acc|
        value = presence(secret)
        acc[name.to_s] = value if value
      end
    end
  end
end
