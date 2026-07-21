# frozen_string_literal: true

require "thor"

module PgKeeper
  # The +pgkeeper+ command line interface.
  #
  # Global options (config path, log level/format/file) apply to every command.
  # Commands return meaningful process exit codes: +0+ success, +1+ partial
  # failure, +2+ total failure — so cron and CI can react to them.
  class CLI < Thor
    DEFAULT_CONFIG_PATHS = ["pgkeeper.yml", "config/pgkeeper.yml", "/etc/pgkeeper/pgkeeper.yml"].freeze

    class_option :config, type: :string, aliases: "-c", desc: "Path to pgkeeper.yml"
    class_option :log_level, type: :string, default: "info", desc: "debug|info|warn|error"
    class_option :log_format, type: :string, default: "logfmt", desc: "logfmt|json"
    class_option :log_file, type: :string, desc: "Also write logs to this file"

    def self.exit_on_failure? = true

    desc "version", "Print the PgKeeper version"
    def version
      say PgKeeper::VERSION
    end
    map %w[--version -v] => :version

    desc "doctor", "Check the environment: tools, config, connectivity, versions"
    def doctor
      checks = Doctor.new(config_path: resolve_config_path(required: false), logger: logger).run
      print_checks(checks)
      exit(Doctor.healthy?(checks) ? ExitCode::SUCCESS : ExitCode::FAILURE)
    end

    desc "validate", "Load and validate the config file, reporting any problems"
    def validate
      config = load_config
      say "OK: #{config.source} is valid (#{config.databases.length} database(s), " \
          "#{config.storage.length} storage target(s))", :green
    end

    desc "backup", "Dump configured databases to local storage with manifests"
    method_option :only, type: :array, desc: "Only back up these database name(s)"
    def backup
      config = load_config
      report = Orchestrator.new(config, logger: logger).run(only: options[:only])
      print_report(report)
      exit(report.exit_code)
    end

    desc "list", "List backups across every configured destination"
    method_option :only, type: :array, desc: "Only list these database name(s)"
    def list
      config = load_config
      each_adapter(config) do |adapter|
        say adapter.name, :cyan
        sets = Catalog.new(adapter).backup_sets
        sets = sets.select { |s| options[:only].include?(s.database) } if options[:only]
        if sets.empty?
          say "  (no backups)", :yellow
        else
          sets.sort_by(&:timestamp).reverse_each { |set| say "  #{backup_set_row(set)}".rstrip }
        end
      end
    end

    desc "prune", "Delete backups that fall outside the retention policy"
    method_option :apply, type: :boolean, default: false,
                          desc: "Actually delete backups (default is a dry run)"
    method_option :only, type: :array, desc: "Only prune these database name(s)"
    def prune
      config = load_config
      report = Pruner.new(config, logger: logger).prune(apply: options[:apply], only: options[:only])
      print_prune(report)
    end

    desc "verify [SELECTOR]", "Verify backups: checksum + structural, or full restore with --deep"
    method_option :deep, type: :boolean, default: false,
                         desc: "Tier 3: restore into a scratch database and sanity-check it"
    method_option :only, type: :array, desc: "Only verify these database name(s)"
    def verify(selector = "latest")
      config = load_config
      results = Verifier.new(config, logger: logger).verify(selector: selector, deep: options[:deep],
                                                            only: options[:only])
      print_verify(results)
      exit(results.all?(&:ok?) ? ExitCode::SUCCESS : ExitCode::FAILURE)
    rescue Error => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    desc "restore [SELECTOR]", "Restore a backup into a database (destructive; guarded by --force)"
    method_option :database, type: :string, desc: "Which backed-up database to restore"
    method_option :target, type: :string, desc: "Target database name (default: same as source)"
    method_option :force, type: :boolean, default: false, desc: "Overwrite a non-empty target database"
    method_option :jobs, type: :numeric, desc: "Parallel jobs for directory-format restores"
    def restore(selector = "latest")
      config = load_config
      run_restore(config, selector)
    rescue Error, EnvironmentError => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    no_commands do
      def logger
        @logger ||= begin
          destinations = [$stdout]
          destinations << options[:log_file] if options[:log_file]
          log = Logging.build(
            level: options[:log_level],
            format: options[:log_format],
            destinations: destinations
          )
          PgKeeper.logger = log
          log
        end
      end

      def load_config
        Config.load(resolve_config_path(required: true))
      rescue ConfigError => e
        say_error e.message, :red
        e.problems.each { |p| say_error "  - #{p}", :red }
        exit(ExitCode::FAILURE)
      end

      def resolve_config_path(required:)
        explicit = options[:config]
        if explicit
          return explicit if File.file?(explicit)

          say_error "config file not found: #{explicit}", :red
          exit(ExitCode::FAILURE)
        end

        found = DEFAULT_CONFIG_PATHS.find { |p| File.file?(p) }
        return found if found
        return nil unless required

        say_error "no config file found (looked in: #{DEFAULT_CONFIG_PATHS.join(', ')})", :red
        say_error "pass one with --config PATH", :red
        exit(ExitCode::FAILURE)
      end

      def print_checks(checks)
        checks.each do |check|
          say "#{status_glyph(check.status)} #{check.name}: #{check.detail}", status_color(check.status)
        end
        failures = checks.count(&:fail?)
        warns = checks.count(&:warn?)
        say ""
        summary = "#{checks.length} checks, #{failures} failing, #{warns} warning(s)"
        say summary, failures.zero? ? :green : :red
      end

      def print_report(report)
        report.results.each { |result| print_result(result) }
        say ""
        clean = report.failed.empty? && report.partial.empty?
        say "#{report.succeeded.length} succeeded, #{report.partial.length} partial, " \
            "#{report.failed.length} failed", clean ? :green : :red
      end

      def print_result(result)
        if result.failure?
          say "✗ #{result.database}: #{result.error&.message}", :red
          return
        end

        glyph, color = result.success? ? ["✓", :green] : ["!", :yellow]
        say "#{glyph} #{result.database} (#{result.duration_seconds}s)", color
        result.artifacts.each { |a| print_artifact(a) }
      end

      def print_artifact(artifact)
        pipeline = [artifact[:compression], artifact[:encryption]].reject { |x| x == "none" }.join("+")
        pipeline = pipeline.empty? ? "" : " [#{pipeline}]"
        say "    #{artifact[:kind]}: #{human_size(artifact[:size_bytes])}#{pipeline}"
        artifact[:destinations].each do |dest|
          if dest.ok?
            say "      → #{dest.name}", :green
          else
            say "      → #{dest.name}: #{dest.error}", :red
          end
        end
      end

      # Build each configured storage adapter and yield it, skipping (with a
      # warning) any whose optional SDK isn't installed.
      def each_adapter(config)
        config.storage.each do |target|
          begin
            adapter = Storage.build(target, logger: logger)
          rescue EnvironmentError => e
            say "#{target['type']}: #{e.message}", :yellow
            next
          end
          yield adapter
        end
      end

      def backup_set_row(set)
        primary = set.primary
        pipeline = [primary&.compression, primary&.encryption].compact.reject { |x| x == "none" }.join("+")
        verified = set.verified? ? "verified(#{primary.verified_tier})" : "unverified"
        format("%<label>-22s %<db>-18s %<size>9s  %<pipe>-12s %<verified>s",
               label: set.label, db: set.database, size: human_size(set.total_size),
               pipe: pipeline.empty? ? "-" : pipeline, verified: verified)
      end

      def print_prune(report)
        unless report.configured
          say "No retention policy configured; nothing to prune.", :yellow
          return
        end
        if report.deletions.empty?
          say "Nothing to prune — every backup is within the retention policy.", :green
          return
        end

        verb = report.applied ? "Deleted" : "Would delete"
        report.deletions.each do |d|
          say "#{report.applied ? '✓' : '-'} #{d.destination}  #{d.database}  #{d.label}  " \
              "(#{human_size(d.size_bytes)})", report.applied ? :green : nil
        end
        say ""
        say "#{verb} #{report.count} backup set(s), #{human_size(report.total_bytes)} total." \
            "#{'  Re-run with --apply to delete.' unless report.applied}", report.applied ? :green : :yellow
      end

      def print_verify(results)
        results.each do |r|
          if r.ok?
            say "✓ #{r.database} #{r.label}: #{r.tier} OK", :green
          else
            say "✗ #{r.database} #{r.label}: #{r.tier} FAILED — #{r.detail}", :red
          end
        end
        say ""
        failed = results.reject(&:ok?).length
        say "#{results.length} verified, #{failed} failed", failed.zero? ? :green : :red
      end

      def run_restore(config, selector)
        database = restore_database(config)
        connection = config.database(database) or raise(Error, "unknown database: #{database}")
        adapter = primary_adapter(config)
        set = pick_set(Catalog.new(adapter).backup_sets(database: database), selector)
        raise Error, "no backup for #{database} matching #{selector.inspect}" if set.nil?

        target = options[:target] || database
        say "Restoring #{database} @ #{set.label} → database #{target}#{' (force)' if options[:force]}", :yellow
        Restorer.new(config, logger: logger).restore(
          set.primary, adapter, target, connection, force: options[:force], jobs: options[:jobs]
        )
        say "✓ Restore complete: #{target}", :green
      end

      def restore_database(config)
        return options[:database] if options[:database]
        return config.databases.first.name if config.databases.length == 1

        raise Error, "multiple databases configured; pass --database NAME"
      end

      def primary_adapter(config)
        target = config.storage.find { |t| t["type"] == "local" } || config.storage.first
        Storage.build(target, logger: logger)
      end

      def pick_set(sets, selector)
        return sets.max_by(&:timestamp) if %w[latest].include?(selector.to_s) || selector.nil?

        sets.find { |s| s.label == selector || s.label.start_with?(selector.to_s) }
      end

      def status_glyph(status)
        { ok: "✓", warn: "!", fail: "✗" }.fetch(status, "?")
      end

      def status_color(status)
        { ok: :green, warn: :yellow, fail: :red }.fetch(status, :white)
      end

      def human_size(bytes)
        return "?" if bytes.nil?

        units = %w[B KB MB GB TB]
        size = bytes.to_f
        unit = 0
        while size >= 1024 && unit < units.length - 1
          size /= 1024
          unit += 1
        end
        format("%<n>.1f%<u>s", n: size, u: units[unit])
      end

      def say_error(message, color = nil)
        say(message, color)
      end
    end
  end
end
