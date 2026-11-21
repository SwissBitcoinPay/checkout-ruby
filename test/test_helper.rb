# frozen_string_literal: true

# The tests run against the library in lib/, the pinned copy of the specification in spec/, local
# relays and fakes of every service: never the network.

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

# libsecp256k1: the system's, or the one `rake secp256k1` built in tmp/ (README.md, "Development").
unless ENV.key?("SATTLEME_SECP256K1_LIBRARY")
  built = Dir[File.join(ROOT, "tmp/secp256k1/lib*/libsecp256k1.{so,dylib}")].first
  ENV["SATTLEME_SECP256K1_LIBRARY"] = built if built
end

require "fileutils"
require "pp"
require "tmpdir"
require "minitest/autorun"
require "sattleme/checkout"
require_relative "support/merchant"

# The pinned copy of the specification (spec/, PIN.json): its vectors, never edited here
# (test/spec_pin_test.rb).
module SpecVectors
  SPEC_DIR = File.join(ROOT, "spec")

  module_function

  # A file of the pinned copy of the specification, read as every implementation reads JSON.
  def read(path)
    Sattleme::Checkout::Internal::Json.parse(File.binread(File.join(SPEC_DIR, path)))
  end

  # vectors/app/app.json: made by the merchant's app.
  def app
    @app ||= read("vectors/app/app.json")
  end
end

module TestNames
  # `test "what holds" do … end`: a test named as node's tests are, one for one.
  def test(name, &)
    method = "test_#{name.gsub(/[^A-Za-z0-9]+/, "_")}"
    raise ArgumentError, "Two tests named #{name}" if method_defined?(method)

    define_method(method, &)
  end
end

Minitest::Test.extend(TestNames)

# A logger that keeps what it is told.
class TestLogger
  def initialize
    @mutex = Mutex.new
    @messages = []
  end

  def warn(message)
    @mutex.synchronize { @messages << message }
  end

  def messages = @mutex.synchronize { @messages.dup }
end

# A logger that says nothing.
QUIET = Object.new.tap { |quiet| def quiet.warn(_message) = nil }

# What most tests need: a hex helper, the error raised by a block.
module TestHelpers
  include Sattleme::Checkout

  def hex(text) = Internal::Text.hex_bytes(text)

  def to_hex(bytes) = Internal::Text.hex(bytes)

  # assert_equal, or assert_nil when nil is expected (as Minitest asks): for the vectors, whose
  # expected value may be null.
  def assert_value(expected, actual, message = nil)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
  end

  # The error the block raises (nil when it raises none).
  def error_of
    yield
    nil
  rescue StandardError => e
    e
  end

  # Waits, a few seconds at most, until the block gives a truthy value: for what a test's threads
  # do at their pace (the relays past the majority, the explorer's socket).
  def eventually(seconds = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      value = yield
      return value if value
      raise Minitest::Assertion, "Not in time" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end
