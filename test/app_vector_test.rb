# frozen_string_literal: true

require_relative "test_helper"

# The gem's half of the cross-check with the merchant's app: a declaration made end to end
# (create_invoice) with the app's integration key and registry (vectors/app/app.json), as the
# specification's vectors/app/implementation-declaration.json, which the app reads as the owner of
# the sale ORD-2001 and as a second sale claiming the payment of app.json's declaration. The
# vector's event is opened as the app opens it, and the gem's own declaration of the same order
# opens to the same inside JSON. Equal ids, contents or signatures are not asked: they depend on the
# order of an implementation's random draws.
class AppVectorTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  APP = SpecVectors.app
  VECTOR = SpecVectors.read("vectors/app/implementation-declaration.json")
  INTEGRATION_KEY = Text.hex_bytes(APP["parsed"]["integrationKey"])
  REGISTRY = Derive.registry(APP["channel"]["value"]["v"]["registryKey"],
                             APP["channel"]["value"]["v"]["registryReader"])

  def teardown
    @merchant&.stop
  end

  # A declaration's inside, opened as the app opens it: the outer key of its address and author
  # (the registry key), then the inner key of the sale's secret and the registry's reader.
  def open_as_app(event)
    fields = Events.fields(event)
    d = fields["tags"].find { |tag| tag[0] == "d" }[1]
    outside = Json.parse(Nip44.decrypt(fields["content"], Derive.outer_key(REGISTRY.key, d, fields["pubkey"])))
    assert_equal "registry-declaration", outside["t"]
    _, secret, = Derive.sale_keys(INTEGRATION_KEY, VECTOR["ref"])
    Nip44.decrypt(outside["v"]["sealed"], Nip44.conversation_key(secret, REGISTRY.reader))
  end

  def make
    @merchant = merchant = TestMerchant.new
    merchant.key_relays = APP["parsed"]["relays"]
    merchant.now = 1_791_380_000
    merchant.start
    merchant.net.get("wss://relay.example").store(APP["channel"]["event"])
    # breez.tips makes an invoice of the same payment as the app's declaration of ORD-1042: the app
    # reads them as two sales claiming one payment.
    hash = APP["declaration"]["paymentHash"]
    merchant.tamper = lambda do |made|
      { pr: TestLightning.make_invoice(amount_msat: made.amount_msat, payment_hash: hash,
                                       description_hash: TestLightning.metadata_hash(TestMerchant::METADATA),
                                       timestamp: merchant.now, expiry_seconds: made.expiry),
        payment_hash: hash, verify: "https://breez.tips/lnurlp/verify/#{hash}" }
    end
    client = Client.new(key: APP["secretKey"], http_client: merchant.http,
                        websocket_client: merchant.net.websocket_client, now: -> { merchant.now }, logger: QUIET,
                        rate_source: ->(_currency) { "99000" })
    invoice = client.create_invoice(ref: "ORD-2001", fiat: { amount: "0.02", currency: "CHF" }, note: "Order 2001",
                                    duration_seconds: 600)
    [invoice, merchant.net.get("wss://relay.example").received]
  end

  test "the app's declaration (implementation-declaration.json) opens, and the gem's declaration of the same order opens to the same JSON" do
    invoice, received = make
    # 0.02 CHF at 99 000 CHF/BTC: ⌈2 × 10^8 / 9 900 000⌉ = ⌈20.2…⌉ = 21 sats.
    assert_equal [VECTOR["sats"], VECTOR["invoice"], VECTOR["paymentHash"], VECTOR["verifyUrl"]],
                 [invoice.sats, invoice.bolt11, invoice.payment_hash, invoice.verify_url]
    _, _, author = Derive.sale_keys(INTEGRATION_KEY, VECTOR["ref"])
    assert_equal VECTOR["saleAuthor"], author
    assert_equal VECTOR["taker"], Derive.taker_tag(Derive.taker_key(INTEGRATION_KEY), author)
    # The only event published: the declaration.
    assert_equal 1, received.size
    mine = received[0]
    vector = VECTOR["event"]
    assert Events.valid?(vector)
    assert Events.valid?(mine)
    assert_equal [vector["kind"], vector["pubkey"], vector["created_at"], vector["tags"]],
                 [mine["kind"], mine["pubkey"], mine["created_at"], mine["tags"]]
    expected = open_as_app(vector)
    assert_equal expected, open_as_app(mine)
    assert_equal({ "version" => 1, "invoice" => VECTOR["invoice"], "verifyUrl" => VECTOR["verifyUrl"],
                   "sale" => { "key" => to_hex(Derive.sale_keys(INTEGRATION_KEY, VECTOR["ref"])[0]),
                               "fiat" => VECTOR["fiat"], "note" => VECTOR["note"] },
                   "taker" => VECTOR["taker"] }, Json.parse(expected))
  end
end
