# frozen_string_literal: true

require "logger"
require "json"
require "time"

module PgKeeper
  # Structured logging with a choice of human-readable +logfmt+ or machine
  # +json+ output. A logger writes to stdout and, optionally, a file.
  #
  #   logger = PgKeeper::Logging.build(level: :debug, format: :json)
  #   logger.info("dump complete", db: "app", bytes: 12_345)
  #
  # Structured fields are passed as keyword-ish hashes and merged into the line.
  module Logging
    FORMATS = %i[logfmt json].freeze
    LEVELS = %i[debug info warn error fatal].freeze

    module_function

    # Build a {StructuredLogger}. +destinations+ may include +$stdout+ and/or a
    # file path.
    def build(level: :info, format: :logfmt, destinations: [$stdout])
      format = format.to_sym
      raise ArgumentError, "unknown log format: #{format}" unless FORMATS.include?(format)

      targets = Array(destinations).map { |d| d.is_a?(String) ? open_file(d) : d }
      logger = Logger.new(MultiIO.new(targets))
      logger.level = resolve_level(level)
      logger.formatter = formatter_for(format)
      StructuredLogger.new(logger)
    end

    def resolve_level(level)
      case level
      when Integer then level
      when String, Symbol then Logger.const_get(level.to_s.upcase)
      else Logger::INFO
      end
    end

    def formatter_for(format)
      format == :json ? json_formatter : logfmt_formatter
    end

    def json_formatter
      proc do |severity, time, _progname, msg|
        message, fields = split_message(msg)
        payload = { ts: time.utc.iso8601(3), level: severity.downcase, msg: message }.merge(fields)
        "#{JSON.generate(payload)}\n"
      end
    end

    def logfmt_formatter
      proc do |severity, time, _progname, msg|
        message, fields = split_message(msg)
        pairs = { ts: time.utc.iso8601(3), level: severity.downcase, msg: message }.merge(fields)
        "#{pairs.map { |k, v| "#{k}=#{quote(v)}" }.join(' ')}\n"
      end
    end

    # A logged message may be a plain string, or a [string, fields_hash] pair
    # emitted by our {StructuredLogger} wrapper below.
    def split_message(msg)
      if msg.is_a?(Array) && msg.length == 2 && msg[1].is_a?(Hash)
        [msg[0].to_s, msg[1]]
      else
        [msg.to_s, {}]
      end
    end

    def quote(value)
      str = value.to_s
      return str unless str.match?(/[\s="]/)

      %("#{str.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
    end

    def open_file(path)
      dir = File.dirname(path)
      require "fileutils"
      FileUtils.mkdir_p(dir)
      # A log file lives for the whole process; the Logger owns and closes it, so
      # the block form doesn't apply here.
      file = File.open(path, "a") # rubocop:disable Style/FileOpen
      file.sync = true
      file
    end

    # Thin wrapper that lets callers attach structured fields to a log line:
    #
    #   logger.info("dump complete", db: "app", bytes: 12_345)
    #
    # The [message, fields] pair is handed to the underlying {Logger}, where the
    # formatter merges the fields into the emitted line. Fields carried by
    # {#with} are merged into every subsequent call, so a run can tag every line
    # with its run id without repeating it.
    class StructuredLogger
      attr_reader :base, :context

      def initialize(base, context: {})
        @base = base
        @context = context
      end

      LEVELS.each do |lvl|
        define_method(lvl) do |message, **fields|
          @base.public_send(lvl) { [message, @context.merge(fields)] }
          nil
        end
      end

      # Return a child logger that stamps +fields+ onto every line.
      def with(**fields)
        StructuredLogger.new(@base, context: @context.merge(fields))
      end

      def level = @base.level

      def level=(value)
        @base.level = Logging.resolve_level(value)
      end

      def close = @base.close
    end

    # Fan a single write out to several IO targets (stdout + file).
    class MultiIO
      def initialize(targets)
        @targets = targets
      end

      def write(*args)
        @targets.sum { |t| t.write(*args) }
      end

      def close
        @targets.each { |t| t.close unless [$stdout, $stderr].include?(t) }
      end
    end
  end
end
