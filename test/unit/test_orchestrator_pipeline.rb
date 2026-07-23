# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Unit tests for the artifact pipeline steps (compress/encrypt/package) that
  # don't require a database — they operate on a fake "raw dump" file.
  class TestOrchestratorPipeline < Minitest::Test
    include TestHelpers

    def orchestrator(overrides = {})
      cfg = {
        "workdir" => "/tmp",
        "compression" => "gzip",
        "databases" => [{ "name" => "app" }]
      }.merge(overrides)
      Orchestrator.new(Config.new(cfg), logger: null_logger)
    end

    def ctx(staging)
      Orchestrator::DumpContext.new(db: nil, staging: staging, began_at: nil, timestamp: "t", log: null_logger)
    end

    def raw_file(dir, name, content)
      path = File.join(dir, name)
      File.binwrite(path, content)
      path
    end

    def test_plain_format_applies_configured_compression
      in_tmpdir do |dir|
        orch = orchestrator("compression" => "gzip")
        raw = raw_file(dir, "app.sql", "SELECT 1; " * 1000)
        result, name = orch.send(:package_and_compress, raw, "plain", ctx(dir))

        assert_equal "gzip", name
        assert result.end_with?(".sql.gz")
        refute_path_exists raw, "raw dump should be replaced by the compressed file"
      end
    end

    def test_custom_format_skips_external_compression
      in_tmpdir do |dir|
        orch = orchestrator("compression" => "gzip")
        raw = raw_file(dir, "app.dump", "already compressed bytes")
        result, name = orch.send(:package_and_compress, raw, "custom", ctx(dir))

        assert_equal "none", name, "custom dumps are already compressed; skip external compression"
        assert_equal raw, result
      end
    end

    def test_none_compression_is_passthrough
      in_tmpdir do |dir|
        orch = orchestrator("compression" => "none")
        raw = raw_file(dir, "app.sql", "data")
        result, name = orch.send(:package_and_compress, raw, "plain", ctx(dir))

        assert_equal "none", name
        assert_equal raw, result
      end
    end

    def test_directory_format_is_zipped
      in_tmpdir do |dir|
        orch = orchestrator("compression" => "none")
        dump_dir = File.join(dir, "app.dir")
        FileUtils.mkdir_p(dump_dir)
        File.binwrite(File.join(dump_dir, "toc.dat"), "table of contents")
        File.binwrite(File.join(dump_dir, "3.dat"), "row data")

        result, name = orch.send(:package_and_compress, dump_dir, "directory", ctx(dir))

        assert_equal "zip", name
        assert result.end_with?(".dir.zip")
        refute_path_exists dump_dir, "the dump directory should be replaced by the zip"

        ::Zip::File.open(result) do |zip|
          assert_includes zip.entries.map(&:name), "toc.dat"
        end
      end
    end

    def test_maybe_encrypt_noop_when_disabled
      in_tmpdir do |dir|
        orch = orchestrator("encryption" => { "enabled" => false })
        orch.instance_variable_set(:@encryptor, Crypto.build({ "enabled" => false }))
        raw = raw_file(dir, "app.sql", "plain")
        result, name = orch.send(:maybe_encrypt, raw, ctx(dir))

        assert_equal "none", name
        assert_equal raw, result
      end
    end

    def test_maybe_encrypt_applies_aes
      in_tmpdir do |dir|
        orch = orchestrator
        orch.instance_variable_set(:@encryptor,
                                   Crypto.build({ "enabled" => true, "type" => "aes256gcm", "passphrase_env" => "P" },
                                                env: { "P" => "secret" }))
        raw = raw_file(dir, "app.sql", "plaintext contents")
        result, name = orch.send(:maybe_encrypt, raw, ctx(dir))

        assert_equal "aes256gcm", name
        assert result.end_with?(".enc")
        refute_path_exists raw
        refute_includes File.binread(result), "plaintext contents"
      end
    end

    # Status classification: a run that stored nothing anywhere is a failure —
    # the staging copy is deleted on the way out, so "partial" would report a
    # backup that does not exist.
    def ok_dest = Orchestrator::Destination.new(name: "a", status: :ok)
    def failed_dest = Orchestrator::Destination.new(name: "b", status: :failed, error: "boom")
    def status_of(destinations) = orchestrator.send(:derive_status, [{ destinations: destinations }])

    def test_all_destinations_ok_is_success
      assert_equal :success, status_of([ok_dest, ok_dest])
    end

    def test_some_destinations_failed_is_partial
      assert_equal :partial, status_of([ok_dest, failed_dest])
    end

    def test_every_destination_failed_is_failure
      assert_equal :failure, status_of([failed_dest, failed_dest])
    end

    def test_a_single_failed_destination_is_failure
      assert_equal :failure, status_of([failed_dest])
    end
  end
end
