# frozen_string_literal: true

require "rake/testtask"

# Gem-packaging tasks (build / install / release) derived from the gemspec, so
# `rake install` puts the current checkout on your PATH as `pgkeeper`. Guarded
# like the RuboCop task below: a minimal environment without Bundler simply
# skips these and keeps the test/lint tasks working.
begin
  require "bundler/gem_tasks"
rescue LoadError
  warn "bundler/gem_tasks unavailable; `rake build`/`install`/`release` are disabled"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/unit/**/test_*.rb"]
    t.warning = false
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/integration/**/test_*.rb"]
    t.warning = false
  end
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:lint)
rescue LoadError
  desc "Run RuboCop (unavailable: rubocop not installed)"
  task :lint do
    warn "rubocop is not installed; run `bundle install` first"
  end
end

task default: %i[test lint]
