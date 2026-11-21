# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "English"
require_relative "support/secret_holders"

class KeyTest < Minitest::Test
  include TestHelpers

  KEY = SpecVectors.app["secretKey"]
  TEAM, PART, RELAYS = KEY.delete_prefix("sattleme_ck_").split(".")

  # `part` (base64url of UTF-8) with a byte order mark before its text.
  def self.with_bom(part)
    Internal::Base64.encode_url("\xEF\xBB\xBF".b + Internal::Base64.decode_url(part))
  end

  test "reads the key the app made" do
    parsed = Internal::IntegrationKey.parse(KEY)
    assert_equal SpecVectors.app["parsed"]["team"], parsed.team_public_key
    assert_equal SpecVectors.app["parsed"]["integrationKey"], to_hex(parsed.key)
    assert_equal SpecVectors.app["parsed"]["relays"], parsed.relays
    # The key of integration-keys.json's "the app's vector", with the same parts.
    cases = SpecVectors.read("vectors/integration-keys.json")["cases"]
    vector = cases.find { |item| item["name"] == "the app's vector" }
    assert_equal vector["key"], KEY
    assert_equal vector["expected"].values_at("teamPublicKey", "integrationKey", "relays"),
                 SpecVectors.app["parsed"].values_at("team", "integrationKey", "relays")
  end

  test "keeps the key out of its JSON, inspection, pretty print and serializations" do
    parsed = Internal::IntegrationKey.parse(KEY)
    key_hex = SpecVectors.app["parsed"]["integrationKey"]
    assert_equal %w[teamPublicKey relays], parsed.to_h.keys
    client = Client.new(key: KEY, logger: QUIET)
    [parsed, client].each do |holder|
      shown = [holder.inspect, holder.to_s, holder.to_h.to_s, PP.pp(holder, +""), YAML.dump(holder)]
      shown.each do |text|
        refute_includes text, key_hex
        refute_includes text, PART
      end
      assert_raises(TypeError) { Marshal.dump(holder) }
    end
  end

  test "keeps every secret out of what Ruby shows of an object that holds one, and of its JSON" do
    require "json"
    holders = SecretHolders.holders
    assert_equal 13, holders.size
    holders.each do |name, holder|
      shown = { "inspect" => holder.inspect, "to_s" => holder.to_s, "pp" => PP.pp(holder, +""),
                "YAML" => YAML.dump(holder), "as_json" => holder.as_json.inspect, "to_json" => holder.to_json,
                # The json gem asks each object its to_json, in a document too.
                "JSON.generate" => JSON.generate(holder), "in a document" => JSON.generate({ "x" => [holder] }) }
      shown.each { |how, text| assert_empty SecretHolders.shown_in(text), "#{name}: #{how}" }
      assert_raises(TypeError, name) { Marshal.dump(holder) }
    end
    # The client's JSON: its key's public parts.
    client = holders.to_h.fetch("Client")
    assert_equal({ "teamPublicKey" => SpecVectors.app["parsed"]["team"], "relays" => ["wss://relay.example"] },
                 client.as_json)
    assert_equal Internal::Json.generate(client.as_json), client.to_json
  end

  # What a process with ActiveSupport's as_json and to_json (test/support/active_support_json.rb)
  # writes of each holder of SecretHolders, alone and in a document, every string in hex (so that
  # bytes that are no text show too), and the client's as_json.
  ACTIVE_SUPPORT_SCRIPT = <<~'RUBY'
    def hexed(value)
      case value
      when Hash then value.to_h { |name, item| [hexed(name), hexed(item)] }
      when Array then value.map { |item| hexed(item) }
      when String then value.unpack1("H*")
      else value
      end
    end

    def attempt
      yield
    rescue StandardError => e
      "#{e.class}: #{e.message}".unpack1("H*")
    end

    shown = SecretHolders.holders.to_h do |name, holder|
      [name, { "as_json" => attempt { hexed(holder.as_json) },
               "in a document" => attempt { hexed({ "order" => 1, "holder" => [holder] }.as_json) },
               "to_json" => attempt { holder.to_json.unpack1("H*") },
               "to_json of a document" => attempt { { "holder" => [holder] }.to_json.unpack1("H*") } }]
    end
    client = SecretHolders.holders.to_h.fetch("Client")
    puts Sattleme::Checkout::Internal::Json.generate("shown" => shown, "client" => client.as_json)
  RUBY

  # The strings of `tree` (each written in hex), as they are.
  def unhexed(tree)
    case tree
    when Hash then tree.flat_map { |name, item| unhexed(name) + unhexed(item) }
    when Array then tree.flat_map { |item| unhexed(item) }
    when String then [[tree].pack("H*")]
    else [tree.to_s]
    end
  end

  test "keeps every secret out of ActiveSupport's JSON, which Rails writes of any object it logs or renders" do
    # In a process of its own: ActiveSupport changes every object.
    output = IO.popen([RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-I", File.join(ROOT, "test"),
                       "-r", "support/active_support_json", "-r", "sattleme/checkout", "-r", "support/secret_holders",
                       "-e", ACTIVE_SUPPORT_SCRIPT], &:read)
    assert_predicate $CHILD_STATUS, :success?
    result = Internal::Json.parse(output)
    assert_equal 13, result["shown"].size
    result["shown"].each do |name, ways|
      ways.each { |how, hexed| assert_empty SecretHolders.shown_in(unhexed(hexed).join("\n")), "#{name}: #{how}" }
    end
    assert_equal({ "teamPublicKey" => SpecVectors.app["parsed"]["team"], "relays" => ["wss://relay.example"] },
                 result["client"])
  end

  DAMAGED = [
    ["empty", ""],
    ["another prefix", KEY.sub("sattleme_ck_", "sattleme_other_")],
    ["a later format's prefix", KEY.sub("sattleme_ck_", "sattleme_ck2_")],
    ["the prefix sattleme_ without ck_", KEY.sub("sattleme_ck_", "sattleme_")],
    ["no prefix", KEY.delete_prefix("sattleme_ck_")],
    ["a link holding its parts", "https://pay.example/pay##{TEAM}.#{PART}.#{RELAYS}"],
    ["a part missing", "sattleme_ck_#{TEAM}.#{PART}"],
    ["a part too many", "#{KEY}.#{RELAYS}"],
    ["a key cut short", KEY[0...-3]],
    ["a team cut short", "sattleme_ck_#{TEAM[1..]}.#{PART}.#{RELAYS}"],
    ["a key too long", "sattleme_ck_#{TEAM}.#{PART}AA.#{RELAYS}"],
    ["padding", "sattleme_ck_#{TEAM}=.#{PART}.#{RELAYS}"],
    ["standard base64", "sattleme_ck_+#{TEAM[1..]}.#{PART}.#{RELAYS}"],
    ["unused bits set", "sattleme_ck_#{TEAM[0...-1]}b.#{PART}.#{RELAYS}"],
    ["no relay", "sattleme_ck_#{TEAM}.#{PART}."],
    ["a relay that is not one", "sattleme_ck_#{TEAM}.#{PART}.bG9jYWxob3N0"],
    ["spaces", " #{KEY}"],
    # Strict UTF-8 keeps it: U+FEFF then "relay…" is no relay's host (SPEC.md §8, step 5).
    ["a relays part starting with a byte order mark", "sattleme_ck_#{TEAM}.#{PART}.#{with_bom(RELAYS)}"],
    ["not a String", 42],
    ["nil", nil]
  ].freeze

  DAMAGED.each do |name, text|
    test "refuses #{name}, without the key in the message" do
      error = error_of { Internal::IntegrationKey.parse(text) }
      assert_instance_of InvalidKeyError, error
      assert_equal "invalid_key", error.code
      refute_predicate error, :retryable?
      refute_includes error.message, PART
      refute_includes error.message, SpecVectors.app["parsed"]["integrationKey"]
    end
  end

  test "reads a key in US-ASCII or binary, as an environment variable may give it" do
    [KEY.dup.force_encoding(Encoding::US_ASCII), KEY.b].each do |text|
      assert_equal SpecVectors.app["parsed"]["team"], Internal::IntegrationKey.parse(text).team_public_key
    end
  end

  test "refuses a key at construction" do
    assert_raises(InvalidKeyError) { Client.new(key: "nope") }
    assert_raises(InvalidKeyError) { Client.new }
  end
end
