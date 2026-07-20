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

    desc "list", "List backups present in local storage"
    def list
      config = load_config
      dir = config.local_path
      if dir.nil?
        say "No local storage target configured; `list` currently reads local storage only.", :yellow
        return
      end
      unless File.directory?(dir)
        say "No local storage directory yet: #{dir}", :yellow
        return
      end
      print_backups(dir)
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

      def print_backups(dir)
        manifests = Dir[File.join(dir, "**", "*#{Manifest::SUFFIX}")]
        if manifests.empty?
          say "No backups found in #{dir}", :yellow
          return
        end
        manifests.each { |mpath| say backup_row(mpath).rstrip }
      end

      def backup_row(manifest_path)
        m = Manifest.load(manifest_path)
        artifact = File.join(File.dirname(manifest_path), m.artifact.to_s)
        missing = File.exist?(artifact) ? "" : "  (artifact missing!)"
        pipeline = [m.data["compression"], m.data["encryption"]].compact.reject { |x| x == "none" }.join("+")
        format("%<name>-48s %<size>10s  %<pipe>-10s %<when>s%<missing>s",
               name: m.artifact, size: human_size(m.size_bytes),
               pipe: pipeline.empty? ? "-" : pipeline,
               when: m.data["finished_at"] || m.data["started_at"], missing: missing)
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
