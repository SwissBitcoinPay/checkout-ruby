# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

# `bundle exec rake`: every check the CI runs, in its order: the pinned copy of the specification,
# RuboCop (format and lint), the tests, the package. `build`, `install` and `release` are Bundler's
# (release.yml runs `release`: never by hand).
task default: %i[spec:check rubocop test build:check]

namespace :spec do
  desc "Check that spec/ is the copy spec/PIN.json pins, file for file"
  task :check do
    ruby "scripts/spec.rb", "check"
  end

  desc "Replace spec/ with a clean checkout-spec clone's files: rake spec:import[../checkout-spec]"
  task :import, [:clone] do |_, args|
    abort "Usage: rake spec:import[<checkout-spec clone>]" unless args[:clone]
    ruby "scripts/spec.rb", "import", args[:clone]
  end
end

# RuboCop is in the Gemfile's `lint` group, which a bundle may leave out (the CI's test jobs:
# BUNDLE_WITHOUT=lint): then `rake rubocop` says so.
begin
  require "rubocop/rake_task"

  RuboCop::RakeTask.new(:rubocop) do |task|
    task.options = ["--display-cop-names"]
    # No cache in the CI: RuboCop's is in HOME, outside the job's own directory (RUNNER_TEMP).
    task.options += ["--cache", "false"] if ENV["CI"]
  end
rescue LoadError
  desc "RuboCop (not in this bundle: BUNDLE_WITHOUT=lint)"
  task :rubocop do
    abort "RuboCop is not in this bundle (its group, lint, was left out): bundle install with it"
  end
end

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"]
  task.warning = true
end

namespace :build do
  desc "Build the gem into pkg/ and check what it holds"
  task :check do
    ruby "scripts/package.rb"
  end
end

# libsecp256k1 for development, where the system has none: Bitcoin Core's release, at a commit
# checked here, built into tmp/secp256k1, which the tests use (test/test_helper.rb). The CI builds
# nothing: it takes Ubuntu's (.github/ci/setup.sh).
SECP256K1 = {
  repository: "https://github.com/bitcoin-core/secp256k1",
  tag: "v0.8.0",
  commit: "6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d"
}.freeze

desc "Build libsecp256k1 #{SECP256K1[:tag]} into tmp/secp256k1 (git, cmake and a C compiler)"
task :secp256k1 do
  prefix = File.expand_path("tmp/secp256k1")
  next puts("#{prefix}: built already") unless Dir["#{prefix}/lib*/libsecp256k1.{so,dylib}"].empty?

  source = File.expand_path("tmp/secp256k1-source")
  rm_rf source
  sh "git", "clone", "--quiet", "--depth", "1", "--branch", SECP256K1[:tag], SECP256K1[:repository], source
  commit = `git -C #{source} rev-parse HEAD`.strip
  abort "#{SECP256K1[:tag]} is #{commit}, not #{SECP256K1[:commit]}" unless commit == SECP256K1[:commit]
  sh "cmake", "-S", source, "-B", "#{source}/build", "-DCMAKE_BUILD_TYPE=Release",
     "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DSECP256K1_BUILD_TESTS=OFF",
     "-DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF", "-DSECP256K1_BUILD_BENCHMARK=OFF",
     "-DSECP256K1_BUILD_EXAMPLES=OFF", "-DSECP256K1_BUILD_CTIME_TESTS=OFF",
     "-DSECP256K1_ENABLE_MODULE_ECDH=ON", "-DSECP256K1_ENABLE_MODULE_EXTRAKEYS=ON",
     "-DSECP256K1_ENABLE_MODULE_SCHNORRSIG=ON"
  sh "cmake", "--build", "#{source}/build", "--parallel", "4"
  sh "cmake", "--install", "#{source}/build"
  rm_rf source
end
