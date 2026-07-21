# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

module PgKeeper
  # Restores a backup, and provides the shared "materialize" step (reverse the
  # compression + encryption pipeline back to a usable dump) that verification
  # also relies on.
  #
  # Restores are deliberately CLI-only and guarded: restoring over an existing
  # non-empty database requires +force: true+, because it is destructive and a
  # 3 a.m. operator should have to mean it.
  class Restorer
    Result = Struct.new(:database, :target, :label, :status, :detail, keyword_init: true) do
      def ok? = status == :ok
    end

    def initialize(config, logger: PgKeeper.logger)
      @config = config
      @logger = logger
      @encryptor = Crypto.build(@config.encryption)
    end

    # Download +artifact+ from +adapter+ and reverse its encryption and
    # compression into +workdir+. Returns { path:, format: } where +path+ is a
    # file (custom/plain) or directory (directory format) ready for pg_restore.
    def materialize(artifact, adapter, workdir)
      stored = File.join(workdir, File.basename(artifact.remote_path))
      adapter.download(artifact.remote_path, stored)

      decrypted = reverse_encryption(artifact, stored)
      reverse_compression(artifact, decrypted, workdir)
    end

    # Restore a backup set's primary dump into a target database.
    def restore(artifact, adapter, target_db, connection, force: false, jobs: nil)
      FileUtils.mkdir_p(@config.workdir)
      Dir.mktmpdir("pgkeeper-restore-", @config.workdir) do |workdir|
        materialized = materialize(artifact, adapter, workdir)
        guard_target!(connection, target_db, force)
        run_restore(materialized, target_db, connection, jobs, force)
      end
    end

    private

    def reverse_encryption(artifact, path)
      return path if artifact.encryption.nil? || artifact.encryption == "none"

      if @encryptor.nil?
        raise Error, "artifact #{File.basename(path)} is encrypted (#{artifact.encryption}) " \
                     "but no encryption is configured to decrypt it"
      end

      dest = strip_suffix(path, @encryptor.extension)
      @encryptor.decrypt(path, dest)
      dest
    end

    def reverse_compression(artifact, path, workdir)
      case artifact.compression
      when nil, "none"
        { path: path, format: artifact.dump_format }
      when "zip"
        reverse_zip(artifact, path, workdir)
      else
        dest = strip_suffix(path, Compress.for(artifact.compression).extension)
        Compress.for(artifact.compression).decompress(path, dest)
        { path: dest, format: artifact.dump_format }
      end
    end

    def reverse_zip(artifact, path, workdir)
      if artifact.dump_format == "directory"
        dir = File.join(workdir, "#{File.basename(path, '.*')}.restored")
        Compress::Zip.new.decompress_tree(path, dir)
        { path: dir, format: "directory" }
      else
        dest = strip_suffix(path, "zip")
        Compress::Zip.new.decompress(path, dest)
        { path: dest, format: artifact.dump_format }
      end
    end

    # Refuse to clobber a non-empty database unless the caller forces it.
    def guard_target!(connection, target_db, force)
      env = connection.libpq_env.merge("PGDATABASE" => target_db)
      out, status = Open3.capture2e(env, "psql", "-XtAc", <<~SQL)
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
      SQL
      return unless status.success?

      table_count = out.strip.to_i
      return if table_count.zero? || force

      raise Error, "target database #{target_db.inspect} already has #{table_count} table(s); " \
                   "pass --force to overwrite it"
    end

    def run_restore(materialized, target_db, connection, jobs, force)
      env = connection.libpq_env.merge("PGDATABASE" => target_db)
      case materialized[:format]
      when "plain"
        run!(env, "psql", "--no-password", "-v", "ON_ERROR_STOP=0", "-f", materialized[:path])
      else # custom or directory
        args = ["--no-password", "--dbname=#{target_db}"]
        # --clean --if-exists drops existing objects first, so a forced restore
        # over a non-empty database doesn't collide with what's already there.
        args += ["--clean", "--if-exists"] if force
        args << "--jobs=#{jobs}" if jobs && materialized[:format] == "directory"
        run!(env, "pg_restore", *args, materialized[:path])
      end
      @logger.info("restore complete", target: target_db, format: materialized[:format])
    end

    def run!(env, tool, *)
      _out, err, status = Open3.capture3(env, tool, *)
      return if status.success?

      raise Error, "#{tool} failed (#{status.exitstatus}): #{err.strip}"
    rescue Errno::ENOENT
      raise EnvironmentError, "#{tool} not found on PATH"
    end

    def strip_suffix(path, ext)
      suffix = ".#{ext}"
      path.end_with?(suffix) ? path.delete_suffix(suffix) : "#{path}.plain"
    end
  end
end
