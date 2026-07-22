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
    "lib/**/*.erb",
    "bin/*",
    "config/*.example.yml",
    "docs/*.md",
    "README.md",
    "LICENSE*"
  ]
  spec.bindir      = "bin"
  spec.executables = ["pgkeeper"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/devcamke/pgkeeper"
  spec.metadata["changelog_uri"] = "https://github.com/devcamke/pgkeeper/blob/main/docs/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/devcamke/pgkeeper/issues"

  spec.add_dependency "thor", "~> 1.3"

  # zip archiving bundles a dump + its manifest into one shareable file; rubyzip
  # is pure Ruby, so it's a safe hard dependency.
  spec.add_dependency "rubyzip", "~> 2.3"

  # Email notifications (SMTP + TLS) and the SQLite run-history store that powers
  # `pgkeeper status`.
  spec.add_dependency "mail", "~> 2.8"
  spec.add_dependency "sqlite3", "~> 2.0"

  # Cron / natural-language schedule parsing and next-occurrence computation for
  # the scheduler and daemon (pure Ruby).
  spec.add_dependency "fugit", "~> 1.11"

  # Ruby 4 no longer ships these as default gems, so declare them explicitly
  # rather than relying on them being present in the standard library.
  spec.add_dependency "erb", "~> 4.0"
  spec.add_dependency "logger", "~> 1.6"

  # Cloud storage SDKs are intentionally NOT hard dependencies — each cloud
  # adapter lazy-requires its SDK and tells the user to install it if missing,
  # so a local-only install stays lean. See the storage adapters and the
  # optional dependencies in the Gemfile.

  spec.metadata["rubygems_mfa_required"] = "true"
end
