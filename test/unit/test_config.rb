# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestConfig < Minitest::Test
    include TestHelpers

    def test_parses_minimal_config_with_defaults
      config = Config.parse(<<~YAML)
        databases:
          - name: app
      YAML

      assert_equal 1, config.databases.length
      db = config.databases.first

      assert_equal "app", db.name
      assert_equal "app", db.database, "database defaults to name"
      assert_equal "custom", db.format, "format defaults to custom"
      refute db.include_globals
      assert_equal "none", config.compression
      refute config.encryption["enabled"]
    end

    def test_defaults_merge_into_each_database
      config = Config.parse(<<~YAML)
        defaults:
          host: db.internal
          username: backup
          include_globals: true
        databases:
          - name: app
          - name: analytics
            host: analytics.internal
      YAML

      app = config.database("app")
      analytics = config.database("analytics")

      assert_equal "db.internal", app.host
      assert_equal "backup", app.username
      assert app.include_globals
      assert_equal "analytics.internal", analytics.host, "per-db override wins over defaults"
      assert_equal "backup", analytics.username
    end

    def test_erb_interpolates_env
      yaml = Config.render(<<~ERB, "test")
        databases:
          - name: app
            password: <%= ENV.fetch("PGKEEPER_TEST_SECRET", "fallback") %>
      ERB

      config = Config.new(yaml)

      assert_equal "fallback", config.database("app").password
    end

    def test_libpq_env_excludes_password_when_using_pgpass
      config = Config.parse(<<~YAML)
        databases:
          - name: app
            host: h
            port: 6000
            username: u
            password: secret
            pgpass: true
      YAML

      env = config.database("app").libpq_env

      assert_equal "h", env["PGHOST"]
      assert_equal "6000", env["PGPORT"]
      assert_equal "u", env["PGUSER"]
      refute env.key?("PGPASSWORD"), "pgpass mode must not export PGPASSWORD"
    end

    def test_libpq_env_sets_password_by_default
      config = Config.parse(<<~YAML)
        databases:
          - name: app
            password: secret
      YAML

      assert_equal "secret", config.database("app").libpq_env["PGPASSWORD"]
    end

    def test_missing_databases_is_an_error
      err = assert_raises(ConfigError) { Config.parse("compression: gzip") }
      assert_includes err.problems.join, "databases"
    end

    def test_unknown_top_level_key_is_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databses:
            - name: typo
        YAML
      end
      assert(err.problems.any? { |p| p.include?("unknown key") })
    end

    def test_unknown_database_key_is_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
              hostt: typo
        YAML
      end
      assert(err.problems.any? { |p| p.include?("unknown key") })
    end

    def test_bad_format_enum_is_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
              format: bogus
        YAML
      end
      assert(err.problems.any? { |p| p.include?("format must be one of") })
    end

    def test_bad_compression_enum_is_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          compression: rar
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("compression must be one of") })
    end

    def test_duplicate_database_names_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("duplicate") })
    end

    def test_non_integer_port_reported
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
              port: not-a-number
        YAML
      end
      assert(err.problems.any? { |p| p.include?("port must be an integer") })
    end

    def test_negative_retention_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          retention:
            keep_daily: -1
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("non-negative integer") })
    end

    def test_bad_notification_event_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          notifications:
            email:
              on: [success, explosion]
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("unknown event") })
    end

    def test_default_storage_when_none_given
      config = Config.parse(<<~YAML)
        workdir: /data/pgk
        databases:
          - name: app
      YAML

      assert_equal "/data/pgk/backups", config.local_path
    end

    def test_dropbox_storage_with_access_token_accepted
      config = Config.parse(<<~YAML)
        storage:
          - type: dropbox
            root: /pgkeeper
            access_token: tok-123
        databases:
          - name: app
      YAML

      assert_equal "dropbox", config.storage.first["type"]
    end

    def test_dropbox_storage_without_credentials_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          storage:
            - type: dropbox
              root: /pgkeeper
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("dropbox") && p.include?("access_token") })
    end

    def test_google_drive_storage_accepted
      config = Config.parse(<<~YAML)
        storage:
          - type: google_drive
            folder_id: ABC123
            credentials_file: /etc/pgkeeper/sa.json
        databases:
          - name: app
      YAML

      assert_equal "google_drive", config.storage.first["type"]
    end

    def test_google_drive_storage_without_credentials_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          storage:
            - type: google_drive
              folder_id: ABC123
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("google_drive") && p.include?("credentials") })
    end

    def test_sharepoint_storage_accepted
      config = Config.parse(<<~YAML)
        storage:
          - type: sharepoint
            drive_id: b!drive
            tenant_id: tenant-uuid
            client_id: app-uuid
            client_secret: shhh
        databases:
          - name: app
      YAML

      assert_equal "sharepoint", config.storage.first["type"]
    end

    def test_sharepoint_storage_without_credentials_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          storage:
            - type: sharepoint
              drive_id: b!drive
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("sharepoint") && p.include?("tenant_id") })
    end

    def test_load_missing_file_raises
      assert_raises(ConfigError) { Config.load("/nonexistent/pgkeeper.yml") }
    end

    def test_load_reads_and_validates_file
      in_tmpdir do |dir|
        path = File.join(dir, "pgkeeper.yml")
        File.write(path, "databases:\n  - name: app\n")
        config = Config.load(path)

        assert_equal path, config.source
        assert_equal 1, config.databases.length
      end
    end

    def test_valid_schedule_accepted
      config = Config.parse(<<~YAML)
        schedule: daily at 03:15
        databases:
          - name: app
            schedule: every monday at 9am
      YAML

      assert_equal "daily at 03:15", config.schedule
      assert_equal "every monday at 9am", config.database("app").schedule
    end

    def test_bad_global_schedule_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          schedule: whenever
          databases:
            - name: app
        YAML
      end
      assert(err.problems.any? { |p| p.include?("schedule") })
    end

    def test_bad_database_schedule_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
              schedule: "not a schedule"
        YAML
      end
      assert(err.problems.any? { |p| p.include?("schedule") })
    end

    # --- maintenance block ------------------------------------------------

    def test_maintenance_block_parses_verify_and_prune
      config = Config.parse(<<~YAML)
        databases:
          - name: app
        maintenance:
          verify:
            schedule: weekly on sunday at 04:00
            deep: true
          prune:
            schedule: daily at 05:00
            apply: true
            only: app
      YAML

      assert_equal "weekly on sunday at 04:00", config.maintenance["verify"]["schedule"]
      assert config.maintenance["verify"]["deep"]
      assert_equal ["app"], config.maintenance["prune"]["only"]
      assert config.maintenance["prune"]["apply"]
    end

    def test_maintenance_task_requires_a_schedule
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          maintenance:
            verify:
              deep: true
        YAML
      end
      assert(err.problems.any? { |p| p.include?("maintenance.verify requires a `schedule`") })
    end

    def test_maintenance_bad_schedule_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          maintenance:
            prune:
              schedule: whenever
        YAML
      end
      assert(err.problems.any? { |p| p.include?("maintenance.prune.schedule") })
    end

    def test_maintenance_unknown_key_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          maintenance:
            reindex:
              schedule: daily
        YAML
      end
      assert(err.problems.any? { |p| p.include?("maintenance has unknown key") })
    end

    # --- S3 Object Lock (immutable backups) -------------------------------

    def test_s3_object_lock_accepted
      config = Config.parse(<<~YAML)
        databases:
          - name: app
        storage:
          - type: s3
            bucket: backups
            object_lock:
              mode: COMPLIANCE
              retain_days: 30
      YAML

      lock = config.storage.first["object_lock"]

      assert_equal "COMPLIANCE", lock["mode"]
      assert_equal 30, lock["retain_days"]
    end

    def test_s3_object_lock_bad_mode_rejected
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          storage:
            - type: s3
              bucket: backups
              object_lock:
                mode: FOREVER
                retain_days: 30
        YAML
      end
      assert(err.problems.any? { |p| p.include?("object_lock.mode") })
    end

    def test_s3_object_lock_requires_positive_retain_days
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          storage:
            - type: s3
              bucket: backups
              object_lock:
                mode: GOVERNANCE
                retain_days: 0
        YAML
      end
      assert(err.problems.any? { |p| p.include?("object_lock.retain_days") })
    end

    # --- encryption key rotation ------------------------------------------

    def test_encryption_previous_keys_accepted
      config = Config.parse(<<~YAML)
        databases:
          - name: app
        encryption:
          enabled: true
          passphrase_env: PGKEEPER_PASS
          previous_passphrase_envs:
            - PGKEEPER_PASS_OLD
          previous_keyfiles:
            - /etc/pgkeeper/old.key
      YAML

      assert_equal ["PGKEEPER_PASS_OLD"], config.encryption["previous_passphrase_envs"]
      assert_equal ["/etc/pgkeeper/old.key"], config.encryption["previous_keyfiles"]
    end

    def test_encryption_previous_passphrase_envs_must_be_a_list
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          encryption:
            enabled: true
            passphrase_env: PGKEEPER_PASS
            previous_passphrase_envs: PGKEEPER_PASS_OLD
        YAML
      end
      assert(err.problems.any? { |p| p.include?("previous_passphrase_envs must be a list") })
    end

    def test_slug_is_filesystem_safe
      config = Config.parse(<<~YAML)
        databases:
          - name: "app/prod:1"
      YAML

      assert_equal "app_prod_1", config.database("app/prod:1").slug
    end

    def test_web_block_is_validated_but_optional
      config = Config.parse(<<~YAML)
        databases:
          - name: app
        web:
          bind: 0.0.0.0
          port: 9000
          auth:
            token: sekrit
      YAML

      assert_equal({ "bind" => "0.0.0.0", "port" => 9000, "auth" => { "token" => "sekrit" } }, config.web)
      assert_empty Config.parse("databases:\n  - name: app").web, "web is optional"
    end

    def test_web_rejects_bad_port_and_unknown_keys
      err = assert_raises(ConfigError) do
        Config.parse(<<~YAML)
          databases:
            - name: app
          web:
            port: 99999
            listen: nope
            auth:
              tokenn: typo
        YAML
      end

      assert(err.problems.any? { |p| p.include?("web.port") })
      assert(err.problems.any? { |p| p.include?("web has unknown key") })
      assert(err.problems.any? { |p| p.include?("web.auth has unknown key") })
    end

    def test_web_auth_with_unset_env_var_does_not_fail_validation
      config = Config.parse(<<~YAML)
        databases:
          - name: app
        web:
          auth:
            token:
      YAML

      assert_nil config.web.dig("auth", "token"),
                 "an unset env var must not break config validation — `pgkeeper web` enforces it"
    end
  end
end
