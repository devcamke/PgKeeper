# frozen_string_literal: true

require "openssl"

module PgKeeper
  module Web
    # Rack middleware that authenticates every request — pages and API alike —
    # before the dashboard sees it. Two credential shapes:
    #
    #   * +token+: accepted as `Authorization: Bearer <token>`, or as the
    #     password of HTTP basic auth with any username (so browsers work),
    #   * +username+ / +password+: classic HTTP basic auth.
    #
    # Comparisons are constant-time over SHA-256 digests, so neither the
    # length nor the content of a guess leaks through timing. Refuses to boot
    # with no credentials at all: an unauthenticated dashboard exposing backup
    # metadata is the exact failure PLAN.md forbids.
    class Auth
      def initialize(app, token: nil, username: nil, password: nil)
        @app = app
        @token = token
        @username = username
        @password = password
        return if @token || (@username && @password)

        raise EnvironmentError,
              "web dashboard auth is not configured — set `web.auth.token` (e.g. from an " \
              "environment variable) or `web.auth.username` + `web.auth.password` in your config"
      end

      def call(env)
        return @app.call(env) if authorized?(env["HTTP_AUTHORIZATION"])

        [401,
         { "content-type" => "text/plain", "www-authenticate" => %(Basic realm="PgKeeper") },
         ["401 Unauthorized\n"]]
      end

      private

      def authorized?(header)
        return false if header.nil? || header.empty?

        scheme, credential = header.split(" ", 2)
        case scheme&.downcase
        when "bearer" then bearer_ok?(credential)
        when "basic" then basic_ok?(credential)
        else false
        end
      end

      def bearer_ok?(credential)
        !@token.nil? && secure_compare(credential.to_s, @token)
      end

      def basic_ok?(credential)
        decoded = decode_base64(credential.to_s)
        return false if decoded.nil?

        user, pass = decoded.split(":", 2)
        return true if @username && @password &&
                       secure_compare(user.to_s, @username) && secure_compare(pass.to_s, @password)

        # Token configs work from a browser too: any username, token as password.
        !@token.nil? && secure_compare(pass.to_s, @token)
      end

      def decode_base64(str)
        str.unpack1("m")
      rescue ArgumentError
        nil
      end

      # Constant-time equality over fixed-length digests, so inputs of any
      # length compare in the same time.
      def secure_compare(given, expected)
        OpenSSL.fixed_length_secure_compare(
          OpenSSL::Digest.digest("SHA256", given),
          OpenSSL::Digest.digest("SHA256", expected)
        )
      end
    end
  end
end
