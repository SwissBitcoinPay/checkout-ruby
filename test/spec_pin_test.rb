# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/spec"

# The pinned copy of the specification (spec/, PORTING.md of checkout-spec): every file of
# spec/PIN.json is there with its SHA-256, and nothing else. It changes only by taking a newer
# version of checkout-spec (rake spec:import[<clone>]), never by hand.
class SpecPinTest < Minitest::Test
  test "is the copy PIN.json pins" do
    assert_empty SpecPin.problems
  end

  test "tells a copy that differs from its PIN.json" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(ROOT, "spec/."), dir)
      File.write(File.join(dir, "vectors/bolt11.json"), "{}")
      File.write(File.join(dir, "extra.json"), "{}")
      FileUtils.rm(File.join(dir, "currencies.json"))
      assert_equal ["vectors/bolt11.json differs from PIN.json", "currencies.json is missing",
                    "extra.json is not in PIN.json"].sort, SpecPin.problems(dir).sort
    end
  end
end
