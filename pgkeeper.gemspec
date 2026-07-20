# frozen_string_literal: true

require_relative "lib/pgkeeper/version"

Gem::Specification.new do |spec|
  spec.name        = "pgkeeper"
  spec.version     = PgKeeper::VERSION
  spec.authors     = ["PgKeeper contributors"]
  spec.summary     = "Automated PostgreSQL backup solution: dump, compress, encrypt, ship, verify."
  spec.description = <<~DESC
    PgKeeper dumps your PostgreSQL databases on a schedule, compresses and optionally
    encrypts the artifacts, stores them locally and/or in the cloud, enforces retention
    policies, verifies that backups are actually restorable, and reports status.
  DESC
  spec.homepage = "https://github.com/devcamke/pgkeeper"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/*",
    "config/*.example.yml",
    "README.md",
    "PLAN.md",
    "LICENSE*"
  ]
  spec.bindir      = "bin"
  spec.executables = ["pgkeeper"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"

  # Ruby 4 no longer ships these as default gems, so declare them explicitly
  # rather than relying on them being present in the standard library.
  spec.add_dependency "erb", "~> 4.0"
  spec.add_dependency "logger", "~> 1.6"

  spec.metadata["rubygems_mfa_required"] = "true"
end
