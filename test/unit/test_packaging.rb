# frozen_string_literal: true

require "test_helper"
require "rubygems"

module PgKeeper
  # Guards the packaging surface: a valid, installable gemspec and the presence
  # of the deployment artifacts (Docker, docs) shipped in this phase.
  class TestPackaging < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)

    def gemspec
      @gemspec ||= Gem::Specification.load(File.join(ROOT, "pgkeeper.gemspec"))
    end

    def test_gemspec_is_valid
      assert gemspec, "gemspec should load"
      # validate raises Gem::InvalidSpecificationException if not installable; it
      # also prints style warnings to stderr, which we silence rather than assert.
      capture_io { gemspec.validate }
    rescue Gem::InvalidSpecificationException => e
      flunk "gemspec is invalid: #{e.message}"
    end

    def test_version_matches_constant
      assert_equal PgKeeper::VERSION, gemspec.version.to_s
    end

    def test_ships_executable
      assert_includes gemspec.executables, "pgkeeper"
      assert_path_exists File.join(ROOT, "bin", "pgkeeper")
    end

    def test_bundles_lib_docs_and_changelog
      files = gemspec.files

      assert_includes files, "lib/pgkeeper.rb"
      assert_includes files, "CHANGELOG.md"
      assert(files.any? { |f| f.start_with?("docs/") }, "docs should be bundled")
    end

    def test_declares_required_ruby_and_metadata
      assert gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.6"))
      assert_equal "true", gemspec.metadata["rubygems_mfa_required"]
      assert gemspec.metadata["changelog_uri"]
    end

    def test_deployment_artifacts_exist
      %w[Dockerfile .dockerignore docker-compose.example.yml
         docs/SECURITY.md docs/STORAGE.md docs/RESTORE.md].each do |f|
        assert_path_exists File.join(ROOT, f)
      end
    end
  end
end
