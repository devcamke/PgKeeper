# frozen_string_literal: true

require "test_helper"

module PgKeeper
  # A run fans out to every destination by default, or to a chosen subset when
  # `destinations:` names them. Exercised at the adapter-building seam so it
  # needs no live pg_dump.
  class TestOrchestratorDestinations < Minitest::Test
    include TestHelpers

    def config(dir)
      Config.new({
                   "workdir" => dir,
                   "databases" => [{ "name" => "app" }],
                   "storage" => [
                     { "type" => "local", "name" => "nas", "path" => File.join(dir, "nas") },
                     { "type" => "local", "name" => "cold", "path" => File.join(dir, "cold") },
                     { "type" => "memory", "name" => "scratch" }
                   ]
                 })
    end

    def adapters_for(dir, destinations)
      orch = Orchestrator.new(config(dir), logger: null_logger)
      orch.send(:start_run, config(dir).databases, "run-1", destinations)
      orch.instance_variable_get(:@adapters).map(&:name)
    end

    def test_nil_destinations_fans_out_to_all
      in_tmpdir { |dir| assert_equal %w[nas cold scratch], adapters_for(dir, nil) }
    end

    def test_selects_a_single_named_destination
      in_tmpdir { |dir| assert_equal %w[nas], adapters_for(dir, ["nas"]) }
    end

    def test_selects_a_subset
      in_tmpdir { |dir| assert_equal %w[nas scratch], adapters_for(dir, %w[nas scratch]) }
    end

    def test_unknown_destination_raises_before_dumping
      in_tmpdir do |dir|
        error = assert_raises(Error) { adapters_for(dir, ["ssd"]) }

        assert_match(/unknown destination "ssd"/, error.message)
      end
    end
  end
end
