# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module PgKeeper
  module Storage
    class SharePoint < Base
      # Fetches Microsoft Graph access tokens with the OAuth2 client-credentials
      # grant — no SDK. The app-only token is minted from the tenant's app
      # registration (`client_id` + `client_secret`) and cached until shortly
      # before its reported expiry, then re-minted — Graph tokens last ~1h, and
      # a large upload can outlive one.
      class AppToken
        AUTHORITY = "https://login.microsoftonline.com"
        SCOPE = "https://graph.microsoft.com/.default"
        # Refresh this many seconds before the reported expiry so a token never
        # goes stale mid-operation.
        TOKEN_REFRESH_MARGIN = 60

        def initialize(tenant_id:, client_id:, client_secret:, timeout: 60)
          missing = { tenant_id: tenant_id, client_id: client_id, client_secret: client_secret }
                    .select { |_, value| value.to_s.empty? }.keys
          raise ConfigError, "sharepoint storage requires #{missing.join(', ')}" unless missing.empty?

          @tenant_id = tenant_id
          @client_id = client_id
          @client_secret = client_secret
          @timeout = timeout
          @token = nil
        end

        def token
          request_token if @token.nil? || Time.now >= @refresh_at
          @token
        end

        private

        def request_token
          uri = URI("#{AUTHORITY}/#{@tenant_id}/oauth2/v2.0/token")
          request = Net::HTTP::Post.new(uri)
          request.set_form_data("client_id" => @client_id, "client_secret" => @client_secret,
                                "scope" => SCOPE, "grant_type" => "client_credentials")
          response = perform(uri, request)
          code = response.code.to_i
          unless code.between?(200, 299)
            raise StorageError, "sharepoint token request failed: HTTP #{code} #{response.body}"
          end

          body = JSON.parse(response.body)
          @refresh_at = Time.now + body["expires_in"].to_i - TOKEN_REFRESH_MARGIN
          @token = body.fetch("access_token")
        end

        def perform(uri, request)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = @timeout
          http.read_timeout = @timeout
          http.start { |conn| conn.request(request) }
        end
      end
    end
  end
end
