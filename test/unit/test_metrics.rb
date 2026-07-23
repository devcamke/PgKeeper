# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestMetrics < Minitest::Test
    include TestHelpers

    def config(dir)
      Config.parse(<<~YAML)
        workdir: #{dir}
        databases:
          - name: app
          - name: analytics
        storage:
          - type: local
            path: #{dir}/b
      YAML
    end

    def record(config, database:, status:, at:, size: 2048, duration: 3.5)
      artifacts = status == :failure ? [] : [{ kind: "database", size_bytes: size, destinations: [] }]
      result = Orchestrator::Result.new(database: database, status: status, artifacts: artifacts,
                                        duration_seconds: duration)
      History.new(File.join(config.workdir, "history.sqlite3"), logger: null_logger)
             .record(Orchestrator::RunReport.new(results: [result]),
                     run_id: "r-#{at.to_i}", started_at: at, finished_at: at + 5)
    end

    def test_renders_up_and_help_type_headers
      in_tmpdir do |dir|
        text = Metrics.render(config(dir), logger: null_logger)

        assert_includes text, "pgkeeper_up 1"
        assert_includes text, "# TYPE pgkeeper_last_run_timestamp_seconds gauge"
        assert_includes text, "# HELP pgkeeper_last_backup_size_bytes"
        assert text.end_with?("\n")
      end
    end

    def test_emits_per_database_series_from_history
      in_tmpdir do |dir|
        cfg = config(dir)
        at = Time.utc(2026, 7, 21, 3, 15)
        record(cfg, database: "app", status: :success, at: at, size: 4096, duration: 12.0)

        text = Metrics.render(cfg, logger: null_logger)

        assert_includes text, %(pgkeeper_last_run_success{database="app"} 1)
        assert_includes text, %(pgkeeper_last_backup_size_bytes{database="app"} 4096)
        assert_includes text, %(pgkeeper_last_run_duration_seconds{database="app"} 12.0)
        assert_includes text, %(pgkeeper_last_run_timestamp_seconds{database="app"} #{at.to_i})
        assert_includes text, %(pgkeeper_last_success_timestamp_seconds{database="app"} #{at.to_i})
      end
    end

    def test_failed_last_run_reports_zero_and_keeps_prior_success_time
      in_tmpdir do |dir|
        cfg = config(dir)
        ok_at = Time.utc(2026, 7, 20, 3, 15)
        fail_at = Time.utc(2026, 7, 21, 3, 15)
        record(cfg, database: "app", status: :success, at: ok_at)
        record(cfg, database: "app", status: :failure, at: fail_at)

        text = Metrics.render(cfg, logger: null_logger)

        assert_includes text, %(pgkeeper_last_run_success{database="app"} 0)
        # last-success timestamp must still point at the earlier successful run
        assert_includes text, %(pgkeeper_last_success_timestamp_seconds{database="app"} #{ok_at.to_i})
      end
    end

    def test_database_with_no_history_emits_no_series
      in_tmpdir do |dir|
        cfg = config(dir)
        record(cfg, database: "app", status: :success, at: Time.utc(2026, 7, 21))

        text = Metrics.render(cfg, logger: null_logger)

        refute_includes text, %(database="analytics")
      end
    end

    def test_label_values_are_escaped
      assert_equal 'a\\"b', Metrics.escape_label('a"b')
      assert_equal "a\\\\b", Metrics.escape_label("a\\b")
    end

    def seed_pitr(dir, manifest, remote)
      adapter = Storage::Local.new(root: File.join(dir, "b"), logger: null_logger)
      Dir.mktmpdir do |tmp|
        art = File.join(tmp, "a")
        File.binwrite(art, "x")
        adapter.upload(art, remote)
        meta = File.join(tmp, "m.json")
        File.write(meta, JSON.generate(manifest))
        adapter.upload(meta, "#{remote}#{Manifest::SUFFIX}")
      end
    end

    def pitr_config(dir, pitr: "enabled: true, max_lag: 10m")
      Config.parse("workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/b\n" \
                   "clusters:\n  - name: c1\n    host: h\n    pitr: { #{pitr} }\n")
    end

    def test_emits_pitr_series_per_cluster
      in_tmpdir do |dir|
        cfg = pitr_config(dir)
        base_at = Time.now.utc - 3600
        wal_at = Time.now.utc - 120
        seed_pitr(dir, { "database" => "c1", "kind" => "base", "started_at" => base_at.iso8601,
                         "size_bytes" => 1, "checksum" => { "value" => "x" },
                         "start_segment" => "000000010000000000000005" }, "c1/base/b1")
        seed_pitr(dir, { "database" => "c1", "kind" => "wal", "started_at" => wal_at.iso8601, "size_bytes" => 1,
                         "checksum" => { "value" => "x" }, "segment" => "000000010000000000000005" },
                  "c1/wal/000000010000000000000005")

        text = Metrics.render(cfg, logger: null_logger)

        assert_includes text, "# TYPE pgkeeper_wal_archive_lag_seconds gauge"
        assert_match(/pgkeeper_wal_archive_lag_seconds\{cluster="c1"\} \d+/, text)
        assert_includes text, %(pgkeeper_wal_archive_stalled{cluster="c1"} 0)
        assert_match(/pgkeeper_recovery_window_seconds\{cluster="c1"\} \d+/, text)
        assert_includes text, %(pgkeeper_last_base_backup_timestamp_seconds{cluster="c1"} #{base_at.to_i})
      end
    end

    def test_stalled_switch_is_omitted_without_a_threshold
      in_tmpdir do |dir|
        cfg = pitr_config(dir, pitr: "enabled: true")
        seed_pitr(dir, { "database" => "c1", "kind" => "wal", "started_at" => (Time.now.utc - 60).iso8601,
                         "size_bytes" => 1, "checksum" => { "value" => "x" },
                         "segment" => "000000010000000000000005" }, "c1/wal/000000010000000000000005")

        text = Metrics.render(cfg, logger: null_logger)

        assert_includes text, %(pgkeeper_wal_archive_lag_seconds{cluster="c1"})
        refute_includes text, "pgkeeper_wal_archive_stalled{cluster="
      end
    end

    def test_no_pitr_series_without_clusters
      in_tmpdir do |dir|
        text = Metrics.render(config(dir), logger: null_logger)

        refute_includes text, "pgkeeper_wal_archive_lag_seconds"
      end
    end

    def test_write_textfile_is_atomic_and_creates_dirs
      in_tmpdir do |dir|
        path = File.join(dir, "sub", "pgkeeper.prom")
        Metrics.write_textfile("pgkeeper_up 1\n", path)

        assert_path_exists path
        assert_equal "pgkeeper_up 1\n", File.read(path)
        # no leftover temp files beside it
        assert_equal ["pgkeeper.prom"], Dir.children(File.dirname(path))
      end
    end
  end
end
