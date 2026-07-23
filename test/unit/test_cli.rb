# frozen_string_literal: true

require "test_helper"
require "json"
require "pgkeeper/cli"

module PgKeeper
  # The CLI is a thin Thor dispatch layer; these lock its command aliases so a
  # rename of the underlying command can't silently break the shorthand.
  class TestCli < Minitest::Test
    include TestHelpers

    def aliases
      CLI.instance_variable_get(:@map)
    end

    def test_run_is_an_alias_for_backup
      assert_equal :backup, aliases["run"], "`pgkeeper run` should dispatch to backup"
    end

    def test_onboard_is_an_alias_for_connect
      assert_equal :connect, aliases["onboard"], "`pgkeeper onboard` should dispatch to connect"
    end

    def test_status_reports_pitr_lag_and_window
      in_tmpdir do |dir|
        write_pitr_config(dir)
        store = File.join(dir, "store")
        seed_pitr(store, "pgc/base/b1", "base", Time.now.utc - 3600, "start_segment" => "000000010000000000000005")
        seed_pitr(store, "pgc/wal/000000010000000000000005", "wal", Time.now.utc - 120,
                  "segment" => "000000010000000000000005")

        out, = capture_io { CLI.start(["status", "-c", File.join(dir, "pgkeeper.yml")]) }

        assert_includes out, "PITR clusters"
        assert_includes out, "pgc"
        assert_includes out, "WAL lag"
        assert_includes out, "window"
      end
    end

    def test_status_flags_stalled_wal_archiving
      in_tmpdir do |dir|
        write_pitr_config(dir, pitr: "{ enabled: true, max_lag: 1m }")
        store = File.join(dir, "store")
        seed_pitr(store, "pgc/base/b1", "base", Time.now.utc - 3600, "start_segment" => "000000010000000000000005")
        seed_pitr(store, "pgc/wal/000000010000000000000005", "wal", Time.now.utc - 1800,
                  "segment" => "000000010000000000000005")

        out, = capture_io { CLI.start(["status", "-c", File.join(dir, "pgkeeper.yml")]) }

        assert_includes out, "STALLED"
      end
    end

    private

    def write_pitr_config(dir, pitr: "{ enabled: true, max_lag: 10m, recovery_window: 7d }")
      File.write(File.join(dir, "pgkeeper.yml"),
                 "workdir: #{dir}\ndatabases:\n  - name: app\nstorage:\n  - type: local\n    path: #{dir}/store\n" \
                 "clusters:\n  - name: pgc\n    host: h\n    pitr: #{pitr}\n")
    end

    def seed_pitr(store, remote, kind, at, extra = {})
      adapter = Storage::Local.new(root: store, logger: null_logger)
      Dir.mktmpdir do |tmp|
        art = File.join(tmp, "a")
        File.binwrite(art, "x")
        adapter.upload(art, remote)
        manifest = { "database" => "pgc", "kind" => kind, "started_at" => at.iso8601,
                     "size_bytes" => 1, "checksum" => { "value" => "x" } }.merge(extra)
        meta = File.join(tmp, "m.json")
        File.write(meta, JSON.generate(manifest))
        adapter.upload(meta, "#{remote}#{Manifest::SUFFIX}")
      end
    end
  end
end
