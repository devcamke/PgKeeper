# frozen_string_literal: true

require "fileutils"

module PgKeeper
  module Storage
    # S3-compatible object storage: AWS S3 and any API-compatible service
    # (MinIO, Backblaze B2, Cloudflare R2, DigitalOcean Spaces) via a custom
    # +endpoint+.
    #
    # The +aws-sdk-s3+ gem is an *optional* dependency — this adapter requires it
    # lazily and tells the user to install it if it's missing, so a local-only
    # PgKeeper install stays lean.
    class S3 < Base
      attr_reader :bucket, :prefix

      def initialize(bucket:, region: nil, prefix: "", endpoint: nil,
                     access_key_id: nil, secret_access_key: nil, force_path_style: false, **)
        super(**)
        require_sdk!
        @bucket = bucket
        @prefix = normalize_prefix(prefix)
        @client = build_client(region, endpoint, access_key_id, secret_access_key, force_path_style)
      end

      # Inject a pre-built (e.g. stubbed) client — used by tests.
      def self.with_client(client, bucket:, prefix: "", **opts)
        allocate.tap do |s3|
          s3.send(:init_with_client, client, bucket: bucket, prefix: prefix, **opts)
        end
      end

      def name = "s3://#{@bucket}/#{@prefix}"

      def healthcheck
        @client.head_bucket(bucket: @bucket)
        true
      rescue StandardError => e
        raise StorageError.new("#{name}: bucket not reachable: #{e.message}", destination: name)
      end

      private

      def init_with_client(client, bucket:, prefix: "", logger: PgKeeper.logger,
                           retry_attempts: DEFAULT_ATTEMPTS, retry_base: 0.5)
        @logger = logger
        @retry_attempts = retry_attempts
        @retry_base = retry_base
        @client = client
        @bucket = bucket
        @prefix = normalize_prefix(prefix)
      end

      def do_upload(local_path, remote_path)
        File.open(local_path, "rb") do |body|
          @client.put_object(bucket: @bucket, key: key(remote_path), body: body)
        end
      end

      def do_download(remote_path, local_path)
        FileUtils.mkdir_p(File.dirname(local_path))
        @client.get_object(response_target: local_path, bucket: @bucket, key: key(remote_path))
      end

      def do_delete(remote_path)
        @client.delete_object(bucket: @bucket, key: key(remote_path))
      end

      def do_list(prefix)
        entries = []
        @client.list_objects_v2(bucket: @bucket, prefix: key(prefix)).each do |page|
          page.contents.each do |obj|
            entries << Entry.new(path: strip_prefix(obj.key), size_bytes: obj.size)
          end
        end
        entries.sort_by(&:path)
      end

      def remote_size(remote_path)
        @client.head_object(bucket: @bucket, key: key(remote_path)).content_length
      rescue StandardError
        nil
      end

      # Retry throttling, 5xx, and networking errors; the SDK also retries
      # internally, this is a belt-and-suspenders outer layer.
      def transient_error?(error)
        return true if defined?(Seahorse::Client::NetworkingError) && error.is_a?(Seahorse::Client::NetworkingError)
        return false unless defined?(Aws::Errors::ServiceError) && error.is_a?(Aws::Errors::ServiceError)

        code = error.respond_to?(:code) ? error.code.to_s : error.class.name
        code.match?(/Throttl|SlowDown|InternalError|ServiceUnavailable|RequestTimeout|500|503/i)
      end

      def key(remote_path)
        "#{@prefix}#{remote_path}"
      end

      def strip_prefix(full_key)
        full_key.delete_prefix(@prefix)
      end

      def normalize_prefix(prefix)
        p = prefix.to_s
        return "" if p.empty?

        p.end_with?("/") ? p : "#{p}/"
      end

      def build_client(region, endpoint, access_key_id, secret_access_key, force_path_style)
        options = { region: region || "us-east-1" }
        options[:endpoint] = endpoint if endpoint
        options[:force_path_style] = true if force_path_style || endpoint
        if access_key_id && secret_access_key
          options[:credentials] = Aws::Credentials.new(access_key_id, secret_access_key)
        end
        Aws::S3::Client.new(**options)
      end

      def require_sdk!
        require "aws-sdk-s3"
      rescue LoadError
        raise EnvironmentError,
              "the aws-sdk-s3 gem is required for S3 storage. Add `gem \"aws-sdk-s3\"` to your Gemfile."
      end
    end
  end
end
