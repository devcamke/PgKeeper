# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestConfigWriter < Minitest::Test
    include TestHelpers

    def entry(name: "app", **overrides)
      {
        "name" => name,
        "host" => "db.internal",
        "port" => 5432,
        "database" => name,
        "username" => "backup",
        "password_env" => ConfigWriter.password_env(name),
        "format" => "custom"
      }.merge(overrides)
    end

    def test_password_env_slugifies_the_name
      assert_equal "PGKEEPER_APP_PRODUCTION_PASSWORD", ConfigWriter.password_env("app-production")
      assert_equal "PGKEEPER_MY_DB_1_PASSWORD", ConfigWriter.password_env("my.db 1")
    end

    def test_render_database_is_a_yaml_list_item
      yaml = ConfigWriter.render_database(entry)

      assert_match(/\A  - name: app\n/, yaml)
      assert_includes yaml, "    port: 5432\n"
    end

    def test_render_database_emits_password_as_env_reference
      yaml = ConfigWriter.render_database(entry(name: "orders"))

      assert_includes yaml, %(password: <%= ENV["PGKEEPER_ORDERS_PASSWORD"] %>)
      refute_includes yaml, "password_env"
    end

    def test_render_database_skips_nil_values
      yaml = ConfigWriter.render_database(entry.merge("host" => nil))

      refute_includes yaml, "host:"
    end

    def test_render_config_round_trips_after_env_substitution
      yaml = ConfigWriter.render_config(
        workdir: "/wd", schedule: "daily at 03:15",
        database: entry, backup_path: "/wd/backups"
      )
      ENV["PGKEEPER_APP_PASSWORD"] = "secret"
      config = Config.parse(yaml.gsub(/<%=.*?%>/) { |m| ERB.new(m).result(binding) })

      assert_equal ["app"], config.databases.map(&:name)
      assert_equal "daily at 03:15", config.schedule
      assert_equal 5432, config.databases.first.port
    ensure
      ENV.delete("PGKEEPER_APP_PASSWORD")
    end

    def test_render_config_local_storage_name_does_not_collide
      yaml = ConfigWriter.render_config(
        workdir: "/wd", schedule: "hourly", database: entry, backup_path: "/wd/backups"
      )
      # A `name: local` would collide with the `local` type keyword and fail
      # validation — the generated single local target must omit it.
      refute_match(/name: local/, yaml)
    end

    def test_append_database_inserts_under_databases_key
      existing = <<~YAML
        workdir: /wd
        databases:
          - name: existing
            host: h
        storage: []
      YAML
      out = ConfigWriter.append_database(existing, ConfigWriter.render_database(entry(name: "added")))

      assert_includes out, "name: added"
      assert_includes out, "name: existing"
      # Everything else is preserved verbatim.
      assert_includes out, "workdir: /wd"
      assert_includes out, "storage: []"
    end

    def test_append_database_matches_existing_indentation
      zero_indent = "databases:\n- name: existing\n  host: h\n"
      out = ConfigWriter.append_database(zero_indent, ConfigWriter.render_database(entry(name: "added")))

      assert_includes out, "\n- name: added\n"
      assert_includes out, "\n  host: db.internal\n"
    end

    def test_append_database_preserves_erb_and_comments
      existing = <<~YAML
        # a comment
        databases:
          - name: existing
            password: <%= ENV["SOME_SECRET"] %>
      YAML
      out = ConfigWriter.append_database(existing, ConfigWriter.render_database(entry(name: "added")))

      assert_includes out, "# a comment"
      assert_includes out, %(<%= ENV["SOME_SECRET"] %>)
    end

    def test_append_database_raises_without_a_databases_block
      assert_raises(ConfigError) do
        ConfigWriter.append_database("workdir: /wd\n", ConfigWriter.render_database(entry))
      end
    end

    def test_write_is_atomic_and_creates_parent_dirs
      in_tmpdir do |dir|
        path = File.join(dir, "nested", "pgkeeper.yml")
        ConfigWriter.write(path, "hello: world\n")

        assert_equal "hello: world\n", File.read(path)
        assert_empty Dir.glob(File.join(dir, "nested", "*.tmp.*"))
      end
    end
  end
end
