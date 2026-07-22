# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rack-test", "~> 2.1", require: false
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-minitest", "~> 0.34", require: false
  gem "rubocop-rake", "~> 0.6", require: false
  # Stubs HTTP so webhook / dead-man's-switch notifier tests need no network.
  gem "webmock", "~> 3.19", require: false
end

# The optional web dashboard (`pgkeeper web`). rack is the app framework; puma
# (or any Rack server) serves it. Neither is a runtime dependency of the gem —
# lib/pgkeeper/web lazy-requires them so headless installs never pay for the
# dashboard. They live here so the test suite can exercise the dashboard with
# rack-test.
group :web, :test do
  gem "puma", ">= 6.4", "< 8"
  gem "rack", "~> 3.1"
end

# Optional cloud-storage SDKs. These are not runtime dependencies of the gem
# (adapters lazy-require them); they live here so the test suite can exercise
# the cloud adapters. Users who want a given backend add the matching gem.
group :cloud, :test do
  gem "aws-sdk-s3", "~> 1.150"
  # aws-sdk-core needs an XML parser and no longer finds one in the stdlib on
  # newer Rubies; rexml is the lightweight pure-Ruby choice.
  gem "rexml", "~> 3.3"
end
