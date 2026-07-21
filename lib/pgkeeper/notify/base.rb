# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module PgKeeper
  # Notifiers tell humans the state of their backups. Every backend shares two
  # rules: it only fires for the events it's configured for (+on: [success,
  # failure]+), and a notifier blowing up must NEVER take down the backup —
  # notification errors are logged, never raised.
  module Notify
    # Tiny Net::HTTP wrapper for the webhook and dead-man's-switch notifiers, so
    # neither pulls in a heavier HTTP dependency.
    module Http
      module_function

      def post_json(url, payload, timeout: 10)
        request(url, timeout: timeout) do |uri|
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(payload)
          req
        end
      end

      def get(url, timeout: 10)
        request(url, timeout: timeout) { |uri| Net::HTTP::Get.new(uri) }
      end

      def request(url, timeout:)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        response = http.request(yield(uri))
        code = response.code.to_i
        raise Error, "HTTP #{code} from #{uri.host}" unless code.between?(200, 299)

        response
      end
    end

    class Base
      attr_reader :events

      # +events+ is the set of run outcomes this notifier fires on
      # (:success/:failure).
      def initialize(events:, logger: PgKeeper.logger)
        @events = Array(events).map(&:to_sym)
        @logger = logger
      end

      # Short name for logs.
      def name = self.class.name.split("::").last.downcase

      def wants?(summary)
        @events.include?(summary.event)
      end

      # Fire if this notifier cares about the run's outcome. Swallows and logs
      # any delivery error so the backup run is never affected.
      def notify(summary)
        return false unless wants?(summary)

        deliver(summary)
        @logger.debug("notification sent", via: name, event: summary.event)
        true
      rescue StandardError => e
        @logger.error("notifier failed (non-fatal)", via: name, error: e.message)
        false
      end

      # Subclasses implement the actual delivery.
      def deliver(_summary)
        raise NotImplementedError
      end
    end
  end
end
