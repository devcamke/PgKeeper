# frozen_string_literal: true

require "test_helper"
require "json"

module PgKeeper
  class TestLogging < Minitest::Test
    def test_logfmt_includes_level_message_and_fields
      io = StringIO.new
      logger = Logging.build(level: :debug, format: :logfmt, destinations: [io])
      logger.info("dump complete", db: "app", bytes: 42)

      line = io.string

      assert_includes line, "level=info"
      assert_includes line, "msg=\"dump complete\""
      assert_includes line, "db=app"
      assert_includes line, "bytes=42"
    end

    def test_json_format_is_parseable
      io = StringIO.new
      logger = Logging.build(level: :debug, format: :json, destinations: [io])
      logger.warn("slow", duration_s: 1.5)

      payload = JSON.parse(io.string)

      assert_equal "warn", payload["level"]
      assert_equal "slow", payload["msg"]
      assert_in_delta 1.5, payload["duration_s"]
      assert payload["ts"], "timestamp present"
    end

    def test_level_filtering
      io = StringIO.new
      logger = Logging.build(level: :warn, format: :logfmt, destinations: [io])
      logger.debug("noise")
      logger.info("also noise")
      logger.error("signal")

      refute_includes io.string, "noise"
      assert_includes io.string, "signal"
    end

    def test_with_stamps_context_on_every_line
      io = StringIO.new
      logger = Logging.build(level: :debug, format: :logfmt, destinations: [io]).with(run: "r1")
      logger.info("one")
      logger.info("two", db: "x")

      lines = io.string.lines

      assert(lines.all? { |l| l.include?("run=r1") })
      assert_includes lines.last, "db=x"
    end

    def test_unknown_format_raises
      assert_raises(ArgumentError) { Logging.build(format: :xml) }
    end
  end
end
