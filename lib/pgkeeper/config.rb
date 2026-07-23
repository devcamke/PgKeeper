# frozen_string_literal: true

require "yaml"
require "erb"

require "pgkeeper/pitr/config"

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
    # Every type also accepts an optional friendly `name` (an alias used to
    # select the destination for a run and to label it in history).
    STORAGE_KEYS = {
      "local" => %w[type name path],
      "s3" => %w[type name bucket region prefix endpoint access_key_id secret_access_key
                 force_path_style object_lock],
      "dropbox" => %w[type name root access_token refresh_token app_key app_secret],
      "google_drive" => %w[type name folder_id credentials_json credentials_file],
      "sharepoint" => %w[type name drive_id tenant_id client_id client_secret root],
      "memory" => %w[type name]
    }.freeze

    DEFAULT_WORKDIR = "/var/backups/pgkeeper"

    # Wall-clock deadlines (seconds) for the external tools PgKeeper shells out
    # to. Generous by default so a legitimate large dump never trips them, but
    # finite so a genuinely hung child can't block a run forever. A value of 0
    # disables the deadline for that class of command.
    DEFAULT_TIMEOUTS = {
      "dump" => 21_600,    # pg_dump / pg_dumpall (6h)
      "restore" => 21_600, # pg_restore / psql restore (6h)
      "verify" => 3_600,   # deep-verify restore into a scratch database (1h)
      "query" => 60        # short metadata queries: size estimate, guards, SHOW (60s)
    }.freeze

    # Backup-size anomaly detection defaults. A dump that is suddenly far
    # smaller than its recent history is the classic sign of a silently broken
    # backup (a dropped table, a bad --exclude, a half-empty database).
    DEFAULT_ANOMALY = {
      "enabled" => true,
      "min_samples" => 2,  # need at least this many prior successful runs to judge
      "sample_size" => 5,  # baseline is the median of the last N successful runs
      "shrink_pct" => 50,  # warn when today's dump is >= this % smaller than baseline
      "grow_pct" => 0      # warn when it is this % larger (0 disables growth warnings)
    }.freeze

    # Object Lock (WORM) retention modes for S3-family destinations. GOVERNANCE
    # can be bypassed by a privileged caller; COMPLIANCE cannot be shortened or
    # removed by anyone (including the root account) until the object expires.
    OBJECT_LOCK_MODES = %w[GOVERNANCE COMPLIANCE].freeze

    attr_reader :source, :raw, :databases, :storage, :retention,
                :compression, :encryption, :notifications, :workdir, :schedule, :web,
                :timeouts, :anomaly, :maintenance, :clusters

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

    # The cluster matching +name+, or nil.
    def cluster(name)
      @clusters.find { |c| c.name == name }
    end

    # Clusters with PITR enabled (the ones base backups / WAL archiving act on).
    def pitr_clusters
      @clusters.select(&:pitr?)
    end

    # The deadline (seconds) for a class of command (:dump, :restore, :verify,
    # :query), or nil when disabled (a configured 0).
    def timeout(kind)
      value = @timeouts[kind.to_s]
      value&.positive? ? value : nil
    end

    # Local storage target path, if a +local+ storage backend is configured.
    def local_path
      target = @storage.find { |s| s["type"] == "local" }
      target && target["path"]
    end

    # One selectable {Destination} per configured storage target. +token+ is
    # what `pgkeeper backup --destinations` and the web API accept to scope a
    # run to that destination; +label+ is for humans (pickers, docs).
    Destination = Struct.new(:token, :label, :type, :name, keyword_init: true)

    def destinations
      @storage.map do |target|
        name = target["name"].to_s
        token = name.empty? ? target["type"].to_s : name
        label = name.empty? ? target["type"].to_s : "#{name} (#{target['type']})"
        Destination.new(token: token, label: label, type: target["type"], name: (name unless name.empty?))
      end
    end

    private

    def validate_and_build!
      unless @raw.is_a?(Hash)
        problem("top level of config must be a mapping (got #{@raw.class})")
        return
      end

      reject_unknown_keys(@raw, %w[databases defaults compression encryption storage
                                   retention notifications workdir schedule web
                                   timeouts anomaly maintenance clusters], "(root)")

      @workdir = string_or_default(@raw["workdir"], DEFAULT_WORKDIR, "workdir")
      @schedule = validate_schedule(@raw["schedule"], "schedule")
      @compression = enum_or_default(@raw["compression"], COMPRESSION, "none", "compression")
      @encryption = build_encryption(@raw["encryption"])
      @databases = build_databases(@raw["databases"], @raw["defaults"])
      @storage = build_storage(@raw["storage"])
      @retention = build_retention(@raw["retention"])
      @notifications = build_notifications(@raw["notifications"])
      @web = build_web(@raw["web"])
      @clusters = build_clusters(@raw["clusters"])
      build_scheduling_and_limits!
    end

    # The upkeep/limit sections: what to schedule beyond the backup, wall-clock
    # deadlines, and anomaly thresholds.
    def build_scheduling_and_limits!
      @maintenance = build_maintenance(@raw["maintenance"])
      @timeouts = build_timeouts(@raw["timeouts"])
      @anomaly = build_anomaly(@raw["anomaly"])
    end

    def build_timeouts(hash)
      return DEFAULT_TIMEOUTS.dup if hash.nil?

      unless hash.is_a?(Hash)
        problem("`timeouts` must be a mapping")
        return DEFAULT_TIMEOUTS.dup
      end

      reject_unknown_keys(hash, DEFAULT_TIMEOUTS.keys, "timeouts")
      hash.each do |key, value|
        next if value.is_a?(Integer) && value >= 0

        problem("timeouts.#{key} must be a non-negative integer (seconds; 0 disables)")
      end
      DEFAULT_TIMEOUTS.merge(hash.select { |_, v| v.is_a?(Integer) && v >= 0 })
    end

    def build_anomaly(hash)
      return DEFAULT_ANOMALY.dup if hash.nil?

      unless hash.is_a?(Hash)
        problem("`anomaly` must be a mapping")
        return DEFAULT_ANOMALY.dup
      end

      reject_unknown_keys(hash, DEFAULT_ANOMALY.keys, "anomaly")
      merged = DEFAULT_ANOMALY.dup
      merged["enabled"] = !!hash["enabled"] if hash.key?("enabled")
      validate_anomaly_numbers(hash, merged)
      merged
    end

    def validate_anomaly_numbers(hash, merged)
      %w[min_samples sample_size shrink_pct grow_pct].each do |key|
        next unless hash.key?(key)

        value = hash[key]
        if value.is_a?(Integer) && value >= 0
          merged[key] = value
        else
          problem("anomaly.#{key} must be a non-negative integer")
        end
      end
    end

    # The optional `maintenance:` block schedules the two upkeep jobs that keep
    # backups *trustworthy* and *bounded* — verification and pruning — the same
    # way `schedule:` schedules the backup itself. Without this, only backups
    # could be automated; verify/prune had to be hand-wired into cron.
    def build_maintenance(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        problem("`maintenance` must be a mapping")
        return {}
      end

      reject_unknown_keys(hash, %w[verify prune], "maintenance")
      {
        "verify" => build_maintenance_task(hash["verify"], "verify", %w[schedule deep only]),
        "prune" => build_maintenance_task(hash["prune"], "prune", %w[schedule apply only])
      }.compact
    end

    def build_maintenance_task(cfg, name, allowed)
      return nil if cfg.nil?

      unless cfg.is_a?(Hash)
        problem("maintenance.#{name} must be a mapping")
        return nil
      end

      reject_unknown_keys(cfg, allowed, "maintenance.#{name}")
      task = cfg.dup
      task["schedule"] = validate_maintenance_schedule(task["schedule"], name)
      task["only"] = normalize_only(task["only"], name) if task.key?("only")
      coerce_maintenance_flags(task, name, allowed)
      task
    end

    def validate_maintenance_schedule(value, name)
      if value.nil?
        problem("maintenance.#{name} requires a `schedule`")
        return nil
      end
      validate_schedule(value, "maintenance.#{name}.schedule")
    end

    # `only:` accepts a single database name or a list of them.
    def normalize_only(value, name)
      list = Array(value).map(&:to_s)
      if list.empty? || list.any?(&:empty?)
        problem("maintenance.#{name}.only must be a database name or a non-empty list of names")
        return nil
      end
      list
    end

    # `deep:` (verify) and `apply:` (prune) are booleans; coerce leniently, the
    # same way `encryption.enabled` and `anomaly.enabled` are handled.
    def coerce_maintenance_flags(task, _name, allowed)
      %w[deep apply].each do |flag|
        task[flag] = !!task[flag] if allowed.include?(flag) && task.key?(flag)
      end
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

    # Physical clusters for PITR (Phase 12). Optional and separate from the
    # logical `databases:` list — a cluster is the whole instance. Stage 0 parses
    # and validates them; no base-backup/WAL behavior acts on them yet.
    def build_clusters(list)
      return [] if list.nil?

      unless list.is_a?(Array)
        problem("`clusters` must be a list")
        return []
      end

      seen = {}
      list.each_with_index.filter_map { |entry, idx| build_cluster(entry, idx, seen) }
    end

    def build_cluster(entry, idx, seen)
      unless entry.is_a?(Hash)
        problem("clusters[#{idx}] must be a mapping")
        return nil
      end

      reject_unknown_keys(entry, ClusterConfig::KEYS, "clusters[#{idx}]")
      name = entry["name"]
      unless name.is_a?(String) && !name.strip.empty?
        problem("clusters[#{idx}] is missing a non-empty `name`")
        return nil
      end
      if seen[name]
        problem("duplicate cluster name #{name.inspect}")
        return nil
      end
      seen[name] = true

      ClusterConfig.new(entry).tap do |c|
        c.validation_problems.each { |p| problem("cluster #{name.inspect}: #{p}") }
      end
    end

    def build_storage(list)
      return default_storage if list.nil?

      unless list.is_a?(Array)
        problem("`storage` must be a list of targets")
        return default_storage
      end

      targets = list.each_with_index.filter_map { |entry, idx| build_storage_target(entry, idx) }
      validate_storage_names(targets)
      targets
    end

    # Friendly `name:` aliases must be unique and must not shadow a storage
    # type keyword — both would make destination selection ambiguous.
    def validate_storage_names(targets)
      seen = {}
      targets.each_with_index do |target, idx|
        name = target["name"]
        next if name.nil?

        unless name.is_a?(String) && !name.strip.empty?
          problem("storage[#{idx}] `name` must be a non-empty string")
          next
        end
        problem("storage[#{idx}] `name` #{name.inspect} collides with a storage type") if STORAGE_KEYS.key?(name)
        problem("duplicate storage name #{name.inspect}") if seen[name]
        seen[name] = true
      end
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
        validate_object_lock(entry["object_lock"], idx)
      when "dropbox"
        validate_dropbox_credentials(entry, idx)
      when "google_drive"
        validate_google_drive(entry, idx)
      when "sharepoint"
        validate_sharepoint(entry, idx)
      end
    end

    # Object Lock makes uploaded backups immutable (WORM) for a retention window,
    # so a leaked credential or a rogue `prune` can't delete them before they
    # expire. The bucket itself must have Object Lock enabled (a create-time
    # setting on S3); PgKeeper only sets per-object retention on upload.
    def validate_object_lock(cfg, idx)
      return if cfg.nil?

      unless cfg.is_a?(Hash)
        problem("storage[#{idx}] (s3) `object_lock` must be a mapping")
        return
      end

      reject_unknown_keys(cfg, %w[mode retain_days], "storage[#{idx}] (s3) object_lock")
      mode = cfg["mode"].to_s
      unless OBJECT_LOCK_MODES.include?(mode)
        problem("storage[#{idx}] (s3) object_lock.mode must be one of #{OBJECT_LOCK_MODES.join(', ')}")
      end
      days = cfg["retain_days"]
      return if days.is_a?(Integer) && days.positive?

      problem("storage[#{idx}] (s3) object_lock.retain_days must be a positive integer (days)")
    end

    # Dropbox needs either a direct access token or a full refresh-token triple.
    def validate_dropbox_credentials(entry, idx)
      return if entry["access_token"].is_a?(String)
      return if %w[refresh_token app_key app_secret].all? { |k| entry[k].is_a?(String) }

      problem("storage[#{idx}] (dropbox) requires `access_token`, " \
              "or `refresh_token` + `app_key` + `app_secret`")
    end

    # Google Drive needs the target folder plus service-account credentials,
    # supplied inline or as a file path.
    def validate_google_drive(entry, idx)
      problem("storage[#{idx}] (google_drive) requires a `folder_id`") unless entry["folder_id"].is_a?(String)
      return if entry["credentials_json"].is_a?(String) || entry["credentials_file"].is_a?(String)

      problem("storage[#{idx}] (google_drive) requires `credentials_json` or `credentials_file`")
    end

    # SharePoint/OneDrive needs the target drive plus the app registration's
    # tenant and client credentials.
    def validate_sharepoint(entry, idx)
      %w[drive_id tenant_id client_id client_secret].each do |key|
        problem("storage[#{idx}] (sharepoint) requires `#{key}`") unless entry[key].is_a?(String)
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

      reject_unknown_keys(hash, %w[enabled type passphrase_env keyfile recipient
                                   previous_passphrase_envs previous_keyfiles], "encryption")
      hash["enabled"] = !!hash["enabled"]
      validate_previous_keys(hash)
      hash
    end

    # `previous_passphrase_envs` / `previous_keyfiles` list the *old* keys retired
    # by a key rotation. New backups use the primary key; old backups stay
    # decryptable (restore + verify) because these are tried in turn. Both must
    # be lists of strings.
    def validate_previous_keys(hash)
      %w[previous_passphrase_envs previous_keyfiles].each do |key|
        value = hash[key]
        next if value.nil?

        unless value.is_a?(Array) && value.all?(String)
          problem("encryption.#{key} must be a list of strings")
          next
        end
        hash[key] = value
      end
    end

    def build_notifications(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        problem("`notifications` must be a mapping")
        return {}
      end

      reject_unknown_keys(hash, %w[email webhook healthcheck], "notifications")
      validate_notifier(hash["email"], "email")
      validate_notifier(hash["webhook"], "webhook", required: %w[url])
      validate_notifier(hash["healthcheck"], "healthcheck", required: %w[url])
      hash
    end

    def validate_notifier(cfg, name, required: [])
      return if cfg.nil?

      unless cfg.is_a?(Hash)
        problem("notifications.#{name} must be a mapping")
        return
      end

      required.each do |key|
        problem("notifications.#{name} requires `#{key}`") unless cfg[key].is_a?(String)
      end
      validate_notification_events(cfg, name)
    end

    # Validate the `on:` trigger list. Note the YAML 1.1 footgun: Psych parses a
    # bare `on:` key as the boolean `true`, which deep_stringify turns into the
    # string "true". We accept both so the documented `on: [success, failure]`
    # form actually works instead of silently disabling triggers.
    def validate_notification_events(cfg, name)
      raw = cfg["on"] || cfg["true"]
      return if raw.nil?

      bad = Array(raw).map(&:to_s) - NOTIFY_EVENTS
      problem("notifications.#{name}.on has unknown event(s): #{bad.join(', ')}") unless bad.empty?
    end

    # Validate the optional `web:` dashboard block. Shape errors fail fast, but
    # credential *presence* is deliberately not enforced here: an unset env var
    # renders to nil, and a missing web token must never stop a backup run.
    # `pgkeeper web` enforces credentials at startup instead.
    def build_web(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        problem("`web` must be a mapping")
        return {}
      end

      reject_unknown_keys(hash, %w[bind port auth], "web")
      port = hash["port"]
      unless port.nil? || (port.is_a?(Integer) && port.between?(1, 65_535))
        problem("web.port must be an integer between 1 and 65535")
      end
      validate_web_auth(hash["auth"])
      hash
    end

    def validate_web_auth(auth)
      return if auth.nil?
      return problem("web.auth must be a mapping") unless auth.is_a?(Hash)

      reject_unknown_keys(auth, %w[token tokens username password], "web.auth")
      %w[token username password].each do |key|
        value = auth[key]
        problem("web.auth.#{key} must be a string") unless value.nil? || value.is_a?(String)
      end
      validate_web_auth_tokens(auth["tokens"])
    end

    # `tokens:` is a map of caller name => secret, so each caller can be revoked
    # on its own. Names must be non-empty and secrets must be strings.
    def validate_web_auth_tokens(tokens)
      return if tokens.nil?
      return problem("web.auth.tokens must be a mapping of name => token") unless tokens.is_a?(Hash)

      tokens.each do |name, secret|
        problem("web.auth.tokens has an empty token name") if name.to_s.strip.empty?
        problem("web.auth.tokens.#{name} must be a string") unless secret.is_a?(String)
      end
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

    # Validate a schedule expression parses (cron / natural language), returning
    # the original string for the scheduler to re-parse.
    def validate_schedule(value, key)
      return nil if value.nil?

      unless value.is_a?(String)
        problem("#{key} must be a string schedule expression")
        return nil
      end

      Schedule.parse(value)
      value
    rescue ConfigError => e
      problem("#{key}: #{e.message}")
      nil
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
              schemas exclude_tables sslmode pgpass connect_timeout schedule].freeze

    attr_reader :name, :host, :port, :username, :password, :database,
                :format, :include_globals, :schemas, :exclude_tables,
                :sslmode, :connect_timeout, :schedule, :validation_problems

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
      @schedule = coerce_schedule(hash["schedule"])
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

    def coerce_schedule(value)
      return nil if value.nil?

      Schedule.parse(value.to_s)
      value.to_s
    rescue ConfigError => e
      @validation_problems << "schedule: #{e.message}"
      nil
    end
  end
end
