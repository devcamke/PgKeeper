# frozen_string_literal: true

require "open3"

module PgKeeper
  # Environment self-check. +pgkeeper doctor+ answers "is this host actually able
  # to take a backup?" before a scheduled run finds out the hard way at 3 a.m.
  #
  # Checks (v0.1): required binaries on PATH and their versions, config file
  # readability + validity, destination writability, and — when a config is
  # supplied — per-database connectivity and server/client version drift.
  class Doctor
    Check = Struct.new(:name, :status, :detail, keyword_init: true) do
      def ok? = status == :ok
      def warn? = status == :warn
      def fail? = status == :fail
    end

    REQUIRED_TOOLS = %w[pg_dump pg_restore pg_dumpall psql].freeze

    def initialize(config_path: nil, logger: PgKeeper.logger)
      @config_path = config_path
      @logger = logger
      @checks = []
    end

    # Run all checks and return the list of {Check}s.
    def run
      @checks = []
      check_tools
      config = check_config
      if config
        check_databases(config)
        check_clusters(config)
      end
      @checks
    end

    # True if no check failed (warnings are tolerated).
    def self.healthy?(checks)
      checks.none?(&:fail?)
    end

    private

    def check_tools
      REQUIRED_TOOLS.each do |tool|
        version = Dump::Runner.tool_version(tool)
        if version
          add(tool, :ok, version)
        else
          add(tool, :fail, "not found on PATH")
        end
      end
    end

    def check_config
      return nil if @config_path.nil?

      unless File.file?(@config_path)
        add("config", :fail, "not found: #{@config_path}")
        return nil
      end

      config = Config.load(@config_path)
      clusters = config.pitr_clusters.length
      suffix = clusters.positive? ? ", #{clusters} PITR cluster(s)" : ""
      add("config", :ok, "#{@config_path} (#{config.databases.length} database(s)#{suffix})")
      config
    rescue ConfigError => e
      detail = ([e.message] + e.problems.map { |p| "  - #{p}" }).join("\n")
      add("config", :fail, detail)
      nil
    end

    def check_databases(config)
      config.storage.each { |target| check_storage(target) }
      config.databases.each { |db| check_connectivity(db) }
    end

    # Probe each configured storage destination. A missing optional cloud SDK is
    # a warning (the user can install it), not a hard failure of doctor.
    def check_storage(target)
      type = target["type"]
      adapter = Storage.build(target, logger: @logger)
      adapter.healthcheck
      add("storage:#{type}", :ok, adapter.name)
    rescue EnvironmentError => e
      add("storage:#{type}", :warn, e.message)
    rescue StorageError, ConfigError => e
      add("storage:#{type}", :fail, e.message)
    end

    def check_connectivity(db)
      out, status = Open3.capture2e(db.libpq_env, "psql", "-XtAc", "SELECT version()")
      if status.success?
        add("db:#{db.name}", :ok, out.strip.split(" on ").first)
        check_version_drift(db)
      else
        add("db:#{db.name}", :fail, "connection failed: #{out.strip.lines.last&.strip}")
      end
    rescue Errno::ENOENT
      add("db:#{db.name}", :fail, "psql not found on PATH")
    end

    # pg_dump must be at least as new as the server it dumps; an older client
    # against a newer server is a classic silent-corruption footgun.
    def check_version_drift(db)
      server = numeric_version(server_version(db))
      client = numeric_version(Dump::Runner.tool_version("pg_dump", env: db.libpq_env))
      return if server.nil? || client.nil?

      if client >= server
        add("db:#{db.name}:versions", :ok, "pg_dump #{client} >= server #{server}")
      else
        add("db:#{db.name}:versions", :warn,
            "pg_dump #{client} is older than server #{server}; upgrade the client")
      end
    end

    def server_version(db)
      out, status = Open3.capture2e(db.libpq_env, "psql", "-XtAc", "SHOW server_version")
      status.success? ? out.strip : nil
    end

    # -- PITR prerequisites (Phase 12, Stage 0) ----------------------------
    #
    # For each PITR-enabled cluster, verify the host can actually do PITR before
    # a base backup / WAL stream is ever attempted: the physical tools are
    # present and version-matched, the server is reachable, `wal_level` is high
    # enough, and (streaming) there's replication capacity.
    def check_clusters(config)
      config.pitr_clusters.each { |cluster| check_cluster(cluster) }
    end

    def check_cluster(cluster)
      check_pitr_tools(cluster)
      return unless check_cluster_connectivity(cluster)

      check_wal_level(cluster)
      return unless cluster.pitr.mode == "stream"

      check_max_wal_senders(cluster)
      check_replication_role(cluster)
    end

    def check_pitr_tools(cluster)
      tools = ["pg_basebackup"]
      tools << "pg_receivewal" if cluster.pitr.mode == "stream"
      tools.each do |tool|
        version = Dump::Runner.tool_version(tool)
        add("pitr:#{cluster.name}:#{tool}", version ? :ok : :fail, version || "not found on PATH")
      end
    end

    def check_cluster_connectivity(cluster)
      out, status = Open3.capture2e(cluster.libpq_env, "psql", "-XtAc", "SELECT version()")
      if status.success?
        add("pitr:#{cluster.name}", :ok, out.strip.split(" on ").first)
        true
      else
        add("pitr:#{cluster.name}", :fail, "connection failed: #{out.strip.lines.last&.strip}")
        false
      end
    rescue Errno::ENOENT
      add("pitr:#{cluster.name}", :fail, "psql not found on PATH")
      false
    end

    def check_wal_level(cluster)
      level = cluster_show(cluster, "wal_level")
      if %w[replica logical].include?(level)
        add("pitr:#{cluster.name}:wal_level", :ok, level)
      else
        add("pitr:#{cluster.name}:wal_level", :fail,
            "wal_level is #{level.inspect}; PITR needs at least `replica`")
      end
    end

    def check_max_wal_senders(cluster)
      value = cluster_show(cluster, "max_wal_senders").to_i
      if value >= 1
        add("pitr:#{cluster.name}:max_wal_senders", :ok, value.to_s)
      else
        add("pitr:#{cluster.name}:max_wal_senders", :warn,
            "max_wal_senders is #{value}; streaming needs at least 1")
      end
    end

    def check_replication_role(cluster)
      answer = cluster_query(cluster, "SELECT (rolreplication OR rolsuper) FROM pg_roles WHERE rolname = current_user")
      if answer == "t"
        add("pitr:#{cluster.name}:replication", :ok, "role can stream WAL")
      else
        add("pitr:#{cluster.name}:replication", :warn,
            "connecting role lacks REPLICATION; grant it for streaming mode")
      end
    end

    def cluster_show(cluster, setting)
      cluster_query(cluster, "SHOW #{setting}")
    end

    def cluster_query(cluster, sql)
      out, status = Open3.capture2e(cluster.libpq_env, "psql", "-XtAc", sql)
      status.success? ? out.strip : nil
    end

    def numeric_version(str)
      return nil if str.nil?

      str[/(\d+)(?:\.\d+)?/, 1]&.to_i
    end

    def add(name, status, detail)
      @checks << Check.new(name: name, status: status, detail: detail)
    end
  end
end
