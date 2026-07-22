# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Validation of the `web.auth.tokens` map (per-caller, independently
  # revocable tokens).
  class TestConfigWebAuth < Minitest::Test
    include TestHelpers

    def parse(auth_yaml)
      Config.parse(<<~YAML)
        databases:
          - name: app
        web:
          auth:
        #{auth_yaml.gsub(/^/, '    ')}
      YAML
    end

    def test_named_tokens_are_accepted
      config = parse(<<~YAML)
        tokens:
          ci: tok-ci
          bot: tok-bot
      YAML

      assert_equal({ "ci" => "tok-ci", "bot" => "tok-bot" }, config.web.dig("auth", "tokens"))
    end

    def test_single_token_and_named_tokens_can_coexist
      config = parse(<<~YAML)
        token: legacy
        tokens:
          ci: tok-ci
      YAML

      assert_equal "legacy", config.web.dig("auth", "token")
      assert_equal "tok-ci", config.web.dig("auth", "tokens", "ci")
    end

    def test_tokens_must_be_a_mapping
      err = assert_raises(ConfigError) { parse("tokens: not-a-map\n") }

      assert(err.problems.any? { |p| p.include?("web.auth.tokens must be a mapping") })
    end

    def test_token_secret_must_be_a_string
      err = assert_raises(ConfigError) do
        parse(<<~YAML)
          tokens:
            ci: 12345
        YAML
      end

      assert(err.problems.any? { |p| p.include?("web.auth.tokens.ci must be a string") })
    end

    def test_unknown_auth_key_is_rejected
      err = assert_raises(ConfigError) { parse("bogus: x\n") }

      assert(err.problems.any? { |p| p.include?("unknown key") })
    end
  end
end
