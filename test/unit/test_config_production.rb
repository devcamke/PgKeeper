# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # Config parsing for the production-hardening blocks: timeouts and anomaly.
  class TestConfigProduction < Minitest::Test
    include TestHelpers

    def parse(extra = "")
      Config.parse(<<~YAML)
        databases:
          - name: app
            database: app
        storage:
          - type: local
            path: /tmp/pgk
        #{extra}
      YAML
    end

    def test_timeouts_default_when_absent
      config = parse

      assert_equal Config::DEFAULT_TIMEOUTS, config.timeouts
      assert_equal 21_600, config.timeout(:dump)
      assert_equal 60, config.timeout(:query)
    end

    def test_timeouts_override_merges_over_defaults
      config = parse(<<~YAML)
        timeouts:
          dump: 300
      YAML
      assert_equal 300, config.timeout(:dump)
      # untouched keys keep their defaults
      assert_equal 21_600, config.timeout(:restore)
    end

    def test_zero_timeout_disables_the_deadline
      config = parse(<<~YAML)
        timeouts:
          dump: 0
      YAML
      assert_nil config.timeout(:dump)
    end

    def test_negative_timeout_is_a_config_error
      err = assert_raises(ConfigError) do
        parse(<<~YAML)
          timeouts:
            dump: -5
        YAML
      end
      assert(err.problems.any? { |p| p.include?("timeouts.dump") })
    end

    def test_unknown_timeout_key_rejected
      err = assert_raises(ConfigError) { parse("timeouts:\n  bogus: 5\n") }
      assert(err.problems.any? { |p| p.include?("timeouts") && p.include?("bogus") })
    end

    def test_anomaly_defaults_when_absent
      config = parse

      assert_equal Config::DEFAULT_ANOMALY, config.anomaly
      assert config.anomaly["enabled"]
    end

    def test_anomaly_can_be_disabled
      config = parse(<<~YAML)
        anomaly:
          enabled: false
      YAML
      refute config.anomaly["enabled"]
    end

    def test_anomaly_override_merges
      config = parse(<<~YAML)
        anomaly:
          shrink_pct: 25
      YAML
      assert_equal 25, config.anomaly["shrink_pct"]
      assert_equal 5, config.anomaly["sample_size"]
    end

    def test_anomaly_rejects_bad_numbers
      err = assert_raises(ConfigError) { parse("anomaly:\n  shrink_pct: nope\n") }
      assert(err.problems.any? { |p| p.include?("anomaly.shrink_pct") })
    end
  end
end
