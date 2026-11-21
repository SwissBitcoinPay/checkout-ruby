# frozen_string_literal: true

require_relative "test_helper"
require "English"

# The Ruby examples of README.md run as they are written (test/support/readme_examples.rb, in a
# process of its own), against local relays and fakes of every service.
class ReadmeTest < Minitest::Test
  test "runs every Ruby example of the README as it is written" do
    output = IO.popen([RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-I", File.join(ROOT, "test"),
                       File.join(ROOT, "test/support/readme_examples.rb")], err: %i[child out], &:read)
    assert_predicate $CHILD_STATUS, :success?, output
    assert_includes output, "every example ran"
    assert_equal 10, output.scan(/^ran: /).size, output
  end
end
