# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

# JSON as every implementation reads and writes it (SPEC.md §2): as JavaScript does (JSON.parse and
# JSON.stringify), which Ruby's `json` does not: every number a double, the last of two members of
# one name, a lone surrogate kept, a byte order mark refused; no more than 64 arrays and objects
# nested, told by a scan before reading; written compact.
class JsonTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  def parse(text) = Json.parse(text)

  test "reads every number as its IEEE 754 double, whatever its spelling" do
    %w[500 500.0 5e2 5E+2 50000e-2].each { |text| assert_equal 500.0, parse(text), text }
    assert_kind_of Float, parse("1")
    # A large integer loses what a double cannot hold, as in JavaScript.
    assert_equal 9_007_199_254_740_992.0, parse("9007199254740993")
    assert_equal 0.30000000000000004, parse("0.30000000000000004")
    # Negative zero, and the edges of the doubles' range: an infinity or a zero, never an error.
    assert_predicate parse("-0"), :zero?
    assert_equal(-Float::INFINITY, 1 / parse("-0"))
    assert_equal Float::INFINITY, parse("1e400")
    assert_equal(-Float::INFINITY, parse("-1e400"))
    assert_equal 0.0, parse("1e-400")
    assert_equal Float::MAX, parse("1.7976931348623157e308")
    assert_equal Float::MAX, parse("1.7976931348623158e308")
    assert_equal Float::INFINITY, parse("1.7976931348623159e308")
    assert_equal 5e-324, parse("4.9e-324")
    assert_equal 5e-324, parse("2.4703282292062328e-324")
    assert_equal 0.0, parse("2.4703282292062327e-324")
    assert_equal 2.2250738585072014e-308, parse("2.2250738585072014e-308")
    assert_equal 1e308, parse("1#{"0" * 308}")
  end

  test "reads an integer of any length as a double: of 5000 digits too, an infinity beyond the range" do
    assert_equal Float::INFINITY, parse("9" * 5000)
    assert_equal(-Float::INFINITY, parse("-#{"9" * 5000}"))
    assert_equal [Float::INFINITY], parse("[#{"1" * 400}]")
    assert_equal 1e300, parse("1#{"0" * 300}")
    assert_equal 1.0, parse("1.#{"0" * 5000}1")
    assert_equal 0.0, parse("0.#{"0" * 5000}1")
    assert_equal Float::INFINITY, parse("1E+400")
  end

  test "reads a number of 20 000 digits and more, its zeros included, as JavaScript reads it" do
    # Ruby's own conversion reads these as an infinity, a zero, or ten times the value.
    assert_equal 7.777777777777778e+99, parse("#{"7" * 30_000}e-29900")
    assert_equal 0.7, parse("0.#{"0" * 100_000}7e100000")
    assert_equal 1.0, parse("1#{"0" * 20_000}e-20000")
    assert_equal(-7.0, parse("-0.#{"0" * 30_000}7e30001"))
    # 2^53 + 1 is halfway between two doubles: ties to even, but for a digit after it.
    assert_equal 9_007_199_254_740_992.0, parse("9007199254740993#{"0" * 30_000}e-30000")
    assert_equal 9_007_199_254_740_994.0, parse("9007199254740993#{"0" * 30_000}1e-30001")
    assert_equal 5e-324, parse("4940656458412465441765687928682213723651#{"0" * 30_000}e-30363")
  end

  test "reads a number of 1 MiB in time linear in its length, at the edges of the range and beyond" do
    digits = (1 << 20) - 20
    {
      "#{"1" * digits}e-#{digits - 306}" => 1.1111111111111111e+305,
      "0.#{"1" * digits}e-300" => 1.1111111111111111e-301,
      "1e#{"1" * digits}" => Float::INFINITY,
      "1e-#{"1" * digits}" => 0.0,
      "0e#{"9" * digits}" => 0.0,
      "1e#{"0" * digits}12" => 1e12
    }.each do |text, expected|
      value = nil
      seconds = cpu_seconds { value = parse(text) }
      assert_equal expected, value, text[0, 20]
      assert_operator seconds, :<, 2, text[0, 20]
    end
  end

  test "keeps the last of two members of one name, and names in their order" do
    assert_equal({ "a" => 2.0, "b" => 1.0 }, parse('{"a":1,"b":1,"a":2}'))
    assert_equal %w[z a m], parse('{"z":1,"a":2,"m":3}').keys
  end

  test "reads a member's name holding U+0000 as any other name" do
    assert_equal({ "a\u0000b" => 1.0 }, parse('{"a\\u0000b":1}'))
    assert_equal({ "\u0000" => 2.0, "" => 3.0 }, parse('{"\\u0000":1,"":3,"\\u0000":2}'))
    # Not escaped, a control character makes no JSON string.
    assert_raises(Json::Invalid) { parse("{\"a\u0000b\":1}") }
  end

  test "keeps a lone surrogate as the bytes that would encode it, which no text check takes" do
    lone = parse('"a\\ud800b"')
    assert_equal "a\xED\xA0\x80b".b, lone.b
    refute_predicate lone, :valid_encoding?
    refute Text.well_formed?(lone)
    assert_equal "😀", parse('"\\ud83d\\ude00"')
    assert_equal "\xED\xB0\x80😀".b, parse('"\\udc00\\ud83d\\ude00"').b
    assert_equal "\xED\xA0\xBD\xED\xA0\xBD".b, parse('"\\ud83d\\ud83d"').b
    # The rest of the document reads.
    assert_equal 1.0, parse('{"note":"\\ud800","sats":1}')["sats"]
  end

  test "reads escapes, and refuses what RFC 8259 does not allow" do
    assert_equal "\"\\/\b\f\n\r\té", parse('"\\"\\\\\\/\\b\\f\\n\\r\\t\\u00E9"')
    ["", " ", "01", "-01", "00", "[01]", '{"a":01}', "1.", ".5", "+1", "-", "1e", "0x10", "NaN", "Infinity",
     "-Infinity", "[1,]", '{"a":1,}', "[,]", "[1,,2]", "'a'", "\"\t\"", "\"\n\"", '"\\x"', '"\\u12"', '"\\U0041"',
     "{a:1}", "[1] x", "\xEF\xBB\xBF{}", "\v1", "\f1", "true1", "nul", "[", "{", '{"a"}', '{"a":}', '{"a" 1}',
     "[1 2]", "\"a", "\xFF", "//c\n1", "/*c*/1",
     # Whitespace is space, tab, line feed and carriage return, nothing else.
     "\u00A01", "1\u00A0", "[1,\u00A02]", "\uFEFF1", "[1,\uFEFF2]", "\u20281", "\u00851", "\u30001"].each do |text|
      assert_raises(Json::Invalid, text.inspect) { parse(text) }
    end
    assert_equal [1.0, [], {}], parse(" \t\r\n[1 , [ ] , { } ] \n")
    assert_nil Json.parse_or("{", nil)
    assert_equal :none, Json.parse_or(5, :none)
  end

  # `depth` arrays and objects, one in another, an object first: {"a":[{"a":[…0…]}]}.
  def nested(depth)
    opening = Array.new(depth) { |i| i.even? ? '{"a":' : "[" }
    closing = Array.new(depth) { |i| i.even? ? "}" : "]" }.reverse
    "#{opening.join}0#{closing.join}"
  end

  test "refuses a text in which more than 64 arrays and objects nest, arrays and objects counted together" do
    value = parse(("[" * 64) + ("]" * 64))
    63.times { value = value[0] }
    assert_equal [], value
    assert_raises(Json::Invalid) { parse(("[" * 65) + ("]" * 65)) }
    assert_raises(Json::Invalid) { parse("#{'{"a":' * 65}1#{"}" * 65}") }
    value = parse(nested(64))
    32.times { value = value["a"][0] }
    assert_equal 0.0, value
    assert_raises(Json::Invalid) { parse(nested(65)) }
    # Twice 63 deep, one after the other: never more than 64 at once.
    assert_equal 2, parse("[#{nested(63)},#{nested(63)}]").size
    assert_raises(Json::Invalid) { parse("[#{nested(63)},[#{nested(64)}]]") }
  end

  test "counts no bracket inside a string, an escaped quote and an escaped backslash told apart" do
    assert_equal ["[" * 100], parse("[\"#{"[" * 100}\"]")
    assert_equal ["\"#{"[{" * 100}"], parse("[\"\\\"#{"[{" * 100}\"]")
    # After an escaped backslash, the quote ends the string: the brackets after it nest.
    read = parse("[\"\\\\\",#{nested(63)}]")
    assert_equal ["\\", Hash], [read[0], read[1].class]
    assert_raises(Json::Invalid) { parse("[\"\\\\\",#{nested(64)}]") }
    # A string never closed: no JSON, whatever follows its quote.
    assert_raises(Json::Invalid) { parse("[\"#{"[" * 100}") }
  end

  test "refuses a long string never closed, or broken at its end, in time linear in its length" do
    long = "a" * (1 << 20)
    texts = ["\"#{long}", "\"#{long}\u0001\"", "[\"#{"a\\n" * 100_000}\\x\"]", "{\"#{long}\":1,\"#{long}"]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(20) do
      texts.each { |text| assert_raises(Json::Invalid) { parse(text) } }
    end
    # A string matched with backtracking takes for ever: 4 MiB in linear time take well below this.
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15
  end

  # The CPU time this thread spends in the block: what a busy machine's other work does not count.
  def cpu_seconds
    started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    yield
    Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - started
  end

  test "reads a string's escapes in time linear in its length: 1 MiB of them, a non-ASCII character between each or not" do
    # As a relay sends the text of an event anybody wrote (SPEC.md §13, Limits): a line feed is an
    # escape, and so is any control character.
    { "\\u0000" => "\u0000", "\\u0000é" => "\u0000é", "é\\n" => "é\n", "\\ud83d\\ude00\\ud800" => "😀\xED\xA0\x80".b }
      .each do |escaped, text|
        count = (1 << 20) / escaped.bytesize
        value = nil
        seconds = Timeout.timeout(60) { cpu_seconds { value = parse("[\"#{escaped * count}\"]") } }
        assert_equal (text * count).b, value[0].b, escaped
        # Ruby's own JSON takes milliseconds; a reader that counted each escape's offset from the
        # string's start took 9 s for the first, 130 s for the second.
        assert_operator seconds, :<, 2, escaped
      end
  end

  test "tells a text too deep by a scan, before reading it: the reader itself has no bound" do
    deep = ("[" * 100_000) + ("]" * 100_000)
    assert_raises(Json::Invalid) { parse(deep) }
    # Read without recursion, no depth exhausts the stack (Ruby's `json` stops at 100 by default):
    # what bounds the depth is the scan, the same in every implementation.
    value = Json::Parser.new(deep).parse
    99_999.times { value = value[0] }
    assert_equal [], value
    assert_equal({ "a" => { "a" => {} } }, parse('{"a":{"a":{}}}'))
  end

  test "writes compact JSON as JSON.stringify writes it" do
    value = { "s" => "a\"b\\c/\u2028é\x00\x1f\b\f\n\r\t", "n" => [1, 1.5, -0.0, 100.0, 1e21, 1e-7, 1.23e-18, 0.1 + 0.2],
              "t" => true, "f" => false, "z" => nil, :sym => :value }
    # U+2028 as it is, as JSON.stringify writes it.
    expected = "{\"s\":\"a\\\"b\\\\c/\u2028é\\u0000\\u001f\\b\\f\\n\\r\\t\"," \
               '"n":[1,1.5,0,100,1e+21,1e-7,1.23e-18,0.30000000000000004],' \
               '"t":true,"f":false,"z":null,"sym":"value"}'
    assert_equal expected, Json.generate(value)
    # Doubles as JavaScript prints them: integers below 10^21 in full, the shortest digits.
    { 123_456_789_012_345_680_000.0 => "123456789012345680000", 1.5e300 => "1.5e+300", 5e-324 => "5e-324",
      0.000001 => "0.000001", 0.0000001 => "1e-7", 25.0 => "25", -1.5 => "-1.5",
      9_007_199_254_740_993 => "9007199254740993" }.each do |number, text|
      assert_equal text, Json.generate(number), number.inspect
    end
    assert_raises(ArgumentError) { Json.generate(Float::NAN) }
    assert_raises(ArgumentError) { Json.generate(Float::INFINITY) }
    assert_raises(ArgumentError) { Json.generate(Object.new) }
  end

  test "writes a lone surrogate it read as JSON.stringify writes one: its escape" do
    assert_equal '"a\\ud800b"', Json.generate(parse('"a\\ud800b"'))
    assert_equal '["\\udc00😀"]', Json.generate([parse('"\\udc00\\ud83d\\ude00"')])
    # Bytes that are no UTF-8 at all are no text.
    assert_raises(ArgumentError) { Json.generate("\xFF".b) }
  end

  test "reads back what it writes" do
    value = { "a" => [1.0, "é", { "b" => nil }], "c" => "😀\u0000" }
    assert_equal value, parse(Json.generate(value))
  end

  test "tells safe integers apart, as Number.isSafeInteger does" do
    assert Json.safe_integer?(9_007_199_254_740_991.0)
    refute Json.safe_integer?(9_007_199_254_740_992.0)
    assert Json.safe_integer?(-9_007_199_254_740_991)
    refute Json.safe_integer?(1.5)
    refute Json.safe_integer?(true)
    refute Json.safe_integer?("1")
    refute Json.safe_integer?(Float::INFINITY)
    assert Json.integer?(1e300)
    refute Json.integer?(Float::NAN)
  end
end
