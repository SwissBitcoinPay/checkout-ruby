# frozen_string_literal: true

require_relative "lib/sattleme/checkout/version"

Gem::Specification.new do |spec|
  spec.name = "sattleme-checkout"
  spec.version = Sattleme::Checkout::VERSION
  spec.authors = ["sattle.me"]
  spec.license = "MIT"
  spec.summary = "Take Lightning and on-chain payments for a sattle.me merchant from an online " \
                 "shop's server."
  spec.description = "Take Lightning and on-chain payments for a sattle.me merchant from an " \
                     "online shop's server: invoices, deposit addresses, registry declarations, " \
                     "payment checks. Implements the sattle.me checkout specification."
  spec.homepage = "https://sattle.me"
  spec.metadata = {
    "homepage_uri" => "https://sattle.me",
    "source_code_uri" => "https://github.com/sattleme/checkout-ruby",
    "changelog_uri" => "https://github.com/sattleme/checkout-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sattleme/checkout-ruby/issues",
    "documentation_uri" => "https://github.com/sattleme/checkout-ruby#readme",
    "rubygems_mfa_required" => "true",
    "allowed_push_host" => "https://rubygems.org"
  }

  spec.required_ruby_version = ">= 3.3"
  # What the package holds: the library and its documents; never the tests nor the pinned
  # specification (spec/), which only the tests read.
  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE SECURITY.md]
  spec.require_paths = ["lib"]

  # libsecp256k1 (Bitcoin Core's), the system's, through FFI: README.md, "Dependencies".
  spec.add_dependency "ffi", ">= 1.17.4", "< 2"
end
