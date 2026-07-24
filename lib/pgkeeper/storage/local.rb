# frozen_string_literal: true

require "fileutils"
require "open3"

module PgKeeper
  module Storage
    # Local-filesystem storage. Copies artifacts into a target directory with
    # restrictive permissions (0600), an atomic temp-then-rename so a reader
    # never sees a half-written file, and an fsync so the bytes are actually on
    # disk before we call the upload done.
    class Local < Base
      attr_reader :root

      def initialize(root:, min_free_bytes: 0, **)
        super(**)
        @root = File.expand_path(root)
        @min_free_bytes = min_free_bytes
      end

      def default_name = "local:#{@root}"

      def healthcheck
        FileUtils.mkdir_p(@root)
        raise StorageError.new("#{name}: not writable", destination: name) unless File.writable?(@root)

        true
      end

      private

      def do_upload(local_path, remote_path)
        target = absolute(remote_path)
        FileUtils.mkdir_p(File.dirname(target))
        check_space!(File.dirname(target), File.size(local_path))

        tmp = "#{target}.#{Process.pid}.tmp"
        FileUtils.cp(local_path, tmp)
        File.chmod(0o600, tmp)
        fsync(tmp)
        File.rename(tmp, target)
      end

      def do_download(remote_path, local_path)
        source = absolute(remote_path)
        raise StorageError.new("#{name}: #{remote_path} not found", destination: name) unless File.file?(source)

        FileUtils.mkdir_p(File.dirname(local_path))
        FileUtils.cp(source, local_path)
      end

      def do_delete(remote_path)
        target = absolute(remote_path)
        File.delete(target) if File.file?(target)
      end

      def do_list(prefix)
        base = absolute(prefix)
        escaped = glob_escape(base)
        pattern = File.directory?(base) ? File.join(escaped, "**", "*") : "#{escaped}*"
        Dir.glob(pattern).select { |p| File.file?(p) }.sort.map do |path|
          Entry.new(path: relative(path), size_bytes: File.size(path))
        end
      end

      # Dir.glob treats  * ? [ ] { } \  as pattern syntax; the root and prefix
      # are literal paths, not patterns.
      def glob_escape(path)
        path.gsub(/[\\{}\[\]*?]/) { |char| "\\#{char}" }
      end

      def remote_size(remote_path)
        target = absolute(remote_path)
        File.file?(target) ? File.size(target) : nil
      end

      def absolute(remote_path)
        File.join(@root, remote_path)
      end

      def relative(path)
        path.delete_prefix("#{@root}/")
      end

      def fsync(path)
        File.open(path, "r") do |f|
          f.fsync
        rescue StandardError
          # Some filesystems don't support fsync on a file opened read-only; the
          # copy still happened, so this is best-effort durability.
          nil
        end
      end

      def check_space!(dir, needed)
        return if @min_free_bytes.zero? && needed.zero?

        free = free_bytes(dir)
        return if free.nil?

        return unless free < needed + @min_free_bytes

        raise StorageError.new("#{name}: insufficient space in #{dir} (#{free} free, need #{needed})",
                               destination: name)
      end

      def free_bytes(path)
        out, status = Open3.capture2("df", "-Pk", path)
        return nil unless status.success?

        Integer(out.lines[1].split[3]) * 1024
      rescue StandardError
        nil
      end
    end
  end
end
