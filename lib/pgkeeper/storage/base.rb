# frozen_string_literal: true

module PgKeeper
  module Storage
    # Result of a successful upload.
    UploadResult = Struct.new(:remote_path, :size_bytes, :destination, keyword_init: true)

    # Metadata about a stored object, returned by {Base#list}.
    Entry = Struct.new(:path, :size_bytes, keyword_init: true)

    # The interface every storage backend implements, plus the cross-cutting
    # behavior all of them share: retry-with-backoff on transient errors and
    # post-upload size verification. Subclasses implement the +do_*+ primitives
    # and the {#transient_error?} / {#remote_size} hooks; callers use the public
    # {#upload}/{#download}/{#list}/{#delete}/{#healthcheck} methods.
    #
    # Backends are deliberately independent: one destination failing (a cloud
    # outage) must never stop the others, so the orchestrator uploads to each
    # adapter separately and records status per-destination.
    class Base
      DEFAULT_ATTEMPTS = 3

      attr_reader :logger

      def initialize(logger: PgKeeper.logger, retry_attempts: DEFAULT_ATTEMPTS, retry_base: 0.5)
        @logger = logger
        @retry_attempts = retry_attempts
        @retry_base = retry_base
      end

      # Human-readable destination name, e.g. "local:/var/backups" or
      # "s3://bucket/prefix". Subclasses must override.
      def name
        raise NotImplementedError
      end

      # Upload +local_path+ to +remote_path+, retrying transient failures and
      # verifying the stored size matches. Returns an {UploadResult}.
      def upload(local_path, remote_path)
        size = File.size(local_path)
        with_retries("upload #{remote_path}") { do_upload(local_path, remote_path) }
        verify_upload!(remote_path, size)
        logger.debug("uploaded", destination: name, remote: remote_path, bytes: size)
        UploadResult.new(remote_path: remote_path, size_bytes: size, destination: name)
      rescue StorageError
        raise
      rescue StandardError => e
        raise StorageError.new("#{name}: upload of #{remote_path} failed: #{e.message}", destination: name)
      end

      # Download +remote_path+ to +local_path+. Returns +local_path+.
      def download(remote_path, local_path)
        with_retries("download #{remote_path}") { do_download(remote_path, local_path) }
        local_path
      rescue StorageError
        raise
      rescue StandardError => e
        raise StorageError.new("#{name}: download of #{remote_path} failed: #{e.message}", destination: name)
      end

      # List stored objects under +prefix+ as an array of {Entry}.
      def list(prefix = "")
        with_retries("list #{prefix}") { do_list(prefix) }
      end

      # Delete +remote_path+.
      def delete(remote_path)
        with_retries("delete #{remote_path}") { do_delete(remote_path) }
      end

      # Cheap liveness/permission probe. Returns true, or raises {StorageError}.
      def healthcheck
        raise NotImplementedError
      end

      private

      # Retry a block on transient errors with exponential backoff + jitter.
      def with_retries(label)
        attempt = 0
        begin
          attempt += 1
          yield
        rescue StandardError => e
          raise unless transient_error?(e) && attempt < @retry_attempts

          delay = backoff(attempt)
          logger.warn("retrying storage op", destination: name, op: label, attempt: attempt, delay_s: delay.round(3),
                                             error: e.message)
          pause(delay)
          retry
        end
      end

      def backoff(attempt)
        (@retry_base * (2**(attempt - 1))) + (rand * @retry_base)
      end

      # Overridable so tests don't actually sleep.
      def pause(seconds)
        sleep(seconds)
      end

      # After upload, confirm the backend reports the same byte count we sent. If
      # the backend can't report a size, {#remote_size} returns nil and we skip.
      def verify_upload!(remote_path, expected_size)
        actual = remote_size(remote_path)
        return if actual.nil? || actual == expected_size

        raise StorageError.new(
          "#{name}: uploaded size mismatch for #{remote_path} (sent #{expected_size}, stored #{actual})",
          destination: name
        )
      end

      # --- primitives for subclasses ---------------------------------------

      def do_upload(_local_path, _remote_path) = raise(NotImplementedError)
      def do_download(_remote_path, _local_path) = raise(NotImplementedError)
      def do_list(_prefix) = raise(NotImplementedError)
      def do_delete(_remote_path) = raise(NotImplementedError)

      # Size of a stored object in bytes, or nil if the backend can't report it.
      def remote_size(_remote_path) = nil

      # Whether an error is worth retrying (network blips, throttling, 5xx).
      def transient_error?(_error) = false
    end
  end
end
