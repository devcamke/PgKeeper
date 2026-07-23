# frozen_string_literal: true

require "pgkeeper/schedule"

module PgKeeper
  # A physical PostgreSQL cluster targeted for Point-in-Time Recovery.
  #
  # Unlike a {DatabaseConfig} — one logical database captured with +pg_dump+ — a
  # cluster is the whole instance: +pg_basebackup+ plus a continuous WAL stream
  # cover every database at once. This object carries the connection PITR uses
  # (for base backups and replication) and an optional {PitrConfig}. It validates
  # its own fields and exposes the libpq environment, keeping credentials out of
  # argv, exactly like {DatabaseConfig}.
  #
  # Stage 0 (config + doctor): parsing and validation only. No base-backup or
  # WAL behavior ships against this object yet — see docs/PITR-DESIGN.md.
  class ClusterConfig
    KEYS = %w[name host port username password database sslmode connect_timeout pgpass pitr].freeze

    attr_reader :name, :host, :port, :username, :password, :database,
                :sslmode, :connect_timeout, :pitr, :validation_problems

    def initialize(hash)
      @validation_problems = []
      @name = hash["name"]
      @host = hash["host"]
      @port = coerce_port(hash["port"])
      @username = hash["username"]
      @password = hash["password"]
      # The maintenance database PITR connects to (server-wide operations don't
      # target a single user database); defaults to "postgres".
      @database = hash["database"] || "postgres"
      @sslmode = hash["sslmode"]
      @connect_timeout = hash["connect_timeout"]
      @use_pgpass = !!hash["pgpass"]
      @pitr = PitrConfig.new(hash["pitr"])
      @pitr.validation_problems.each { |p| @validation_problems << "pitr: #{p}" }
    end

    # True when this cluster has PITR turned on.
    def pitr? = @pitr.enabled

    # libpq environment for invoking psql/pg_basebackup/pg_receivewal without
    # putting credentials on the command line. Only sets what is configured, so
    # +.pgpass+ and ambient libpq vars still work.
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

    # File-system-safe slug used in artifact paths.
    def slug = name.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")

    private

    def coerce_port(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      Integer(value.to_s)
    rescue ArgumentError
      @validation_problems << "port must be an integer (got #{value.inspect})"
      nil
    end
  end

  # The +pitr:+ sub-block of a cluster: whether PITR is on, how WAL is captured,
  # the recovery window it promises, the base-backup cadence, and an optional
  # destination subset. Self-validating (accumulates +validation_problems+).
  class PitrConfig
    KEYS = %w[enabled mode slot recovery_window max_lag base_backup destinations].freeze
    MODES = %w[stream archive].freeze
    BASE_BACKUP_KEYS = %w[schedule].freeze

    # Duration suffixes accepted by +recovery_window+ (e.g. "7d", "12h").
    DURATION_UNITS = { "s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400, "w" => 604_800 }.freeze

    attr_reader :enabled, :mode, :slot, :recovery_window, :recovery_window_seconds,
                :max_lag, :max_lag_seconds, :base_backup_schedule, :destinations, :validation_problems

    def initialize(hash)
      @validation_problems = []
      hash = normalize(hash)

      @enabled = !!hash.fetch("enabled", false)
      @mode = coerce_enum(hash["mode"] || "stream", MODES, "mode")
      @slot = hash["slot"] || "pgkeeper"
      @recovery_window = hash["recovery_window"]
      @recovery_window_seconds = coerce_duration(@recovery_window, "recovery_window") unless @recovery_window.nil?
      # The dead-man's switch: alarm when the newest archived WAL is older than
      # this. Unset means "report lag, don't alarm on it".
      @max_lag = hash["max_lag"]
      @max_lag_seconds = coerce_duration(@max_lag, "max_lag") unless @max_lag.nil?
      @destinations = coerce_destinations(hash["destinations"])
      @base_backup_schedule = coerce_base_backup(hash["base_backup"])
    end

    private

    def normalize(hash)
      return {} if hash.nil?

      unless hash.is_a?(Hash)
        @validation_problems << "must be a mapping"
        return {}
      end

      reject_unknown(hash, KEYS, "")
      hash
    end

    def coerce_enum(value, allowed, key)
      value = value.to_s
      return value if allowed.include?(value)

      @validation_problems << "#{key} must be one of #{allowed.join(', ')} (got #{value.inspect})"
      allowed.first
    end

    # Parse "<n><unit>" (e.g. "7d") into seconds; record a problem on a bad value.
    def coerce_duration(value, key)
      m = value.to_s.strip.match(/\A(\d+)\s*([smhdw])\z/)
      unless m
        @validation_problems << "#{key} must look like 7d / 12h / 30m (got #{value.inspect})"
        return nil
      end
      m[1].to_i * DURATION_UNITS.fetch(m[2])
    end

    def coerce_destinations(value)
      return nil if value.nil?

      list = Array(value).map(&:to_s).reject(&:empty?)
      return list unless list.empty?

      @validation_problems << "destinations must be a non-empty list of destination tokens"
      nil
    end

    def coerce_base_backup(hash)
      return nil if hash.nil?

      unless hash.is_a?(Hash)
        @validation_problems << "base_backup must be a mapping"
        return nil
      end

      reject_unknown(hash, BASE_BACKUP_KEYS, "base_backup.")
      validate_schedule(hash["schedule"])
    end

    def validate_schedule(value)
      return nil if value.nil?

      unless value.is_a?(String)
        @validation_problems << "base_backup.schedule must be a string"
        return nil
      end

      Schedule.parse(value)
      value
    rescue ConfigError => e
      @validation_problems << "base_backup.schedule: #{e.message}"
      nil
    end

    def reject_unknown(hash, allowed, prefix)
      unknown = hash.keys.map(&:to_s) - allowed
      return if unknown.empty?

      @validation_problems << "#{prefix}unknown key(s): #{unknown.join(', ')} (allowed: #{allowed.join(', ')})"
    end
  end
end
