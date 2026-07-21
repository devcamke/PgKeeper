# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-minitest", "~> 0.34", require: false
  gem "rubocop-rake", "~> 0.6", require: false
  # Stubs HTTP so webhook / dead-man's-switch notifier tests need no network.
  gem "webmock", "~> 3.19", require: false
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
