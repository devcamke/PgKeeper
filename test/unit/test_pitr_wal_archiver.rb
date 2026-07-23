# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module PgKeeper
  # WAL archive → fetch round-trips through the same compress/encrypt pipeline as
  # dumps, using a real local storage backend (no live Postgres needed).
  class TestPitrWalArchiver < Minitest::Test
    include TestHelpers

    SEG = "000000010000000000000001" # timeline 1, log 0, segment 1

    def config(dir, extra = "")
      Config.parse(<<~YAML)
        workdir: #{dir}
        databases:
          - name: app
        storage:
          - type: local
            path: #{dir}/store
        #{extra}
        clusters:
          - name: c1
            host: h
            pitr: { enabled: true }
      YAML
    end

    def archiver(cfg)
      PITR::WalArchiver.new(cfg, cfg.pitr_clusters.first, logger: null_logger)
    end

    def write_segment(dir, name: SEG)
      bytes = "wal-bytes-#{name}-" * 200
      path = File.join(dir, name)
      File.binwrite(path, bytes)
      [path, bytes]
    end

    def stored(dir, name) = File.join(dir, "store", "c1", "wal", name)

    def test_archives_and_fetches_a_segment_round_trip
      in_tmpdir do |dir|
        arch = archiver(config(dir, "compression: gzip"))
        spool = Dir.mktmpdir
        path, bytes = write_segment(spool)

        assert arch.archive_file(path)
        assert_path_exists stored(dir, SEG)
        assert_path_exists stored(dir, "#{SEG}#{Manifest::SUFFIX}")

        out = File.join(dir, "fetched")

        assert arch.fetch(SEG, out)
        assert_equal bytes, File.binread(out), "fetch reverses compression"
      end
    end

    def test_round_trips_through_encryption_with_ciphertext_at_rest
      in_tmpdir do |dir|
        ENV["PGK_TEST_PASS"] = "s3kret-passphrase"
        extra = "compression: gzip\nencryption:\n  enabled: true\n  type: aes256gcm\n  passphrase_env: PGK_TEST_PASS"
        arch = archiver(config(dir, extra))
        spool = Dir.mktmpdir
        path, bytes = write_segment(spool)
        arch.archive_file(path)

        refute_equal bytes, File.binread(stored(dir, SEG)), "stored segment is ciphertext"

        out = File.join(dir, "fetched")
        arch.fetch(SEG, out)

        assert_equal bytes, File.binread(out), "fetch decrypts and decompresses"
      ensure
        ENV.delete("PGK_TEST_PASS")
      end
    end

    def test_archive_spool_skips_partial_segments_and_removes_archived
      in_tmpdir do |dir|
        arch = archiver(config(dir))
        spool = Dir.mktmpdir
        write_segment(spool, name: SEG)
        File.binwrite(File.join(spool, "#{SEG}.partial"), "still filling")

        count = arch.archive_spool(spool)

        assert_equal 1, count
        refute_path_exists File.join(spool, SEG), "an archived segment is removed from the spool"
        assert_path_exists File.join(spool, "#{SEG}.partial"), "a .partial segment is left alone"
      end
    end

    def test_rejects_a_non_segment_name
      in_tmpdir { |dir| assert_raises(Error) { archiver(config(dir)).archive_file("/tmp/x", "not-a-segment") } }
    end

    # Postgres's archive_command also hands over timeline-history and
    # backup-history files; refusing them wedges archiving forever (the queue is
    # strictly ordered), so both must archive — and fetch back, since a restore
    # with recovery_target_timeline=latest asks for .history files.
    def test_archives_and_fetches_history_and_backup_label_files
      in_tmpdir do |dir|
        arch = archiver(config(dir))
        spool = Dir.mktmpdir
        %w[00000002.history 000000010000000000000005.00000028.backup].each do |name|
          path, bytes = write_segment(spool, name: name)

          assert arch.archive_file(path), "#{name} must be archivable"
          assert_path_exists stored(dir, name)

          out = File.join(dir, "fetched-#{name}")
          arch.fetch(name, out)

          assert_equal bytes, File.binread(out)
        end
      end
    end

    def test_archive_spool_drains_history_files_too
      in_tmpdir do |dir|
        arch = archiver(config(dir))
        spool = Dir.mktmpdir
        write_segment(spool, name: SEG)
        write_segment(spool, name: "00000002.history")

        assert_equal 2, arch.archive_spool(spool)
        refute_path_exists File.join(spool, "00000002.history")
      end
    end

    def test_fetching_a_missing_segment_raises
      in_tmpdir do |dir|
        error = assert_raises(Error) { archiver(config(dir)).fetch(SEG, File.join(dir, "out")) }

        assert_includes error.message, "not found"
      end
    end
  end
end
