# frozen_string_literal: true

require "openssl"

module PgKeeper
  module Web
    # Rack middleware that authenticates every request — pages and API alike —
    # before the dashboard sees it. Credentials come in three shapes, any mix:
    #
    #   * +token+: a single bearer token (also accepted as the basic-auth
    #     password, so browsers work),
    #   * +tokens+: a map of name => secret, so each caller (CI, a bot, a
    #     teammate) has its own token that can be revoked independently — drop
    #     the entry and restart. The authenticating caller's name is recorded on
    #     the request (`env["pgkeeper.caller"]`) for audit logging,
    #   * +username+ / +password+: classic HTTP basic auth.
    #
    # Comparisons are constant-time over SHA-256 digests, so neither the length
    # nor the content of a guess leaks through timing. Refuses to boot with no
    # credentials at all: an unauthenticated dashboard exposing backup metadata
    # is the exact failure PLAN.md forbids.
    class Auth
      # Rack env key naming the authenticated caller (a token name, or the
      # basic-auth username), for downstream audit logging.
      CALLER_KEY = "pgkeeper.caller"

      def initialize(app, token: nil, tokens: nil, username: nil, password: nil)
        @app = app
        @tokens = build_token_list(token, tokens)
        @username = username
        @password = password
        return unless @tokens.empty? && !(@username && @password)

        raise EnvironmentError,
              "web dashboard auth is not configured — set `web.auth.token`, one or more " \
              "`web.auth.tokens` (name => token), or `web.auth.username` + `web.auth.password` " \
              "in your config"
      end

      def call(env)
        caller_name = authenticate(env["HTTP_AUTHORIZATION"])
        if caller_name
          env[CALLER_KEY] = caller_name
          return @app.call(env)
        end

        [401,
         { "content-type" => "text/plain", "www-authenticate" => %(Basic realm="PgKeeper") },
         ["401 Unauthorized\n"]]
      end

      private

      # Normalize the single `token:` and the `tokens:` map into one ordered
      # list of [name, secret] pairs; a lone token is named "token".
      def build_token_list(token, tokens)
        list = []
        list << ["token", token] if token
        tokens&.each { |name, secret| list << [name.to_s, secret] if secret }
        list
      end

      # Return the authenticated caller's name, or nil.
      def authenticate(header)
        return nil if header.nil? || header.empty?

        scheme, credential = header.split(" ", 2)
        case scheme&.downcase
        when "bearer" then match_token(credential.to_s)
        when "basic" then basic_caller(credential.to_s)
        end
      end

      # The name of the token whose secret equals +secret+, or nil.
      def match_token(secret)
        @tokens.find { |(_name, value)| secure_compare(secret, value) }&.first
      end

      def basic_caller(credential)
        decoded = decode_base64(credential)
        return nil if decoded.nil?

        user, pass = decoded.split(":", 2)
        if @username && @password &&
           secure_compare(user.to_s, @username) && secure_compare(pass.to_s, @password)
          return @username
        end

        # Token configs work from a browser too: any username, token as password.
        match_token(pass.to_s)
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
