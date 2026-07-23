# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "time"

module PgKeeper
  module PITR
    # Point-in-Time Recovery (Phase 12, Stage 4): stage a recovery-ready data
    # directory from a base backup + archived WAL, targeted at a moment you
    # choose (time / LSN / named restore point / latest).
    #
    # It picks the right base, materializes it into the target data directory,
    # and writes the recovery configuration — a +restore_command+ that pulls each
    # WAL segment through {WalArchiver} (decrypting/decompressing it), the
    # recovery target, and +recovery.signal+. Postgres does the actual replay
    # when the operator starts the server on the staged directory; driving a
    # live server is deliberately left to that explicit step, not done silently
    # to the host by a backup tool.
    #
    # Destructive and guarded: it refuses a non-empty target directory without
    # +force:+, and never touches a directory with a running server.
    class Restore
      # What to recover to. +type+ is :time / :lsn / :name / :latest.
      Target = Struct.new(:type, :value, keyword_init: true) do
        def describe
          if type == :latest
            "the latest archived WAL"
          else
            "#{type} #{value.respond_to?(:iso8601) ? value.iso8601 : value}"
          end
        end
      end

      Result = Struct.new(:cluster, :base_label, :data_dir, :target, keyword_init: true)

      def initialize(config, cluster, logger: PgKeeper.logger)
        @config = config
        @cluster = cluster
        @logger = logger
        @encryptor = Crypto.build(@config.encryption)
        @adapters = Storage.build_all(@config.storage, logger: @logger)
      end

      def run(target:, data_dir:, force: false, action: "promote", bin: "pgkeeper")
        adapter, base = select_base(target)
        raise Error, "no base backup precedes #{target.describe} for cluster #{@cluster.name}" if base.nil?

        guard!(data_dir, force)
        FileUtils.mkdir_p(data_dir)
        materialize(base, adapter, data_dir)
        write_recovery(data_dir, target, action, bin)
        @logger.info("staged PITR recovery", cluster: @cluster.name, base: base.timestamp&.iso8601,
                                             data_dir: data_dir, target: target.describe)
        Result.new(cluster: @cluster.name, base_label: base_label(base), data_dir: data_dir, target: target)
      end

      # Choose the newest base at or before the target, from [adapter, base]
      # candidate pairs. Pure — the adapter rides along so {#run} can fetch it.
      def self.pick(candidates, target)
        sorted = candidates.sort_by { |(_adapter, base)| base.timestamp }
        case target.type
        when :time
          sorted.select { |(_adapter, base)| base.timestamp && base.timestamp <= target.value }.last
        when :lsn
          limit = Wal.lsn_to_int(target.value)
          sorted.select { |(_adapter, base)| base_lsn(base) && limit && base_lsn(base) <= limit }.last
        else # :latest / :name — the newest base; recovery replays forward to the point
          sorted.last
        end
      end

      def self.base_lsn(base) = Wal.lsn_to_int(base.start_lsn)

      def select_base(target)
        self.class.pick(discover_bases, target) || [nil, nil]
      end

      private

      # Every cataloged base for this cluster, paired with a destination that has
      # it (deduplicated across destinations by remote path).
      def discover_bases
        seen = {}
        @adapters.flat_map do |adapter|
          Catalog.new(adapter).artifacts(database: @cluster.name).select { |a| a.kind == "base" }.filter_map do |base|
            next if seen[base.remote_path]

            seen[base.remote_path] = true
            [adapter, base]
          end
        rescue EnvironmentError, StorageError
          []
        end
      end

      def guard!(data_dir, force)
        return unless File.exist?(data_dir)

        if File.exist?(File.join(data_dir, "postmaster.pid"))
          raise Error, "#{data_dir} has a running server (postmaster.pid present)"
        end
        return if Dir.empty?(data_dir) || force

        raise Error, "target data dir #{data_dir} is not empty (use --force to overwrite)"
      end

      # Fetch the base artifact, reverse encryption + the tree-zip packaging, and
      # extract base.tar into the target data directory.
      def materialize(base, adapter, data_dir)
        Dir.mktmpdir("pgkeeper-base-restore-", ensure_workdir) do |tmp|
          stored = File.join(tmp, "base.artifact")
          adapter.download(base.remote_path, stored)
          decrypted = reverse_encryption(base, stored)

          extracted = File.join(tmp, "extracted")
          Compress::Zip.new.decompress_tree(decrypted, extracted)
          tar = File.join(extracted, "base.tar")
          raise Error, "base.tar not found in base artifact #{File.basename(base.remote_path)}" unless File.file?(tar)

          extract_tar(tar, data_dir)
        end
      end

      def reverse_encryption(base, path)
        return path if base.encryption.nil? || base.encryption == "none"
        raise Error, "base is #{base.encryption}-encrypted but no encryption is configured" if @encryptor.nil?

        dest = "#{path}.decrypted"
        @encryptor.decrypt(path, dest)
        dest
      end

      def extract_tar(tar, data_dir)
        _out, err, status = Subprocess.capture3({}, "tar", "-xf", tar, "-C", data_dir,
                                                timeout: @config.timeout(:restore), label: "tar")
        raise Error, "extracting base.tar failed: #{err.to_s.strip.lines.last}" unless status.success?
      end

      # Append the recovery settings and drop recovery.signal, so a plain
      # `pg_ctl start` on the directory enters archive recovery to the target.
      def write_recovery(data_dir, target, action, bin)
        conf = ["# added by pgkeeper restore",
                %(restore_command = '#{bin} wal fetch --cluster #{@cluster.name} --config #{@config.source} "%f" "%p"'),
                recovery_target_line(target),
                %(recovery_target_action = '#{action}')].compact.join("\n")
        File.open(File.join(data_dir, "postgresql.auto.conf"), "a") { |f| f.puts("\n#{conf}") }
        FileUtils.touch(File.join(data_dir, "recovery.signal"))
      end

      # :latest returns nil — no target line means replay to the end of WAL.
      # Postgres wants a space-separated timestamp with a numeric offset, not the
      # ISO-8601 "T…Z" form (which it rejects as invalid).
      def recovery_target_line(target)
        case target.type
        when :time then %(recovery_target_time = '#{target.value.getutc.strftime('%Y-%m-%d %H:%M:%S+00')}')
        when :lsn then %(recovery_target_lsn = '#{target.value}')
        when :name then %(recovery_target_name = '#{target.value}')
        end
      end

      def base_label(base) = base.timestamp&.strftime("%Y-%m-%dT%H%M%SZ") || File.basename(base.remote_path)

      def ensure_workdir
        FileUtils.mkdir_p(@config.workdir)
        @config.workdir
      end
    end
  end
end
