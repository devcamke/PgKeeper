# frozen_string_literal: true

require "fileutils"

module PgKeeper
  module Storage
    # In-memory storage backend. Not for production — it exists so tests can
    # exercise the orchestrator's fan-out and per-destination behavior without
    # touching disk or the network, and as a third implementation that must pass
    # the same storage contract as Local and S3.
    class Memory < Base
      attr_reader :store

      def initialize(**opts)
        super
        @store = {}
      end

      def name = "memory"
      def healthcheck = true

      private

      def do_upload(local_path, remote_path)
        @store[remote_path] = File.binread(local_path)
      end

      def do_download(remote_path, local_path)
        data = @store[remote_path]
        raise StorageError.new("memory: #{remote_path} not found", destination: name) if data.nil?

        FileUtils.mkdir_p(File.dirname(local_path))
        File.binwrite(local_path, data)
      end

      def do_delete(remote_path)
        @store.delete(remote_path)
      end

      def do_list(prefix)
        @store.keys.select { |k| k.start_with?(prefix) }.sort.map do |k|
          Entry.new(path: k, size_bytes: @store[k].bytesize)
        end
      end

      def remote_size(remote_path)
        @store[remote_path]&.bytesize
      end
    end
  end
end
