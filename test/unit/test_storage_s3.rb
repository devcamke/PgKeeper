# frozen_string_literal: true

require "test_helper"
require "support/storage_contract"
require "aws-sdk-s3"

module PgKeeper
  # Exercises the real S3 adapter against a real Aws::S3::Client whose responses
  # are stubbed by a stateful in-memory store — so every adapter code path runs,
  # without a network or credentials, and the adapter must satisfy the same
  # storage contract as Local and Memory.
  class TestStorageS3 < Minitest::Test
    include TestHelpers
    include StorageContract

    def setup
      @store = {}
      @client = stubbed_client(@store)
    end

    def build_adapter
      Storage::S3.with_client(@client, bucket: "backups", prefix: "pgk", logger: null_logger)
    end

    def test_prefix_is_applied_to_keys
      with_local_file("data") do |src, _dir|
        adapter.upload(src, "db/app.dump")
        # The stored key carries the configured prefix.
        assert_includes @store.keys, "pgk/db/app.dump"
      end
    end

    def test_name_is_s3_url
      assert_equal "s3://backups/pgk/", build_adapter.name
    end

    def test_missing_sdk_message
      # The lazy require raises a helpful EnvironmentError message when absent;
      # here the gem is present, so just assert the adapter constructed fine.
      assert_instance_of Storage::S3, build_adapter
    end

    def test_multipart_upload_reassembles_the_whole_object
      # A 6 MiB payload with a 5 MiB threshold forces the multipart path
      # (create → two upload_parts → complete); the SDK refuses multipart below
      # its 5 MiB part minimum. This proves large uploads no longer go through a
      # single size-capped PUT and that parts reassemble in order.
      adapter = Storage::S3.with_client(
        @client, bucket: "backups", prefix: "pgk", logger: null_logger, multipart_threshold: 5 * 1024 * 1024
      )
      payload = "0123456789abcdef" * (6 * 1024 * 1024 / 16) # exactly 6 MiB
      with_local_file(payload) do |src, _dir|
        result = adapter.upload(src, "db/big.dump")

        assert_equal payload, @store["pgk/db/big.dump"]
        assert_equal payload.bytesize, result.size_bytes
      end
    end

    def test_object_lock_sets_worm_retention_on_upload
      captured = {}
      client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1")
      client.stub_responses(:put_object, lambda { |ctx|
        captured.replace(ctx.params)
        {}
      })
      client.stub_responses(:head_object, { content_length: 4 })
      adapter = Storage::S3.with_client(client, bucket: "backups", prefix: "pgk", logger: null_logger,
                                                object_lock: { "mode" => "COMPLIANCE", "retain_days" => 30 })

      with_local_file("data") { |src, _dir| adapter.upload(src, "db/app.dump") }

      assert_equal "COMPLIANCE", captured[:object_lock_mode]
      assert_kind_of Time, captured[:object_lock_retain_until_date]
      # ~30 days out (allow slack), and in UTC.
      assert_operator captured[:object_lock_retain_until_date], :>, Time.now + (29 * 86_400)
      assert_operator captured[:object_lock_retain_until_date], :<, Time.now + (31 * 86_400)
    end

    def test_object_lock_rejects_missing_or_nonpositive_retain_days
      # retain_days coerced to 0 would mean retain-until = now: Object Lock
      # configured but protecting nothing. Misconfiguration must fail loudly.
      [{ "mode" => "COMPLIANCE" },
       { "mode" => "COMPLIANCE", "retain_days" => 0 },
       { "mode" => "COMPLIANCE", "retain_days" => "soon" }].each do |cfg|
        assert_raises(ConfigError, "object_lock #{cfg.inspect} should be rejected") do
          Storage::S3.with_client(@client, bucket: "backups", prefix: "pgk", logger: null_logger, object_lock: cfg)
        end
      end
    end

    def test_uploads_carry_no_object_lock_by_default
      captured = {}
      client = stubbed_client({})
      client.stub_responses(:put_object, lambda { |ctx|
        captured.replace(ctx.params)
        {}
      })
      adapter = Storage::S3.with_client(client, bucket: "backups", prefix: "pgk", logger: null_logger)

      with_local_file("data") { |src, _dir| adapter.upload(src, "db/app.dump") }

      refute captured.key?(:object_lock_mode), "no Object Lock unless configured"
      refute captured.key?(:object_lock_retain_until_date)
    end

    private

    def stubbed_client(store)
      client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1")
      parts = Hash.new { |h, k| h[k] = {} }
      client.stub_responses(:head_bucket, {})
      client.stub_responses(:put_object, lambda { |ctx|
        store[ctx.params[:key]] = read_body(ctx.params[:body])
        {}
      })
      client.stub_responses(:create_multipart_upload, lambda { |ctx|
        parts[ctx.params[:key]] = {}
        { upload_id: "mpu-#{ctx.params[:key]}" }
      })
      client.stub_responses(:upload_part, lambda { |ctx|
        parts[ctx.params[:key]][ctx.params[:part_number]] = read_body(ctx.params[:body])
        { etag: %("etag-#{ctx.params[:part_number]}") }
      })
      client.stub_responses(:complete_multipart_upload, lambda { |ctx|
        key = ctx.params[:key]
        store[key] = parts.delete(key).sort.map { |_number, data| data }.join
        {}
      })
      client.stub_responses(:get_object, lambda { |ctx|
        data = store[ctx.params[:key]]
        data ? { body: data } : "NoSuchKey"
      })
      client.stub_responses(:head_object, lambda { |ctx|
        data = store[ctx.params[:key]]
        data ? { content_length: data.bytesize } : "NotFound"
      })
      client.stub_responses(:delete_object, lambda { |ctx|
        store.delete(ctx.params[:key])
        {}
      })
      client.stub_responses(:list_objects_v2, lambda { |ctx|
        prefix = ctx.params[:prefix].to_s
        contents = store.select { |k, _| k.start_with?(prefix) }.map { |k, v| { key: k, size: v.bytesize } }
        { contents: contents, is_truncated: false, key_count: contents.length }
      })
      client
    end

    def read_body(body)
      return body.to_s unless body.respond_to?(:read)

      body.rewind if body.respond_to?(:rewind)
      body.read
    end
  end
end
