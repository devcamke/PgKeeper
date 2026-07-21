# frozen_string_literal: true

module PgKeeper
  module Notify
    # Dead-man's switch: pings a monitoring URL (healthchecks.io, Uptime Kuma,
    # Cronitor, ...) when a run succeeds. This catches the worst failure mode of
    # all — cron silently not running the backup at all. An email system can't
    # tell you about a run that never happened; a *missing* ping can.
    #
    # By default it only fires on success (so the monitor alarms when the
    # expected ping doesn't arrive). If a +fail_url+ is set, failures ping that
    # endpoint too for faster signal.
    class Healthcheck < Base
      def self.from_config(cfg, logger)
        return nil unless cfg && cfg["url"]

        events = cfg["fail_url"] ? %w[success failure] : %w[success]
        new(url: cfg["url"], fail_url: cfg["fail_url"], events: cfg["on"] || cfg["true"] || events, logger: logger)
      end

      def initialize(url:, events:, fail_url: nil, logger: PgKeeper.logger)
        super(events: events, logger: logger)
        @url = url
        @fail_url = fail_url
      end

      def deliver(summary)
        target = summary.success? ? @url : (@fail_url || @url)
        Http.get(target)
      end
    end
  end
end
