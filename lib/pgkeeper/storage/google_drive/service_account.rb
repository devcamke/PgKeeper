# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"

module PgKeeper
  module Storage
    class GoogleDrive < Base
      # Turns a Google service-account key into short-lived Drive access tokens
      # using the JWT-bearer grant — no googleauth gem. A signed JWT (RS256 over
      # the account's private key) is exchanged at the token endpoint; the
      # resulting access token is cached until shortly before its reported
      # expiry, then re-minted — tokens last ~1h, and a large upload can outlive
      # one.
      class ServiceAccount
        TOKEN_URI = "https://oauth2.googleapis.com/token"
        SCOPE = "https://www.googleapis.com/auth/drive"
        GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"
        # Refresh this many seconds before the reported expiry so a token never
        # goes stale mid-operation.
        TOKEN_REFRESH_MARGIN = 60

        def self.from_config(json:, file:, timeout: 60)
          creds = load_credentials(json, file)
          new(client_email: creds.fetch("client_email"),
              private_key: OpenSSL::PKey::RSA.new(creds.fetch("private_key")),
              timeout: timeout)
        rescue KeyError => e
          raise ConfigError, "google_drive credentials missing #{e.key} field"
        rescue OpenSSL::PKey::RSAError => e
          raise ConfigError, "google_drive credentials have an unreadable private_key: #{e.message}"
        end

        def self.load_credentials(json, file)
          raw = if !json.to_s.empty?
                  json
                elsif file
                  File.read(file)
                else
                  raise ConfigError, "google_drive storage requires `credentials_json` or `credentials_file`"
                end
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise ConfigError, "google_drive credentials are not valid JSON: #{e.message}"
        end

        def initialize(client_email:, private_key:, timeout: 60)
          @client_email = client_email
          @private_key = private_key
          @timeout = timeout
          @access_token = nil
        end

        def access_token
          request_token if @access_token.nil? || Time.now >= @refresh_at
          @access_token
        end

        private

        def request_token
          uri = URI(TOKEN_URI)
          request = Net::HTTP::Post.new(uri)
          request.set_form_data("grant_type" => GRANT, "assertion" => build_jwt)
          response = perform(uri, request)
          code = response.code.to_i
          unless code.between?(200, 299)
            raise StorageError, "google_drive token request failed: HTTP #{code} #{response.body}"
          end

          body = JSON.parse(response.body)
          @refresh_at = Time.now + body["expires_in"].to_i - TOKEN_REFRESH_MARGIN
          @access_token = body.fetch("access_token")
        end

        def build_jwt
          now = Time.now.to_i
          header = segment("alg" => "RS256", "typ" => "JWT")
          claim = segment("iss" => @client_email, "scope" => SCOPE, "aud" => TOKEN_URI,
                          "iat" => now, "exp" => now + 3600)
          signing_input = "#{header}.#{claim}"
          "#{signing_input}.#{base64url(@private_key.sign(OpenSSL::Digest.new('SHA256'), signing_input))}"
        end

        def segment(hash) = base64url(JSON.generate(hash))

        # URL-safe base64 without padding, using only the stdlib (no base64 gem,
        # which is no longer a default gem on newer Rubies).
        def base64url(data) = [data].pack("m0").tr("+/", "-_").delete("=")

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
