# frozen_string_literal: true

require "mail"

module PgKeeper
  module Notify
    # Email notifications over SMTP+TLS via the +mail+ gem. Sends a multipart
    # message with both HTML and plain-text parts so it renders everywhere.
    #
    # Failure alerts are the point of this: +on: [failure]+ is the recommended
    # minimum. Success mails are optional and can be enabled alongside.
    class Email < Base
      def self.from_config(cfg, logger)
        return nil unless cfg

        new(
          to: Array(cfg["to"]),
          from: cfg["from"] || "pgkeeper@localhost",
          smtp: symbolize(cfg["smtp"] || {}),
          events: cfg["on"] || cfg["true"] || %w[failure],
          logger: logger
        )
      end

      def self.symbolize(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def initialize(to:, from:, smtp:, events:, logger: PgKeeper.logger)
        super(events: events, logger: logger)
        @to = to
        @from = from
        @smtp = smtp
      end

      def deliver(summary)
        raise Error, "email notifications need at least one `to` address" if @to.empty?

        mail = build_mail(summary)
        mail.delivery_method(:smtp, smtp_settings) if @smtp[:host]
        mail.deliver
      end

      private

      def build_mail(summary)
        from_addr = @from
        to_addrs = @to
        # The Mail.new block runs in the message's context, but locals from here
        # remain in scope via the closure.
        Mail.new do
          from     from_addr
          to       to_addrs
          subject  summary.subject
          text_part { body summary.to_text }
          html_part do
            content_type "text/html; charset=UTF-8"
            body summary.to_html
          end
        end
      end

      def smtp_settings
        {
          address: @smtp[:host], port: @smtp[:port] || 587,
          user_name: @smtp[:user_name], password: @smtp[:password],
          authentication: @smtp[:authentication] || :plain,
          enable_starttls_auto: @smtp.fetch(:enable_starttls_auto, true),
          domain: @smtp[:domain]
        }.compact
      end
    end
  end
end
