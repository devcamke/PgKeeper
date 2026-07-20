# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestPgDump < Minitest::Test
    include TestHelpers

    def db(overrides = {})
      config = Config.parse(<<~YAML)
        databases:
          - name: app
            database: appdb
            host: h
            username: u
            password: p
      YAML
      dbc = config.database("app")
      overrides.each { |k, v| dbc.instance_variable_set("@#{k}", v) }
      dbc
    end

    def test_extension_matches_format
      assert_equal "dump", Dump::PgDump.new(db(format: "custom"), logger: null_logger).extension
      assert_equal "sql", Dump::PgDump.new(db(format: "plain"), logger: null_logger).extension
      assert_equal "dir", Dump::PgDump.new(db(format: "directory"), logger: null_logger).extension
    end

    def test_build_args_for_custom_format
      dumper = Dump::PgDump.new(db(format: "custom"), logger: null_logger)
      args = dumper.send(:build_args, "/out/app.dump")

      assert_includes args, "--no-password"
      assert_includes args, "--format=c"
      assert_includes args, "--file=/out/app.dump"
      assert_equal "appdb", args.last, "database name is the final positional arg"
    end

    def test_build_args_directory_format_adds_jobs
      dumper = Dump::PgDump.new(db(format: "directory"), logger: null_logger, jobs: 4)
      args = dumper.send(:build_args, "/out/app.dir")

      assert_includes args, "--format=d"
      assert_includes args, "--jobs=4"
    end

    def test_build_args_includes_schema_and_exclude_filters
      dumper = Dump::PgDump.new(
        db(format: "custom", schemas: ["public"], exclude_tables: %w[logs events]),
        logger: null_logger
      )
      args = dumper.send(:build_args, "/out/app.dump")

      assert_includes args, "--schema=public"
      assert_includes args, "--exclude-table=logs"
      assert_includes args, "--exclude-table=events"
    end

    def test_missing_tool_raises_environment_error
      assert_raises(EnvironmentError) do
        Dump::Runner.run!("pgkeeper-nonexistent-tool", ["--x"], env: {}, logger: null_logger)
      end
    end

    def test_tool_version_nil_for_missing_tool
      assert_nil Dump::Runner.tool_version("pgkeeper-nonexistent-tool")
    end
  end
end
