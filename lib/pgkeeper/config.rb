# frozen_string_literal: true

require "yaml"
require "erb"

module PgKeeper
  # Loads and validates the declarative +pgkeeper.yml+ config.
  #
  # The file is run through ERB first, so +<%= ENV["..."] %>+ interpolation
  # pulls secrets from the environment rather than committing them to git. The
  # parsed structure is then validated against a strict schema: unknown keys,
  # missing required fields, and bad enum values all fail fast — before we ever
  # touch a database — with every problem reported at once.
  #
  #   config = PgKeeper::Config.load("config/pgkeeper.yml")
  #   config.databases.each { |db| ... }
  class Config
    DUMP_FORMATS = %w[custom plain directory].freeze
    COMPRESSION = %w[none gzip zip zstd].freeze
    NOTIFY_EVENTS = %w[success failure].freeze

    # Allowed keys per storage backend type, for strict validation.
    STORAGE_KEYS = {
      "local" => %w[type path],
      "s3" => %w[type bucket region prefix endpoint access_key_id secret_access_key force_path_style],
      "memory" => %w[type]
    }.freeze

    DEFAULT_WORKDIR = "/var/backups/pgkeeper"

    attr_reader :source, :raw, :databases, :storage, :retention,
                :compression, :encryption, :notifications, :workdir

    # Load and validate config from a YAML file path.
    def self.load(path, env: ENV)
      raise ConfigError, "config file not found: #{path}" unless File.file?(path)

      raw = File.read(path)
      new(render(raw, path), source: path, env: env)
    rescue Psych::SyntaxError => e
      raise ConfigError, "invalid YAML in #{path}: #{e.message}"
    end

    # Load and validate config from an already-rendered YAML string. Useful in
    # tests and for library callers that assemble config themselves.
    def self.parse(yaml, source: "<string>", env: ENV)
      new(YAML.safe_load(yaml, permitted_classes: [], aliases: true) || {}, source: source, env: env)
    rescue Psych::SyntaxError => e
      raise ConfigError, "invalid YAML in #{source}: #{e.message}"
    end

    # Render ERB, then parse YAML. ERB runs with access to +ENV+ so config can
    # interpolate secrets.
    def self.render(erb_source, source)
      rendered = ERB.new(erb_source, trim_mode: "-").result(TOPLEVEL_BINDING.dup)
      YAML.safe_load(rendered, permitted_classes: [], aliases: true) || {}
    rescue Psych::SyntaxError => e
      raise ConfigError, "invalid YAML in #{source}: #{e.message}"
    end

    def initialize(hash, source: "<hash>", env: ENV)
      @source = source
      @env = env
      @raw = deep_stringify(hash)
      @problems = []

      validate_and_build!
      return if @problems.empty?

      raise ConfigError.new(
        "invalid configuration in #{source} (#{@problems.length} problem(s))",
        problems: @problems
      )
    end

    # The database matching +name+, or nil.
    def database(name)
      @databases.find { |db| db.name == name }
    end

    # Local storage target path, if a +local+ storage backend is configured.
    def local_path
      target = @storage.find { |s| s["type"] == "local" }
      target && target["path"]
    end

    private

    def validate_and_build!
      unless @raw.is_a?(Hash)
        problem("top level of config must be a mapping (got #{@raw.class})")
        return
      end

      reject_unknown_keys(@raw, %w[databases defaults compression encryption storage
                                   retention notifications workdir], "(root)")

      @workdir = string_or_default(@raw["workdir"], DEFAULT_WORKDIR, "workdir")
      @compression = enum_or_default(@raw["compression"], COMPRESSION, "none", "compression")
      @encryption = build_encryption(@raw["encryption"])
      @databases = build_databases(@raw["databases"], @raw["defaults"])
      @storage = build_storage(@raw["storage"])
      @retention = build_retention(@raw["retention"])
      @notifications = build_notifications(@raw["notifications"])
    end

    def build_databases(list, defaults)
      defaults ||= {}
      unless defaults.is_a?(Hash)
        problem("`defaults` must be a mapping")
        defaults = {}
      end

      unless list.is_a?(Array) && !list.empty?
        problem("`databases` is required and must be a non-empty list")
        return []
      end

      seen = {}
      list.each_with_index.filter_map do |entry, idx|
        db = build_database(entry, defaults, idx)
        next unless db

        if seen[db.name]
          problem("duplicate database name #{db.name.inspect}")
          next
        end
        seen[db.name] = true
        db
      end
    end

    def build_database(entry, defaults, idx)
      unless entry.is_a?(Hash)
        problem("databases[#{idx}] must be a mapping")
        return nil
      end

      merged = defaults.merge(entry)
      reject_unknown_keys(merged, DatabaseConfig::KEYS, "databases[#{idx}]")

      name = merged["name"]
      unless name.is_a?(String) && !name.strip.empty?
        problem("databases[#{idx}] is missing a non-empty `name`")
        return nil
      end

      DatabaseConfig.new(merged, global_compression: @compression).tap do |db|
        db.validation_problems.each { |p| problem("database #{name.inspect}: #{p}") }
      end
    end

    def build_storage(list)
      return default_storage if list.nil?

      unless list.is_a?(Array)
        problem("`storage` must be a list of targets")
        return default_storage
      end

      list.each_with_index.filter_map { |entry, idx| build_storage_target(entry, idx) }
    end

    def default_storage
      [{ "type" => "local", "path" => File.join(@workdir || DEFAULT_WORKDIR, "backups") }]
    end

    def build_storage_target(entry, idx)
      unless entry.is_a?(Hash) && entry["type"].is_a?(String)
        problem("storage[#{idx}] must be a mapping with a `type`")
        return nil
      end

      type = entry["type"]
      unless STORAGE_KEYS.key?(type)
        problem("storage[#{idx}] has unknown type #{type.inspect} (expected one of #{STORAGE_KEYS.keys.join(', ')})")
        return entry
      end

      reject_unknown_keys(entry, STORAGE_KEYS.fetch(type), "storage[#{idx}] (#{type})")
      validate_storage_required(entry, type, idx)
      entry
    end

    def validate_storage_required(entry, type, idx)
      case type
      when "local"
        problem("storage[#{idx}] (local) requires a `path`") unless entry["path"].is_a?(String)
      when "s3"
        problem("storage[#{idx}] (s3) requires a `bucket`") unless entry["bucket"].is_a?(String)
      end
    end

    def build_retention(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        problem("`retention` must be a mapping")
        return {}
      end

      allowed = %w[keep_last keep_daily keep_weekly keep_monthly keep_yearly]
      reject_unknown_keys(hash, allowed, "retention")
      hash.each do |key, value|
        next if value.is_a?(Integer) && value >= 0

        problem("retention.#{key} must be a non-negative integer")
      end
      hash
    end

    def build_encryption(hash)
      return { "enabled" => false } if hash.nil?

      unless hash.is_a?(Hash)
        problem("`encryption` must be a mapping")
        return { "enabled" => false }
      end

      reject_unknown_keys(hash, %w[enabled type passphrase_env keyfile recipient], "encryption")
      hash["enabled"] = !!hash["enabled"]
      hash
    end

    def build_notifications(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        problem("`notifications` must be a mapping")
        return {}
      end

      email = hash["email"]
      validate_notification_events(email) if email.is_a?(Hash)
      hash
    end

    # Validate the `on:` trigger list. Note the YAML 1.1 footgun: Psych parses a
    # bare `on:` key as the boolean `true`, which deep_stringify turns into the
    # string "true". We accept both so the documented `on: [success, failure]`
    # form actually works instead of silently disabling triggers.
    def validate_notification_events(email)
      raw = email["on"] || email["true"]
      return if raw.nil?

      events = Array(raw).map(&:to_s)
      bad = events - NOTIFY_EVENTS
      problem("notifications.email.on has unknown event(s): #{bad.join(', ')}") unless bad.empty?
    end

    # -- validation helpers ------------------------------------------------

    def reject_unknown_keys(hash, allowed, context)
      return unless hash.is_a?(Hash)

      unknown = hash.keys.map(&:to_s) - allowed
      return if unknown.empty?

      problem("#{context} has unknown key(s): #{unknown.join(', ')} (allowed: #{allowed.join(', ')})")
    end

    def enum_or_default(value, allowed, default, key)
      return default if value.nil?

      value = value.to_s
      unless allowed.include?(value)
        problem("#{key} must be one of #{allowed.join(', ')} (got #{value.inspect})")
        return default
      end
      value
    end

    def string_or_default(value, default, key)
      return default if value.nil?
      return value if value.is_a?(String)

      problem("#{key} must be a string")
      default
    end

    def problem(message)
      @problems << message
    end

    def deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      else obj
      end
    end
  end

  # A single database's connection + dump settings, after global defaults have
  # been merged in. Validates its own fields and exposes the environment used to
  # invoke +pg_dump+ (libpq env vars), keeping the password out of argv.
  class DatabaseConfig
    KEYS = %w[name host port username password database format include_globals
              schemas exclude_tables sslmode pgpass connect_timeout].freeze

    attr_reader :name, :host, :port, :username, :password, :database,
                :format, :include_globals, :schemas, :exclude_tables,
                :sslmode, :connect_timeout, :validation_problems

    def initialize(hash, global_compression: "none")
      @validation_problems = []
      @global_compression = global_compression

      @name = hash["name"]
      @database = hash["database"] || @name
      @host = hash["host"]
      @port = coerce_port(hash["port"])
      @username = hash["username"]
      @password = hash["password"]
      @format = coerce_format(hash["format"])
      @include_globals = !!hash.fetch("include_globals", false)
      @schemas = Array(hash["schemas"]).map(&:to_s)
      @exclude_tables = Array(hash["exclude_tables"]).map(&:to_s)
      @sslmode = hash["sslmode"]
      @connect_timeout = hash["connect_timeout"]
      @use_pgpass = !!hash["pgpass"]
    end

    # libpq environment for invoking pg_dump/pg_dumpall/psql without putting
    # credentials on the command line. Only sets what is configured, so
    # +PGPASSFILE+/+.pgpass+ and ambient libpq env vars still work.
    def libpq_env
      env = {}
      env["PGHOST"] = host if host
      env["PGPORT"] = port.to_s if port
      env["PGUSER"] = username if username
      env["PGDATABASE"] = database if database
      env["PGPASSWORD"] = password if password && !@use_pgpass
      env["PGSSLMODE"] = sslmode if sslmode
      env["PGCONNECT_TIMEOUT"] = connect_timeout.to_s if connect_timeout
      env
    end

    # File-system-safe slug used in artifact filenames.
    def slug
      name.gsub(/[^A-Za-z0-9_.-]/, "_")
    end

    private

    def coerce_port(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      Integer(value.to_s)
    rescue ArgumentError
      @validation_problems << "port must be an integer (got #{value.inspect})"
      nil
    end

    def coerce_format(value)
      value = (value || "custom").to_s
      unless Config::DUMP_FORMATS.include?(value)
        @validation_problems << "format must be one of #{Config::DUMP_FORMATS.join(', ')} (got #{value.inspect})"
        return "custom"
      end
      value
    end
  end
end
