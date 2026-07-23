# frozen_string_literal: true

require "thor"
require "time"

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

    desc "backup", "Dump configured databases and fan out to storage destinations (alias: run)"
    method_option :only, type: :array, desc: "Only back up these database name(s)"
    method_option :destinations, type: :array,
                                 desc: "Only ship to these destination(s), by name or type (default: all)"
    def backup
      config = load_config
      report = Orchestrator.new(config, logger: logger)
                           .run(only: options[:only], destinations: options[:destinations])
      print_report(report)
      exit(report.exit_code)
    rescue Error => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end
    map "run" => :backup

    desc "basebackup", "Take a physical base backup of a PITR cluster (Phase 12; see clusters:)"
    method_option :cluster, type: :string, desc: "Only back up this cluster (default: all PITR clusters)"
    method_option :destinations, type: :array,
                                 desc: "Only ship to these destination(s), by name or type (default: all)"
    def basebackup
      config = load_config
      only = options[:cluster] ? [options[:cluster]] : nil
      report = PITR::BaseBackup.new(config, logger: logger)
                               .run(only: only, destinations: options[:destinations])
      print_report(report)
      exit(report.exit_code)
    rescue Error => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    desc "wal ACTION [ARGS]", "PITR WAL archiving: archive-file PATH [NAME] | archive --spool DIR | fetch NAME DEST"
    method_option :cluster, type: :string, desc: "PITR cluster (default: the only one, if unambiguous)"
    method_option :spool, type: :string, desc: "Spool directory (for `wal archive`)"
    def wal(action, *args)
      config = load_config
      archiver = PITR::WalArchiver.new(config, resolve_pitr_cluster(config, options[:cluster]), logger: logger)
      case action
      when "archive-file" then wal_archive_file(archiver, args)
      when "archive" then wal_archive_spool(archiver)
      when "fetch" then wal_fetch(archiver, args)
      else
        say_error "unknown wal action #{action.inspect} (expected: archive-file, archive, fetch)", :red
        exit(ExitCode::FAILURE)
      end
    rescue Error => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    desc "destinations", "List configured storage destinations and the tokens that select them"
    def destinations
      config = load_config
      say "Destinations (use with `backup --destinations TOKEN`):", :cyan
      config.destinations.each do |dest|
        token = dest.token
        say format("  %<token>-16s %<label>s", token: token, label: dest.label)
      end
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
    method_option :pitr, type: :boolean, default: false,
                         desc: "Verify PITR recovery chains (base + unbroken archived WAL)"
    method_option :cluster, type: :string, desc: "With --pitr: only this cluster (default: all)"
    def verify(selector = "latest")
      config = load_config
      return verify_pitr(config) if options[:pitr]

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
    method_option :force, type: :boolean, default: false, desc: "Overwrite a non-empty target/data dir"
    method_option :jobs, type: :numeric, desc: "Parallel jobs for directory-format restores"
    # PITR (Phase 12): recover a whole cluster to a point in time from a base
    # backup + archived WAL. Any of these switches into PITR mode.
    method_option :cluster, type: :string, desc: "PITR: cluster to recover"
    method_option :data_dir, type: :string, desc: "PITR: target data directory to stage recovery into"
    method_option :to_time, type: :string, desc: "PITR target: recover to this timestamp"
    method_option :to_lsn, type: :string, desc: "PITR target: recover to this LSN"
    method_option :to_name, type: :string, desc: "PITR target: recover to this named restore point"
    method_option :to, type: :string, desc: "PITR target: `latest` (replay all archived WAL)"
    method_option :action, type: :string, default: "promote", desc: "PITR: recovery_target_action (promote|pause)"
    method_option :restore_bin, type: :string, default: "pgkeeper",
                                desc: "PITR: pgkeeper path baked into the recovery restore_command"
    def restore(selector = "latest")
      config = load_config
      pitr_target?(options) ? run_pitr_restore(config) : run_restore(config, selector)
    rescue Error, EnvironmentError => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    desc "status", "Show the most recent backup per database from run history"
    method_option :database, type: :string, desc: "Show recent runs for one database"
    method_option :limit, type: :numeric, default: 10, desc: "Rows to show with --database"
    def status
      config = load_config
      history = History.new(File.join(config.workdir, "history.sqlite3"), logger: logger)
      rows = if options[:database]
               history.recent(limit: options[:limit],
                              database: options[:database])
             else
               history.last_per_database
             end
      print_status(rows)
    end

    desc "metrics", "Print Prometheus metrics (last run/success time, size, duration) for scraping"
    method_option :output, type: :string,
                           desc: "Write to this file atomically (for the node_exporter textfile collector)"
    def metrics
      config = load_config
      text = Metrics.render(config, logger: logger)
      if options[:output]
        Metrics.write_textfile(text, options[:output])
        say "Wrote metrics to #{options[:output]}", :green
      else
        print text
      end
    end

    desc "test-notification", "Send a test notification through every configured notifier"
    def test_notification
      config = load_config
      notifier = Notify.build(config, logger: logger)
      unless notifier.any?
        say "No notifiers configured (see `notifications:` in your config).", :yellow
        return
      end
      results = notifier.dispatch(test_summary)
      say "Dispatched to #{notifier.backends.length} notifier(s); #{results.count(true)} succeeded.",
          results.all? ? :green : :yellow
    end

    desc "schedule [ACTION]", "Show (print) or install (install) the schedule from config"
    method_option :systemd, type: :boolean, default: false, desc: "Emit systemd .service/.timer units"
    method_option :output, type: :string, desc: "Write systemd units to this directory instead of stdout"
    method_option :jitter, type: :numeric, default: 0, desc: "systemd RandomizedDelaySec (stagger)"
    method_option :bin, type: :string, default: "pgkeeper", desc: "pgkeeper executable path in generated units"
    def schedule(action = "print")
      config = load_config
      case action
      when "print" then print_schedule(config)
      when "install" then run_schedule_install(config, options)
      else
        say_error "unknown schedule action #{action.inspect} (expected: print, install)", :red
        exit(ExitCode::FAILURE)
      end
    end

    desc "connect", "Onboarding wizard: connect a database and schedule its backups, writing pgkeeper.yml"
    def connect
      path = resolve_config_path_for_write
      Wizard.new(config_path: path, prompt: Prompt.new, logger: logger).run
    rescue Prompt::Aborted => e
      say_error e.message, :yellow
      exit(ExitCode::FAILURE)
    rescue Error => e
      say_error e.message, :red
      e.problems.each { |p| say_error "  - #{p}", :red } if e.respond_to?(:problems)
      exit(ExitCode::FAILURE)
    end
    map "onboard" => :connect

    desc "web", "Serve the monitoring dashboard (auth required; binds to 127.0.0.1 by default)"
    method_option :bind, type: :string, desc: "Address to bind (default: web.bind or 127.0.0.1)"
    method_option :port, type: :numeric, desc: "Port to listen on (default: web.port or 8321)"
    def web
      config = load_config
      require "pgkeeper/web"
      Web.serve(config, logger: logger, bind: options[:bind], port: options[:port])
    rescue Error, EnvironmentError => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    desc "daemon", "Run scheduled backups in-process (for containers without cron/systemd)"
    method_option :jitter, type: :numeric, default: 0, desc: "Max seconds of random stagger before each run"
    def daemon
      config = load_config
      Daemon.new(config, logger: logger, jitter: options[:jitter]).run
    rescue Error => e
      say_error e.message, :red
      exit(ExitCode::FAILURE)
    end

    no_commands do
      def print_schedule(config)
        entries = Scheduler.entries(config)
        return say("No schedule configured (set `schedule:` in your config).", :yellow) if entries.empty?

        entries.each do |e|
          scope = e.only ? " (--only #{e.only.join(',')})" : " (all databases)"
          flags = e.flags.empty? ? "" : " #{e.flags.join(' ')}"
          say "#{e.action} #{e.label}: #{e.schedule.summary}#{flags}#{scope}"
        end
      end

      def run_schedule_install(config, opts)
        entries = Scheduler.entries(config)
        return say("No schedule configured (set `schedule:` in your config).", :yellow) if entries.empty?

        opts[:systemd] ? install_systemd(config, entries, opts) : install_cron(config, entries, opts)
      end

      def install_cron(config, entries, opts)
        cron = Scheduler::Cron.new(entries, bin: opts[:bin], config_path: config.source, workdir: config.workdir)
        say cron.render
      end

      def install_systemd(config, entries, opts)
        units = Scheduler::Systemd.new(entries, bin: opts[:bin], config_path: config.source,
                                                jitter_seconds: opts[:jitter].to_i).units
        return write_units(units, opts[:output]) if opts[:output]

        units.each { |name, body| say "# ===== #{name} =====\n#{body}" }
      end

      def write_units(units, dir)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        units.each { |name, body| File.write(File.join(dir, name), body) }
        say "Wrote #{units.length} unit file(s) to #{dir}", :green
        say "Enable with: systemctl daemon-reload && systemctl enable --now #{units.keys.grep(/\.timer$/).join(' ')}"
      end

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

      # Where the wizard writes. An explicit --config wins; otherwise reuse the
      # first existing default (append mode) or fall back to ./pgkeeper.yml
      # (create mode) so a brand-new host has a sensible target.
      def resolve_config_path_for_write
        return options[:config] if options[:config]

        DEFAULT_CONFIG_PATHS.find { |p| File.file?(p) } || DEFAULT_CONFIG_PATHS.first
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

      # Resolve the PITR cluster to act on: the named one, or the sole PITR
      # cluster when there's exactly one and none was named.
      def resolve_pitr_cluster(config, name)
        clusters = config.pitr_clusters
        if clusters.empty?
          raise Error,
                "no PITR clusters configured (add a `clusters:` entry with `pitr.enabled: true`)"
        end

        if name
          cluster = config.cluster(name)
          raise Error, "unknown or non-PITR cluster: #{name}" unless cluster&.pitr?

          cluster
        elsif clusters.length == 1
          clusters.first
        else
          raise Error, "multiple PITR clusters configured; pass --cluster NAME"
        end
      end

      def wal_archive_file(archiver, args)
        path = args[0] or raise Error, "usage: pgkeeper wal archive-file PATH [NAME]"
        name = args[1] || File.basename(path)
        return say("archived #{name}", :green) if archiver.archive_file(path, name)

        say_error "#{name}: not stored on every destination", :red
        exit(ExitCode::PARTIAL)
      end

      def wal_archive_spool(archiver)
        raise Error, "usage: pgkeeper wal archive --spool DIR" unless options[:spool]

        count = archiver.archive_spool(options[:spool])
        say "archived #{count} segment(s) from #{options[:spool]}", :green
      end

      def wal_fetch(archiver, args)
        name, dest = args
        raise Error, "usage: pgkeeper wal fetch NAME DEST" unless name && dest

        archiver.fetch(name, dest)
        say "fetched #{name} → #{dest}", :green
      end

      def pitr_target?(opts)
        opts[:to_time] || opts[:to_lsn] || opts[:to_name] || opts[:to]
      end

      def run_pitr_restore(config)
        cluster = resolve_pitr_cluster(config, options[:cluster])
        raise Error, "PITR restore needs a target directory: --data-dir DIR" unless options[:data_dir]

        result = PITR::Restore.new(config, cluster, logger: logger)
                              .run(target: pitr_target(options), data_dir: options[:data_dir],
                                   force: options[:force], action: options[:action], bin: options[:restore_bin])
        print_pitr_restore(result)
      end

      def pitr_target(opts)
        if opts[:to_time] then PITR::Restore::Target.new(type: :time, value: Time.parse(opts[:to_time]).utc)
        elsif opts[:to_lsn] then PITR::Restore::Target.new(type: :lsn, value: opts[:to_lsn])
        elsif opts[:to_name] then PITR::Restore::Target.new(type: :name, value: opts[:to_name])
        elsif opts[:to] == "latest" then PITR::Restore::Target.new(type: :latest, value: nil)
        else raise Error, "unknown PITR target (use --to latest, or --to-time / --to-lsn / --to-name)"
        end
      end

      def verify_pitr(config)
        clusters = config.pitr_clusters
        if clusters.empty?
          raise Error,
                "no PITR clusters configured (add a `clusters:` entry with `pitr.enabled: true`)"
        end

        clusters = clusters.select { |c| c.name == options[:cluster] } if options[:cluster]
        raise Error, "unknown or non-PITR cluster: #{options[:cluster]}" if clusters.empty?

        results = clusters.map { |cluster| PITR::Verify.new(config, cluster, logger: logger).verify }
        results.each { |result| print_pitr_verify(result) }
        exit(results.all?(&:ok?) ? ExitCode::SUCCESS : ExitCode::FAILURE)
      end

      def print_pitr_verify(result)
        if result.ok?
          say "✓ #{result.cluster}: #{result.detail}", :green
          say "    base #{result.base_label}, WAL #{result.from_segment}..#{result.to_segment}" if result.from_segment
        else
          say "✗ #{result.cluster}: #{result.detail}", :red
        end
      end

      def print_pitr_restore(result)
        say "✓ Staged recovery of cluster #{result.cluster} into #{result.data_dir}", :green
        say "  base:   #{result.base_label}"
        say "  target: #{result.target.describe}"
        say ""
        say "Start recovery — Postgres replays WAL to the target, then #{options[:action]}s:", :cyan
        say "  pg_ctl -D #{result.data_dir} start"
        say "The restore_command runs `pgkeeper wal fetch`, so its config + secrets must be reachable."
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
        result.warnings.each { |w| say "    ⚠ #{w}", :yellow }
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

      def print_status(rows)
        if rows.empty?
          say "No run history yet. Run `pgkeeper backup` first.", :yellow
          return
        end
        rows.each do |row|
          glyph, color = status_marker(row.status)
          say format("%<g>s %<db>-20s %<status>-9s %<age>-14s %<size>9s  %<when>s",
                     g: glyph, db: row.database, status: row.status,
                     age: "#{human_age(row.started_at)} ago", size: human_size(row.total_bytes),
                     when: row.started_at), color
        end
      end

      def status_marker(status)
        { "success" => ["✓", :green], "partial" => ["!", :yellow], "failure" => ["✗", :red] }
          .fetch(status, ["?", nil])
      end

      def test_summary
        report = Orchestrator::RunReport.new(
          results: [Orchestrator::Result.new(database: "test", status: :success, artifacts: [],
                                             duration_seconds: 0.0)]
        )
        now = Time.now.utc
        Notify::Summary.new(report: report, run_id: "test-notification",
                            started_at: now, finished_at: now, hostname: Manifest.safe_hostname)
      end

      def human_age(iso)
        seconds = (Time.now - Time.iso8601(iso)).to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      rescue ArgumentError, TypeError
        "?"
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
