# frozen_string_literal: true

module PgKeeper
  module Web
    # The "add a database from the web" flow: validate the submitted details,
    # probe the server with them, and only then splice the entry into
    # +pgkeeper.yml+ via {ConfigWriter}'s targeted text surgery — comments and
    # ERB interpolations in the file survive untouched.
    #
    # The security posture mirrors the wizard's, not a config editor's:
    #
    #   * The submitted password is used for the probe only. What lands in the
    #     file is an `<%= ENV["PGKEEPER_<NAME>_PASSWORD"] %>` reference —
    #     secrets stay in the environment, never in the config.
    #   * The updated text is re-validated as a full config before it is
    #     written; an entry that would break the file is rejected instead.
    #   * This route is browser-only (CSRF + confirm gate). It is deliberately
    #     not exposed on the Bearer-token JSON API: a leaked API token can
    #     trigger backups, not rewrite where they point.
    #
    # The running daemon reads config at boot, so every success message ends
    # with "restart pgkeeper" — the flow writes the file, it does not hot-load.
    class DatabaseAdmin
      Result = Struct.new(:ok, :message, keyword_init: true)

      # Names end up in filenames, env-var names, and YAML — keep them boring.
      NAME_PATTERN = /\A[A-Za-z0-9_.-]+\z/

      SSLMODES = %w[disable allow prefer require verify-ca verify-full].freeze

      # Connect deadline (seconds) applied to the probe when the form leaves it
      # unset, so a dead host answers in seconds, not libpq's forever.
      PROBE_CONNECT_TIMEOUT = 10

      def initialize(config, connections:, logger: PgKeeper.logger)
        @config = config
        @connections = connections
        @logger = logger
      end

      # Whether the config can be edited at all: it must have come from a real,
      # writable file (not a string, not a read-only mount).
      def editable?
        source = @config.source.to_s
        File.file?(source) && File.writable?(source)
      end

      # Validate, probe, append. Returns a {Result}; nothing is ever written
      # unless the probe succeeded and the updated file re-validates.
      def add(params)
        entry, password, problems = build_entry(params)
        return failure(problems.join("; ")) unless problems.empty?
        return failure("the config (#{@config.source}) is not an editable file") unless editable?

        probe = @connections.probe(probe_env(entry, password))
        return failure("connection failed: #{probe[:error] || 'unknown error'}") unless probe[:ok]

        write(entry, password)
      end

      private

      # -- validation --------------------------------------------------------

      def build_entry(params)
        problems = []
        name = validate_name(params["name"].to_s.strip, problems)
        entry = {
          "name" => name,
          "host" => presence(params["host"]),
          "port" => validate_port(params["port"], problems),
          "database" => presence(params["database"]),
          "username" => presence(params["username"]),
          "sslmode" => validate_sslmode(params["sslmode"], problems)
        }
        [entry, presence(params["password"]), problems]
      end

      def validate_name(name, problems)
        if name.empty?
          problems << "a name is required"
        elsif !name.match?(NAME_PATTERN)
          problems << "name may only contain letters, digits, and _ . - " \
                      "(it becomes filenames and an env-var name)"
        elsif @config.database(name)
          problems << "a database named #{name.inspect} already exists"
        end
        name
      end

      def validate_port(value, problems)
        raw = presence(value)
        return nil if raw.nil?

        port = Integer(raw, exception: false)
        return port if port&.between?(1, 65_535)

        problems << "port must be an integer between 1 and 65535"
        nil
      end

      def validate_sslmode(value, problems)
        mode = presence(value)
        return nil if mode.nil?
        return mode if SSLMODES.include?(mode)

        problems << "sslmode must be one of #{SSLMODES.join(', ')}"
        nil
      end

      # -- probe -------------------------------------------------------------

      # The exact env a run would use — including the submitted password, which
      # exists only here — with a bounded connect deadline layered on.
      def probe_env(entry, password)
        env = DatabaseConfig.new(entry.merge("password" => password)).libpq_env
        env["PGCONNECT_TIMEOUT"] ||= PROBE_CONNECT_TIMEOUT.to_s
        env
      end

      # -- persist -----------------------------------------------------------

      def write(entry, password)
        rendered = ConfigWriter.render_database(file_entry(entry, password))
        text = File.read(@config.source, encoding: "UTF-8")
        updated = ConfigWriter.append_database(text, rendered)
        revalidate!(updated)
        ConfigWriter.write(@config.source, updated)
        @logger.info("dashboard added database", database: entry["name"], path: @config.source)
        Result.new(ok: true, message: success_message(entry, password))
      rescue ConfigError => e
        failure(e.message)
      end

      # The entry as written: compacted, with the password swapped for its ENV
      # reference. Key order matches the wizard's output.
      def file_entry(entry, password)
        written = entry.compact
        written["password_env"] = ConfigWriter.password_env(entry["name"]) if password
        written
      end

      # Parse + validate the updated text exactly as `Config.load` will at next
      # boot (ERB included), so a bad merge is caught before it hits disk.
      # {Config#initialize} raises ConfigError when validation fails.
      def revalidate!(updated)
        Config.new(Config.render(updated, @config.source), source: @config.source)
      end

      def success_message(entry, password)
        message = "added #{entry['name']} to #{@config.source}"
        if password
          message += " — export #{ConfigWriter.password_env(entry['name'])} " \
                     "(the file only references it)"
        end
        "#{message}; restart pgkeeper to load it"
      end

      def failure(message)
        Result.new(ok: false, message: "nothing was written — #{message}")
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
