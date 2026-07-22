# frozen_string_literal: true

require "pgkeeper/storage/base"
require "pgkeeper/storage/local"
require "pgkeeper/storage/memory"
require "pgkeeper/storage/s3"
require "pgkeeper/storage/dropbox"
require "pgkeeper/storage/google_drive"
require "pgkeeper/storage/sharepoint"

module PgKeeper
  # Storage backends and the factory that builds them from config.
  #
  # A run fans a backup out to every configured target. Building the adapters is
  # separate from using them, so config errors surface up front.
  module Storage
    TYPES = %w[local s3 dropbox google_drive sharepoint memory].freeze

    module_function

    # Build a single adapter from one +storage:+ entry. A friendly +name:+ on
    # the entry becomes the adapter's {Base#name}, so run history and
    # destination selection speak the operator's vocabulary ("nas", "gdrive")
    # rather than the backend's internal path.
    def build(target, logger: PgKeeper.logger)
      adapter = build_adapter(target, logger)
      name = target["name"].to_s
      adapter.display_name = name unless name.strip.empty?
      adapter
    end

    # Build every configured adapter, in order.
    def build_all(targets, logger: PgKeeper.logger)
      Array(targets).map { |t| build(t, logger: logger) }
    end

    # Resolve a list of destination selectors to the subset of +targets+ they
    # name. Each selector matches a target by its friendly +name:+ or by its
    # +type:+. An empty/nil selector list means "every destination" (the
    # default fan-out). A selector that matches nothing raises, listing what is
    # available — a typo must fail loudly, never silently skip a destination.
    def select(targets, selectors)
      wanted = Array(selectors).flat_map { |s| s.to_s.split(",") }.map(&:strip).reject(&:empty?)
      return Array(targets) if wanted.empty?

      chosen = []
      wanted.each do |selector|
        matches = Array(targets).select { |t| t["name"].to_s == selector || t["type"].to_s == selector }
        if matches.empty?
          raise Error, "unknown destination #{selector.inspect}; available: #{tokens(targets).join(', ')}"
        end

        chosen.concat(matches)
      end
      chosen.uniq
    end

    # The tokens (friendly name, else type) that {.select} accepts, in config
    # order — handy for building pickers and error messages.
    def tokens(targets)
      Array(targets).map { |t| t["name"].to_s.empty? ? t["type"].to_s : t["name"].to_s }
    end

    def build_adapter(target, logger)
      case (type = target["type"].to_s)
      when "local"
        Local.new(root: target.fetch("path"), logger: logger)
      when "s3"
        build_s3(target, logger)
      when "dropbox"
        build_dropbox(target, logger)
      when "google_drive"
        build_google_drive(target, logger)
      when "sharepoint"
        build_sharepoint(target, logger)
      when "memory"
        Memory.new(logger: logger)
      else
        raise ConfigError, "unknown storage type: #{type.inspect} (expected one of #{TYPES.join(', ')})"
      end
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

    def build_sharepoint(target, logger)
      SharePoint.new(
        drive_id: target["drive_id"],
        tenant_id: target["tenant_id"],
        client_id: target["client_id"],
        client_secret: target["client_secret"],
        root: target["root"].to_s,
        logger: logger
      )
    end
  end
end
