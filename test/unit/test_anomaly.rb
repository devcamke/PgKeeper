# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestAnomaly < Minitest::Test
    include TestHelpers

    def config(overrides = {})
      Config::DEFAULT_ANOMALY.merge(overrides.transform_keys(&:to_s))
    end

    def test_flags_a_dump_that_shrank_past_the_threshold
      finding = Anomaly.detect(database: "app", current_bytes: 400,
                               baseline_sizes: [1000, 1010, 990, 1000, 1005], config: config)

      refute_nil finding
      assert_equal :shrink, finding.direction
      assert_equal 1000, finding.baseline_bytes
      assert_operator finding.change_pct, :<, 0
      assert_match(/shrank/, finding.message)
    end

    def test_no_finding_when_within_threshold
      finding = Anomaly.detect(database: "app", current_bytes: 900,
                               baseline_sizes: [1000, 1000, 1000], config: config)

      assert_nil finding
    end

    def test_requires_min_samples
      finding = Anomaly.detect(database: "app", current_bytes: 1,
                               baseline_sizes: [1000], config: config("min_samples" => 2))

      assert_nil finding
    end

    def test_disabled_returns_nil
      finding = Anomaly.detect(database: "app", current_bytes: 1,
                               baseline_sizes: [1000, 1000, 1000], config: config("enabled" => false))

      assert_nil finding
    end

    def test_uses_median_so_a_single_outlier_does_not_skew
      # One huge prior run must not drag the baseline up and mask a real shrink,
      # nor invent one. Median of [1000,1000,1000,1000,50000] is 1000.
      finding = Anomaly.detect(database: "app", current_bytes: 950,
                               baseline_sizes: [1000, 1000, 1000, 1000, 50_000], config: config)

      assert_nil finding, "median baseline should be 1000, and 950 is within 50%"
    end

    def test_growth_warning_is_opt_in
      cfg = config("grow_pct" => 100)
      finding = Anomaly.detect(database: "app", current_bytes: 3000,
                               baseline_sizes: [1000, 1000, 1000], config: cfg)

      refute_nil finding
      assert_equal :grow, finding.direction
    end

    def test_growth_disabled_by_default
      finding = Anomaly.detect(database: "app", current_bytes: 100_000,
                               baseline_sizes: [1000, 1000, 1000], config: config)

      assert_nil finding
    end

    def test_ignores_zero_and_negative_samples
      finding = Anomaly.detect(database: "app", current_bytes: 400,
                               baseline_sizes: [0, 0, 1000, 1000], config: config("min_samples" => 2))

      refute_nil finding
      assert_equal 1000, finding.baseline_bytes
    end

    def test_zero_current_bytes_is_not_judged
      finding = Anomaly.detect(database: "app", current_bytes: 0,
                               baseline_sizes: [1000, 1000, 1000], config: config)

      assert_nil finding
    end
  end
end
