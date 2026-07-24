# frozen_string_literal: true

module PgKeeper
  module Web
    # The "set a schedule from the web" flow: validate the submitted
    # expression, then set — or, with a blank expression, clear — the
    # `schedule:` key in +pgkeeper.yml+, either on one database entry or the
    # global default, via {ConfigWriter}'s targeted text surgery. Comments and
    # ERB interpolations in the file survive untouched.
    #
    # The posture mirrors {DatabaseAdmin}'s:
    #
    #   * The expression must parse ({Schedule} — cron, natural language, or a
    #     shorthand) before the file is touched, and the updated text is
    #     re-validated as a full config before it is written; a bad expression
    #     or a bad merge is rejected, never saved.
    #   * Browser-only (CSRF + confirm gate), deliberately not exposed on the
    #     Bearer-token JSON API: a leaked API token can trigger jobs, not
    #     rewire when they run.
    #   * The running process reads config at boot, so every success message
    #     ends with a restart reminder — the flow writes the file, it does not
    #     hot-load.
    class ScheduleAdmin
      Result = Struct.new(:ok, :message, keyword_init: true)

      def initialize(config, logger: PgKeeper.logger)
        @config = config
        @logger = logger
      end

      # Whether the config can be edited at all: it must have come from a
      # real, writable file (not a string, not a read-only mount).
      def editable?
        source = @config.source.to_s
        File.file?(source) && File.writable?(source)
      end

      # Set the schedule for +params["database"]+ (empty = the global
      # default) to +params["expression"]+ (blank = remove it). Returns a
      # {Result}; nothing is written unless the expression parses and the
      # updated file re-validates.
      def set(params)
        name = params["database"].to_s.strip
        expression = presence(params["expression"])
        db = name.empty? ? nil : @config.database(name)
        return failure("no database named #{name.inspect} in the config") if !name.empty? && db.nil?
        return failure("the config (#{@config.source}) is not an editable file") unless editable?

        if expression.nil?
          current = name.empty? ? @config.schedule : db.schedule
          return failure(nothing_to_remove(name)) if current.nil?
        end

        schedule = expression && parse(expression)
        return schedule if schedule.is_a?(Result)

        write(name, expression, schedule)
      end

      private

      def parse(expression)
        Schedule.parse(expression)
      rescue ConfigError => e
        failure(e.message)
      end

      def write(name, expression, schedule)
        text = File.read(@config.source, encoding: "UTF-8")
        updated = if name.empty?
                    ConfigWriter.set_global_schedule(text, expression)
                  else
                    ConfigWriter.set_database_schedule(text, name, expression)
                  end
        revalidate!(updated)
        ConfigWriter.write(@config.source, updated)
        @logger.info("dashboard set schedule", scope: name.empty? ? "(global)" : name,
                                               schedule: expression || "(removed)")
        Result.new(ok: true, message: success_message(name, expression, schedule))
      rescue ConfigError => e
        failure(e.message)
      end

      # Parse + validate the updated text exactly as `Config.load` will at
      # next boot (ERB included), so a bad merge is caught before it hits
      # disk. {Config#initialize} raises ConfigError when validation fails.
      def revalidate!(updated)
        Config.new(Config.render(updated, @config.source), source: @config.source)
      end

      def success_message(name, expression, schedule)
        scope = name.empty? ? "the global schedule" : "#{name}'s schedule"
        change =
          if expression
            "set #{scope} to #{expression.inspect} (cron: #{schedule.to_cron}, " \
              "next: #{schedule.next_time.utc.strftime('%Y-%m-%d %H:%MZ')})"
          elsif name.empty?
            "removed the global schedule"
          else
            "removed #{name}'s schedule override — it follows the global schedule now"
          end
        "#{change}; restart pgkeeper (or the daemon) to apply"
      end

      def nothing_to_remove(name)
        if name.empty?
          "no global schedule is set — nothing to remove"
        else
          "#{name} has no schedule override — nothing to remove"
        end
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
