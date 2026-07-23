# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

module PgKeeper
  module PITR
    # Ships completed WAL segments to storage and fetches them back for restore —
    # the continuous half of PITR that pairs with a base backup. Each segment
    # rides the same conveyor as everything else: compress → encrypt → manifest →
    # fan out. Fetch reverses it (download → decrypt → decompress).
    #
    # Two archive entry points, one storage layout:
    #   * {#archive_file} — one segment, for the server's
    #     `archive_command = 'pgkeeper wal archive-file --cluster N %p %f'`.
    #   * {#archive_spool} — every completed segment in a `pg_receivewal` spool
    #     directory, removing each once it is safely on every destination.
    #
    # Stage 2 of Phase 12 (docs/PITR-DESIGN.md). The long-lived `pg_receivewal`
    # supervisor is a separate concern; this is the data path it feeds.
    class WalArchiver
      # A completed WAL segment file name: 24 uppercase hex chars (timeline + log
      # + segment). Deliberately excludes `.partial` (still filling), backup-label
      # / history files, and the `archive_status` directory.
      SEGMENT = /\A[0-9A-F]{24}\z/

      def initialize(config, cluster, logger: PgKeeper.logger, clock: Time)
        @config = config
        @cluster = cluster
        @logger = logger
        @clock = clock
        @adapters = Storage.build_all(@config.storage, logger: @logger)
        @encryptor = Crypto.build(@config.encryption)
        @compression = @config.compression
      end

      # Archive one segment file. Returns true only when every destination stored
      # it (so an archive_command wrapper can exit non-zero and let Postgres retry).
      def archive_file(path, name = File.basename(path))
        raise Error, "not a WAL segment name: #{name.inspect}" unless name.match?(SEGMENT)
        raise Error, "WAL segment not found: #{path}" unless File.file?(path)

        Dir.mktmpdir(".pgkeeper-wal-") do |tmp|
          processed, compression, encryption = process(path, name, tmp)
          write_manifest(processed, name, compression, encryption)
          upload_segment(processed, name).all?
        end
      end

      # Drain a `pg_receivewal` spool: archive every completed segment, then delete
      # the local copy once it is safely on every destination. Returns the number
      # archived. A segment that fails to reach all destinations is kept (retried
      # next drain), never lost.
      def archive_spool(spool_dir)
        Dir.children(spool_dir).grep(SEGMENT).sort.count do |name|
          path = File.join(spool_dir, name)
          archived = archive_file(path, name)
          File.unlink(path) if archived
          archived
        end
      end

      # Fetch one segment to +dest+, reversing encryption + compression, by trying
      # each destination until one has it. Returns true; raises if no destination
      # holds the segment (so a restore_command fails loudly on a gap).
      def fetch(name, dest)
        Dir.mktmpdir(".pgkeeper-wal-fetch-") do |tmp|
          adapter, meta = locate(name, tmp)
          raise Error, "WAL segment #{name} not found on any destination" if adapter.nil?

          downloaded = File.join(tmp, "segment")
          adapter.download(remote_path(name), downloaded)
          reverse(downloaded, meta, dest)
        end
        dest
      end

      private

      # Compress then (optionally) encrypt into +tmp+; returns the processed path
      # plus the compression/encryption names recorded in the manifest.
      def process(path, name, tmp)
        compressor = Compress.for(@compression)
        suffix = compressor.extension ? ".#{compressor.extension}" : ""
        compressed = File.join(tmp, "#{name}#{suffix}")
        compressor.compress(path, compressed)
        return [compressed, @compression, "none"] if @encryptor.nil?

        encrypted = "#{compressed}.#{@encryptor.extension}"
        @encryptor.encrypt(compressed, encrypted)
        [encrypted, @compression, @encryptor.name]
      end

      def write_manifest(processed, name, compression, encryption)
        now = @clock.now.utc.iso8601
        attrs = {
          "kind" => "wal", "database" => @cluster.name, "segment" => name, "timeline" => timeline_of(name),
          "compression" => compression, "encryption" => encryption, "started_at" => now, "finished_at" => now
        }
        Manifest.for_artifact(processed, attrs).tap { |m| m.write(Manifest.path_for(processed)) }
      end

      # Upload the processed segment + its manifest to every destination,
      # returning one boolean per destination (true = stored there).
      def upload_segment(processed, name)
        remote = remote_path(name)
        @adapters.map do |adapter|
          adapter.upload(processed, remote)
          adapter.upload(Manifest.path_for(processed), Manifest.path_for(remote))
          @logger.debug("archived wal", destination: adapter.name, segment: name)
          true
        rescue StorageError => e
          @logger.error("wal destination failed", destination: adapter.name, segment: name, error: e.message)
          false
        end
      end

      # Find the first destination holding this segment. Downloading the small
      # manifest sidecar doubles as the existence probe and yields the metadata
      # needed to reverse the pipeline.
      def locate(name, tmp)
        remote = Manifest.path_for(remote_path(name))
        @adapters.each do |adapter|
          local = File.join(tmp, "manifest.json")
          adapter.download(remote, local)
          return [adapter, JSON.parse(File.read(local))]
        rescue StorageError
          next
        end
        [nil, nil]
      end

      def reverse(downloaded, meta, dest)
        decrypted = downloaded
        encryption = meta["encryption"]
        if encryption && encryption != "none"
          raise Error, "segment is #{encryption}-encrypted but no encryption is configured" if @encryptor.nil?

          decrypted = "#{downloaded}.decrypted"
          @encryptor.decrypt(downloaded, decrypted)
        end
        Compress.for(meta["compression"] || "none").decompress(decrypted, dest)
      end

      def remote_path(name) = "#{@cluster.slug}/wal/#{name}"
      def timeline_of(name) = name[0, 8].to_i(16)
    end
  end
end
