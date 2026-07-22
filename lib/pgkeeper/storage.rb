# frozen_string_literal: true

require "pgkeeper/storage/base"
require "pgkeeper/storage/local"
require "pgkeeper/storage/memory"
require "pgkeeper/storage/s3"
require "pgkeeper/storage/dropbox"
require "pgkeeper/storage/google_drive"

module PgKeeper
  # Storage backends and the factory that builds them from config.
  #
  # A run fans a backup out to every configured target. Building the adapters is
  # separate from using them, so config errors surface up front.
  module Storage
    TYPES = %w[local s3 dropbox google_drive memory].freeze

    module_function

    # Build a single adapter from one +storage:+ entry.
    def build(target, logger: PgKeeper.logger)
      type = target["type"].to_s
      case type
      when "local"
        Local.new(root: target.fetch("path"), logger: logger)
      when "s3"
        build_s3(target, logger)
      when "dropbox"
        build_dropbox(target, logger)
      when "google_drive"
        build_google_drive(target, logger)
      when "memory"
        Memory.new(logger: logger)
      else
        raise ConfigError, "unknown storage type: #{type.inspect} (expected one of #{TYPES.join(', ')})"
      end
    end

    # Build every configured adapter, in order.
    def build_all(targets, logger: PgKeeper.logger)
      Array(targets).map { |t| build(t, logger: logger) }
    end

    def build_s3(target, logger)
      S3.new(
        bucket: target.fetch("bucket"),
        region: target["region"],
        prefix: target["prefix"].to_s,
        endpoint: target["endpoint"],
        access_key_id: target["access_key_id"],
        secret_access_key: target["secret_access_key"],
        force_path_style: !!target["force_path_style"],
        logger: logger
      )
    end

    def build_dropbox(target, logger)
      Dropbox.new(
        root: target["root"].to_s,
        access_token: target["access_token"],
        refresh_token: target["refresh_token"],
        app_key: target["app_key"],
        app_secret: target["app_secret"],
        logger: logger
      )
    end

    def build_google_drive(target, logger)
      GoogleDrive.new(
        folder_id: target["folder_id"],
        credentials_json: target["credentials_json"],
        credentials_file: target["credentials_file"],
        logger: logger
      )
    end
  end
end
