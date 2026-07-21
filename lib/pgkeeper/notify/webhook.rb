# frozen_string_literal: true

module PgKeeper
  module Notify
    # Generic JSON webhook — POSTs the run summary to a URL. Works as-is for
    # anything that accepts a JSON body; for Slack/Teams/Discord, point it at an
    # incoming-webhook URL and set +format: slack+ for a chat-friendly payload.
    class Webhook < Base
      def self.from_config(cfg, logger)
        return nil unless cfg && cfg["url"]

        new(url: cfg["url"], format: cfg["format"], events: cfg["on"] || cfg["true"] || %w[success failure],
            logger: logger)
      end

      def initialize(url:, events:, format: nil, logger: PgKeeper.logger)
        super(events: events, logger: logger)
        @url = url
        @format = format
      end

      def deliver(summary)
        Http.post_json(@url, payload_for(summary))
      end

      private

      def payload_for(summary)
        return { "text" => slack_text(summary) } if @format.to_s == "slack"

        summary.to_payload
      end

      def slack_text(summary)
        icon = summary.success? ? ":white_check_mark:" : ":rotating_light:"
        "#{icon} #{summary.subject}"
      end
    end
  end
end
