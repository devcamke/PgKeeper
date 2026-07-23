# frozen_string_literal: true

require "open3"
require "securerandom"

require "pgkeeper/prompt"
require "pgkeeper/config_writer"
require "pgkeeper/schedule"

module PgKeeper
  # The `pgkeeper connect` onboarding wizard: an interactive flow that connects
  # one database and schedules its backups, then writes the result to
  # +pgkeeper.yml+.
  #
  # It walks the user through connection details, live-tests the credentials
  # against the server, collects a backup schedule (validated, with a preview of
  # the next few runs), and persists everything — creating a fresh commented
  # config on a new host, or appending to an existing one without disturbing its
  # comments or `<%= ENV[...] %>` interpolations.
  #
  # The prompt IO and the connection prober are both injected, so the whole
  # conversation runs deterministically in tests with StringIO and a stub
  # prober — no terminal and no live Postgres required.
  class Wizard
    # A probe of database reachability: +ok?+ plus a human +detail+ line.
    Probe = Struct.new(:ok, :detail, keyword_init: true) do
      def ok? = ok
    end

    # What the wizard did, returned from {#run} for the CLI to report on.
    Result = Struct.new(:config_path, :created, :database, :schedule, :password_env,
                        :web_token_env, :web_token, keyword_init: true)

    # Env var the generated `web:` block reads its dashboard token from.
    WEB_TOKEN_ENV = "PGKEEPER_WEB_TOKEN"

    def initialize(config_path:, prompt: Prompt.new, logger: PgKeeper.logger, prober: nil)
      @config_path = config_path
      @prompt = prompt
      @logger = logger
      @prober = prober || method(:default_probe)
    end

    # Run the wizard. Returns a {Result}, or nil if the user backed out before
    # anything was written.
    def run
      intro
      existing = load_existing
      db = collect_database(existing)
      test_connection(db)
      schedule = collect_schedule
      web = collect_web(existing)
      persist(existing, db, schedule, web)
    end

    private

    def intro
      @prompt.heading("PgKeeper — connect a database")
      target = File.exist?(@config_path) ? "updating #{@config_path}" : "creating #{@config_path}"
      @prompt.say("This wizard adds a database and a backup schedule (#{target}).")
    end

    # Load the existing config file (rendered) so we can prepopulate defaults and
    # reject duplicate names. A file that exists but fails to load is surfaced as
    # a hard error rather than silently overwritten.
    def load_existing
      return nil unless File.exist?(@config_path)

      Config.load(@config_path)
    rescue ConfigError => e
      raise ConfigError.new(
        "existing config #{@config_path} is invalid — fix it before adding a database (#{e.message})",
        problems: e.problems
      )
    end

    # -- step 1: connection details ----------------------------------------

    def collect_database(existing)
      @prompt.heading("Connection")
      defaults = existing_defaults(existing)
      name = ask_database_name(existing)

      {
        "name" => name,
        "host" => @prompt.ask("Host", default: defaults["host"] || "localhost"),
        "port" => ask_port(defaults["port"] || 5432),
        "database" => @prompt.ask("Database name", default: name),
        "username" => @prompt.ask("Username", default: defaults["username"] || "postgres"),
        "password" => @prompt.ask_secret("Password (leave blank to use .pgpass / ambient credentials)")
      }
    end

    def existing_defaults(existing)
      raw = existing&.raw&.fetch("defaults", nil)
      raw.is_a?(Hash) ? raw : {}
    end

    def ask_database_name(existing)
      names = existing ? existing.databases.map(&:name) : []
      loop do
        name = @prompt.ask("Name for this database (used in backups and history)", required: true)
        return name unless names.include?(name)

        @prompt.say(%(  a database named "#{name}" already exists in #{@config_path} — pick another))
      end
    end

    def ask_port(default)
      loop do
        raw = @prompt.ask("Port", default: default.to_s)
        port = Integer(raw, exception: false)
        return port if port&.between?(1, 65_535)

        @prompt.say("  port must be an integer between 1 and 65535")
      end
    end

    # -- step 2: connection test -------------------------------------------

    def test_connection(db)
      loop do
        @prompt.say("Testing connection to #{db['username']}@#{db['host']}:#{db['port']}/#{db['database']} …")
        probe = run_probe(db)
        if probe.ok?
          @prompt.say("  ✓ connected — #{probe.detail}")
          return
        end

        @prompt.say("  ✗ connection failed — #{probe.detail}")
        break unless retry_or_continue?
      end
    end

    # On a failed probe, let the user re-enter nothing (just retry with the same
    # details, e.g. after starting the server), save the config anyway, or abort.
    def retry_or_continue?
      return true if @prompt.yes?("Retry the connection test?", default: true)

      unless @prompt.yes?("Save this database to the config anyway?", default: false)
        raise Prompt::Aborted, "aborted before writing any config"
      end

      false
    end

    def run_probe(db)
      @prober.call(DatabaseConfig.new(db).libpq_env)
    end

    # Default prober: a bounded `psql` round-trip, mirroring `pgkeeper doctor`.
    def default_probe(env)
      out, status = Open3.capture2e(env, "psql", "-XtAc", "SELECT version()")
      if status.success?
        Probe.new(ok: true, detail: out.strip.split(" on ").first.to_s)
      else
        Probe.new(ok: false, detail: out.strip.lines.last&.strip || "unknown error")
      end
    rescue Errno::ENOENT
      Probe.new(ok: false, detail: "psql not found on PATH")
    end

    # -- step 3: schedule ---------------------------------------------------

    def collect_schedule
      @prompt.heading("Schedule")
      @prompt.say('Cron ("15 3 * * *"), natural language ("every day at 03:15"), or a word ("hourly", "daily").')
      loop do
        expr = @prompt.ask("Backup schedule", default: "daily at 03:15")
        schedule = parse_schedule(expr)
        next unless schedule

        preview_schedule(schedule)
        return expr if @prompt.yes?("Use this schedule?", default: true)
      end
    end

    def parse_schedule(expr)
      Schedule.parse(expr)
    rescue ConfigError => e
      @prompt.say("  ✗ #{e.message}")
      nil
    end

    # -- step 3b: web dashboard --------------------------------------------

    # Offer to set up the `pgkeeper web` dashboard. Returns the web settings, or
    # nil to leave it unconfigured. Skipped silently when the existing config
    # already has a `web:` block — there is nothing to add, and we must never
    # clobber a hand-tuned one.
    def collect_web(existing)
      return nil if existing&.raw&.key?("web")

      @prompt.heading("Web dashboard")
      @prompt.say("`pgkeeper web` serves a monitoring dashboard and can trigger backups.")
      @prompt.say("Auth is required; the token is read from the environment, never inlined.")
      return nil unless @prompt.yes?("Enable the web dashboard?", default: true)

      { "bind" => "127.0.0.1", "port" => ask_port(8321), "token_env" => WEB_TOKEN_ENV }
    end

    def preview_schedule(schedule)
      @prompt.say("  normalized cron: #{schedule.to_cron}")
      from = Time.now
      3.times do
        from = schedule.next_time(from: from)
        @prompt.say("    next run: #{from.strftime('%a %Y-%m-%d %H:%M %Z')}")
        from += 1
      end
    end

    # -- step 4: persist ----------------------------------------------------

    def persist(existing, db, schedule, web)
      entry = build_entry(db)
      # Preview reflects what actually lands: on an existing config the schedule
      # rides on the database entry; on a fresh config it becomes global.
      preview = existing ? entry.merge("schedule" => schedule) : entry
      snippet = ConfigWriter.render_database(preview)
      @prompt.heading("Review")
      @prompt.say(snippet)
      @prompt.say("  + web dashboard on #{web['bind']}:#{web['port']}") if web

      target = existing ? "append this database to #{@config_path}" : "create #{@config_path}"
      unless @prompt.yes?("Write config (#{target})?", default: true)
        @prompt.say("Nothing written. You can paste the block above into your config's `databases:` list.")
        return nil
      end

      write_config(existing, entry, schedule, web)
      result = Result.new(
        config_path: @config_path,
        created: existing.nil?,
        database: entry["name"],
        schedule: schedule,
        password_env: entry["password_env"],
        web_token_env: web && web["token_env"],
        web_token: web && SecureRandom.hex(24)
      )
      guidance(result)
      result
    end

    # Order the keys for a stable, readable YAML entry. The schedule is added by
    # {#write_config} — globally for a fresh config, or on the entry itself when
    # appending, so the other databases keep their own cadence.
    def build_entry(db)
      entry = {
        "name" => db["name"],
        "host" => db["host"],
        "port" => db["port"],
        "database" => db["database"],
        "username" => db["username"]
      }
      entry["password_env"] = ConfigWriter.password_env(db["name"]) unless db["password"].to_s.empty?
      entry["format"] = "custom"
      entry
    end

    def write_config(existing, entry, schedule, web)
      if existing
        entry_with_schedule = entry.merge("schedule" => schedule)
        text = File.read(@config_path, encoding: "UTF-8")
        updated = append_or_snippet(text, entry_with_schedule)
        # `web` is non-nil here only when the existing config had no `web:` block
        # (collect_web checks), so appending one can't duplicate an existing key.
        updated = ConfigWriter.append_web(updated, web) if web
        ConfigWriter.write(@config_path, updated)
      else
        ConfigWriter.write(@config_path, fresh_config(entry, schedule, web))
      end
      @logger.info("wizard wrote config", path: @config_path, database: entry["name"])
    end

    def append_or_snippet(text, entry_with_schedule)
      ConfigWriter.append_database(text, ConfigWriter.render_database(entry_with_schedule))
    rescue ConfigError
      # No recognizable `databases:` block to splice into — fall back to
      # appending a fresh list at the end rather than corrupting the file.
      "#{text.chomp}\n\ndatabases:\n#{ConfigWriter.render_database(entry_with_schedule)}"
    end

    def fresh_config(entry, schedule, web)
      workdir = Config::DEFAULT_WORKDIR
      ConfigWriter.render_config(
        workdir: workdir,
        schedule: schedule,
        database: entry,
        backup_path: File.join(workdir, "backups"),
        web: web
      )
    end

    def guidance(result)
      @prompt.say("✓ #{result.created ? 'Created' : 'Updated'} #{result.config_path}")
      if result.password_env
        @prompt.heading("Set the database password (kept out of the config file)")
        @prompt.say(%(  export #{result.password_env}='…'))
      end
      if result.web_token_env
        @prompt.heading("Set the dashboard token (kept out of the config file)")
        @prompt.say(%(  export #{result.web_token_env}='#{result.web_token}'))
        @prompt.say("  Then start it:  pgkeeper web")
      end
      @prompt.heading("Next steps")
      @prompt.say("  1. Verify:   pgkeeper validate  &&  pgkeeper doctor")
      @prompt.say("  2. Back up:  pgkeeper backup")
      @prompt.say("  3. Schedule: pgkeeper schedule install    # render cron lines")
      @prompt.say("               pgkeeper schedule install --systemd --output /etc/systemd/system")
      @prompt.say("               pgkeeper daemon               # or run in-process (containers)")
      recommend_deep_verify
    end

    # A backup you have never restored is not a backup. Steer new users toward a
    # weekly deep verify from the start — it turns "we have backups" into "we have
    # backups that provably restore", the guarantee that matters on recovery day.
    def recommend_deep_verify
      @prompt.heading("Recommended: prove your backups restore (weekly)")
      @prompt.say("  Add a weekly deep verify — it restores into a throwaway DB and checks it:")
      @prompt.say("    30 4 * * 0 pgkeeper verify --deep --config #{@config_path}")
      @prompt.say("  See docs/RPO-RTO.md for setting a recovery SLA you can keep.")
    end
  end
end
