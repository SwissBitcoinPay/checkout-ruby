# frozen_string_literal: true

# `rake build:check`: builds the gem into pkg/, as `rake release` would, and checks what it holds:
# the library and its documents, never the tests nor the pinned specification; its version, its
# Ruby, its one dependency; and that it loads without a warning. Fails (exit 1) on any difference.

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
DOCUMENTS = %w[README.md CHANGELOG.md LICENSE SECURITY.md].freeze

def fail_with(problems)
  warn(problems.map { |problem| "build:check: #{problem}" })
  exit 1
end

Dir.chdir(ROOT) do
  require_relative "../lib/sattleme/checkout/version"
  missing = DOCUMENTS.reject { |document| File.file?(document) }
  fail_with(missing.map { |document| "#{document} is missing" }) unless missing.empty?

  spec = Gem::Specification.load("sattleme-checkout.gemspec")
  FileUtils.mkdir_p("pkg")
  built = Gem::Package.build(spec)
  path = File.join("pkg", File.basename(built))
  FileUtils.mv(built, path)

  package = Gem::Package.new(path)
  contents = package.contents.sort
  expected = (Dir["lib/**/*.rb"] + DOCUMENTS).sort
  problems = []
  problems << "it holds #{(contents - expected).join(", ")}, which it should not" unless (contents - expected).empty?
  problems << "it lacks #{(expected - contents).join(", ")}" unless (expected - contents).empty?
  problems << "it holds the tests or the specification" if contents.any? { |file| file.start_with?("test/", "spec/") }
  built_spec = package.spec
  problems << "its version is #{built_spec.version}, not #{Sattleme::Checkout::VERSION}" unless
    built_spec.version.to_s == Sattleme::Checkout::VERSION
  problems << "its Ruby is #{built_spec.required_ruby_version}" unless built_spec.required_ruby_version.to_s == ">= 3.3"
  dependencies = built_spec.runtime_dependencies.map(&:name)
  problems << "its dependencies are #{dependencies.join(", ")}, not ffi alone" unless dependencies == ["ffi"]
  problems << "its license is not MIT" unless built_spec.licenses == ["MIT"]
  unless built_spec.metadata["rubygems_mfa_required"] == "true"
    problems << "it does not require multi-factor authentication to be pushed"
  end

  # It loads, without a warning, from what the package holds and its dependency alone: never
  # Bundler's setup, which would load this repository's gemspec, and so its lib/, first
  # (libsecp256k1: the system's, or the one `rake secp256k1` built, as for the tests).
  environment = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }
  built_library = Dir[File.join(ROOT, "tmp/secp256k1/lib*/libsecp256k1.{so,dylib}")].first
  environment["SATTLEME_SECP256K1_LIBRARY"] = built_library if built_library && !ENV.key?("SATTLEME_SECP256K1_LIBRARY")
  ffi = Gem.loaded_specs["ffi"] || Gem::Specification.find_by_name("ffi")
  dependency = ffi.full_require_paths.flat_map { |path| ["-I", path] }
  load = 'require "sattleme/checkout"; exit(Sattleme::Checkout::Client.instance_method(:create_invoice) ? 0 : 1)'
  Dir.mktmpdir("sattleme-checkout-package", File.join(ROOT, "pkg")) do |dir|
    package.extract_files(dir)
    _, errors, status = Open3.capture3(environment, RbConfig.ruby, "-w", "-I", File.join(dir, "lib"), *dependency,
                                       "-e", load)
    problems << "it does not load: #{errors.strip}" unless status.success?
    problems << "it warns when it loads: #{errors.strip}" if status.success? && !errors.strip.empty?
  end
  fail_with(problems) unless problems.empty?

  puts "#{path}: #{contents.size} files, version #{built_spec.version}, Ruby #{built_spec.required_ruby_version}"
end
