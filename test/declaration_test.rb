# frozen_string_literal: true

require_relative "test_helper"

class DeclarationTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  APP = SpecVectors.app
  DECLARATION = APP["declaration"]
  REAL = APP["realInvoice"]
  INTEGRATION_KEY = Text.hex_bytes(APP["parsed"]["integrationKey"])
  REGISTRY = Derive.registry(APP["channel"]["value"]["v"]["registryKey"],
                             APP["channel"]["value"]["v"]["registryReader"])
  RANDOM = SecureRandom.method(:random_bytes)

  def sale(registry = REGISTRY, ref = DECLARATION["ref"])
    Derive.sale(INTEGRATION_KEY, registry, ref)
  end

  test "give the channel's keys and the integration's mark key" do
    address, encryption_key = Derive.channel_keys(INTEGRATION_KEY)
    assert_equal APP["derived"], { "channelAddress" => address, "channelEncryptionKey" => to_hex(encryption_key),
                                   "takerKey" => to_hex(Derive.taker_key(INTEGRATION_KEY)) }
  end

  test "hold a channel the key alone opens, as the gem reads it" do
    address, encryption_key = Derive.channel_keys(INTEGRATION_KEY)
    event = APP["channel"]["event"]
    value = APP["channel"]["value"]
    assert Events.valid?(event)
    assert_equal APP["parsed"]["team"], event["pubkey"]
    assert_equal [["d", address]], event["tags"]
    assert_equal value, Json.parse(Nip44.decrypt(event["content"], encryption_key))
    channel = Channels.parse(value["v"], event["created_at"].to_i)
    assert_equal Channels::Channel.new(
      status: :active, business_name: "Sunrise Bakery", lightning_address: "sattleme02c6047f94@breez.tips",
      registry_key: value["v"]["registryKey"], registry_reader: value["v"]["registryReader"],
      relays: ["wss://relay.example"],
      # The app's channel of this vector names no web app: no checkout link.
      checkout_origin: nil,
      # Nor a tolerance of on-chain underpayments, nor a Bitcoin node: none.
      tolerance: 0, bitcoin_node: nil, updated_at: event["created_at"].to_i
    ), channel
  end

  test "give every key of the order's sale and of its declaration" do
    sale_key, secret, author = Derive.sale_keys(INTEGRATION_KEY, DECLARATION["ref"])
    assert_equal DECLARATION["saleKey"], to_hex(sale_key)
    assert_equal DECLARATION["saleSecret"], to_hex(secret)
    assert_equal DECLARATION["saleAuthor"], author
    assert_equal DECLARATION["taker"], Derive.taker_tag(Derive.taker_key(INTEGRATION_KEY), author)
    assert_equal DECLARATION["address"], Derive.registry_address(REGISTRY.key, DECLARATION["paymentHash"])
    assert_equal DECLARATION["outerKey"], to_hex(Derive.outer_key(REGISTRY.key, DECLARATION["address"], author))
    assert_equal DECLARATION["innerConversationKey"], to_hex(Nip44.conversation_key(secret, REGISTRY.reader))
  end

  test "hold a real breez.tips invoice the gem decodes" do
    decoded = Bolt11.decode(REAL["invoice"])
    assert_equal Bolt11::Invoice.new(network: "bc", amount_msat: Integer(REAL["amountMsat"], 10),
                                     timestamp: REAL["timestamp"].to_i, expiry_seconds: REAL["expirySeconds"].to_i,
                                     payment_hash: REAL["paymentHash"], description_hash: REAL["descriptionHash"]),
                 decoded
  end

  test "hold a declaration the gem opens as its sale" do
    event = DECLARATION["event"]
    assert Events.valid?(event)
    assert_equal DECLARATION["outsideBytes"].to_i,
                 Nip44.decrypt(event["content"], hex(DECLARATION["outerKey"])).bytesize
    opened = Declarations.open(event, sale)
    price = DECLARATION["fiat"].transform_values { |v| v.is_a?(Float) ? v.to_i : v }
    assert_equal Declarations::Opened.new(
      event: Events.from(event), invoice: DECLARATION["invoice"], decoded: Bolt11.decode(DECLARATION["invoice"]),
      verify_url: DECLARATION["verifyUrl"], price: price, note: DECLARATION["note"],
      declared_at: event["created_at"].to_i, rest: nil
    ), opened
    # Another order's sale does not open it.
    assert_nil Declarations.open(event, sale(REGISTRY, "ORD-1043"))
  end

  def made
    Declarations.event(sale: sale, invoice: DECLARATION["invoice"], verify_url: DECLARATION["verifyUrl"],
                       payment_hash: DECLARATION["paymentHash"],
                       price: Declarations.parse_price(DECLARATION["fiat"]), note: DECLARATION["note"],
                       created_at: DECLARATION["event"]["created_at"].to_i, random: RANDOM)
  end

  # The inside of a declaration, opened with the vector's keys.
  def inside(event)
    outside = Json.parse(Nip44.decrypt(Events.fields(event)["content"], hex(DECLARATION["outerKey"])))
    Json.parse(Nip44.decrypt(outside["v"]["sealed"], hex(DECLARATION["innerConversationKey"])))
  end

  test "opens with the vector's keys, holding what the app's holds" do
    event = made
    assert Events.valid?(event)
    assert_equal [30_078, DECLARATION["saleAuthor"], [["d", DECLARATION["address"]]]],
                 [event.kind, event.pubkey, event.tags]
    outside = Nip44.decrypt(event.content, hex(DECLARATION["outerKey"]))
    assert_equal 0, outside.bytesize % 256
    assert_equal "registry-declaration", Json.parse(outside)["t"]
    # The same declaration, field for field, as the vector's (which the app made), and its JSON text.
    assert_equal inside(DECLARATION["event"]), inside(event)
    assert_equal Json.generate(inside(DECLARATION["event"])),
                 Nip44.decrypt(Json.parse(outside)["v"]["sealed"], hex(DECLARATION["innerConversationKey"]))
    assert_equal({ "version" => 1, "invoice" => DECLARATION["invoice"], "verifyUrl" => DECLARATION["verifyUrl"],
                   "sale" => { "key" => DECLARATION["saleKey"], "fiat" => DECLARATION["fiat"],
                               "note" => DECLARATION["note"] },
                   "taker" => DECLARATION["taker"] }, inside(event))
  end

  test "is refused with another registry key or reader" do
    event = made
    assert_nil Declarations.open(event, sale(Registry.new(key: TestMerchant.bytes(9), reader: REGISTRY.reader)))
    assert_nil Declarations.open(event, sale(Registry.new(key: REGISTRY.key, reader: APP["parsed"]["team"])))
  end
end
