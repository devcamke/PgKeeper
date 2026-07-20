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
      check_databases(config) if config
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
      add("config", :ok, "#{@config_path} (#{config.databases.length} database(s))")
      config
    rescue ConfigError => e
      detail = ([e.message] + e.problems.map { |p| "  - #{p}" }).join("\n")
      add("config", :fail, detail)
      nil
    end

    def check_databases(config)
      destination = config.local_path
      check_destination(destination) if destination

      config.databases.each { |db| check_connectivity(db) }
    end

    def check_destination(path)
      if File.directory?(path)
        writable = File.writable?(path)
        add("storage:local", writable ? :ok : :fail,
            writable ? "#{path} (writable)" : "#{path} (not writable)")
      else
        add("storage:local", :warn, "#{path} (does not exist yet; will be created)")
      end
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

    def numeric_version(str)
      return nil if str.nil?

      str[/(\d+)(?:\.\d+)?/, 1]&.to_i
    end

    def add(name, status, detail)
      @checks << Check.new(name: name, status: status, detail: detail)
    end
  end
end
