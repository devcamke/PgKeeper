# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestCompress < Minitest::Test
    include TestHelpers

    # The interesting property is the same for every backend: compress then
    # decompress must return the original bytes exactly.
    def assert_round_trips(compressor, payload)
      in_tmpdir do |dir|
        source = File.join(dir, "source.bin")
        File.binwrite(source, payload)

        compressed = File.join(dir, "out.#{compressor.extension}")
        compressor.compress(source, compressed)

        assert_path_exists compressed

        restored = File.join(dir, "restored.bin")
        compressor.decompress(compressed, restored)

        assert_equal payload, File.binread(restored)
      end
    end

    def test_none_round_trips
      assert_round_trips(Compress.for("none"), "plain bytes")
    end

    def test_gzip_round_trips
      assert_round_trips(Compress.for("gzip"), "the quick brown fox " * 1000)
    end

    def test_gzip_actually_shrinks_compressible_data
      in_tmpdir do |dir|
        source = File.join(dir, "s")
        File.binwrite(source, "a" * 100_000)
        dest = File.join(dir, "s.gz")
        Compress.for("gzip").compress(source, dest)

        assert_operator File.size(dest), :<, File.size(source)
      end
    end

    def test_zip_round_trips
      assert_round_trips(Compress.for("zip"), "zip me " * 5000)
    end

    def test_zip_entry_name_drops_zip_suffix
      in_tmpdir do |dir|
        source = File.join(dir, "app.dump")
        File.binwrite(source, "data")
        dest = File.join(dir, "app.dump.zip")
        Compress.for("zip").compress(source, dest)

        ::Zip::File.open(dest) do |zip|
          assert_equal ["app.dump"], zip.entries.map(&:name)
        end
      end
    end

    def test_gzip_round_trips_large_multichunk_payload
      # 3 MiB exercises the streaming chunk loop in both directions.
      assert_round_trips(Compress.for("gzip"), "x" * (3 * 1024 * 1024))
    end

    def test_unknown_compressor_raises
      assert_raises(ConfigError) { Compress.for("rar") }
    end

    def test_zstd_round_trips_or_skips
      compressor = Compress.for("zstd")
      skip "zstd binary not installed" unless compressor.available?

      assert_round_trips(compressor, "zstd payload " * 2000)
    end

    def test_available_predicate
      assert Compress.available?("gzip")
      assert Compress.available?("zip")
      assert Compress.available?("none")
      refute Compress.available?("bogus")
    end
  end
end
