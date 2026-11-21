# frozen_string_literal: true

require_relative "test_helper"

# The gem's half of the cross-check with the merchant's web app for checkout links
# (vectors/app/checkout-link.json, PORTING.md "Definition of done" 3): a link the gem makes end to
# end (create_invoice with `checkout: true`) for the vector's order (same channel origin, relays,
# business's name, pay request, price, invoice and verify URL) holds exactly the vector's value, in
# a valid event of kind 30078 signed by its own author, with the tags of SPEC.md §30, whose content
# opens with the encryption key its URL's link key derives (a plaintext of a multiple of 256 bytes,
# type `checkout`); the URL is `<origin>/pay#c.<author>.<key>.<relays>` with the vector's relays.
# The vector's own event opens with its keys. Equal event ids, contents or signatures are not
# asked: they depend on the order of an implementation's random draws.
class CheckoutVectorTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTOR = SpecVectors.read("vectors/app/checkout-link.json")

  def teardown
    @merchant&.stop
  end

  def make
    @merchant = merchant = TestMerchant.new
    merchant.key_relays = VECTOR["relays"]
    merchant.now = 1_791_382_000
    # What the merchant's Lightning address answers (SPEC.md §16): its bounds, its metadata.
    merchant.pay = VECTOR["payRequest"]
    merchant.start
    merchant.publish_channel(merchant.channel_value(merchant.now - 60, "checkout" => { "origin" => VECTOR["origin"] }),
                             merchant.now - 60)
    client = Client.new(key: merchant.key, http_client: merchant.http, websocket_client: merchant.net.websocket_client,
                        now: -> { merchant.now }, logger: QUIET, rate_source: ->(_currency) { VECTOR["price"] })
    order = VECTOR["order"]
    invoice = client.create_invoice(ref: order["ref"], fiat: order["fiat"], note: order["note"],
                                    duration_seconds: order["durationSeconds"].to_i, checkout: order["checkout"],
                                    redirect_url: order["redirectUrl"])
    [invoice, merchant.net.get("wss://relay.example").received]
  end

  test "opens the vector's own event with its keys, to its value" do
    keys = CheckoutLinks.keys(hex(VECTOR["linkKey"]))
    assert_equal [VECTOR["address"], VECTOR["encryptionKey"]], [keys.address, to_hex(keys.encryption_key)]
    fragment = CheckoutLinks.parse_fragment(VECTOR["url"][VECTOR["url"].index("#")..])
    assert_equal [:link, VECTOR["author"], VECTOR["linkKey"], VECTOR["relays"]],
                 [fragment.status, fragment.author, to_hex(fragment.link_key), fragment.relays]
    event = VECTOR["event"]
    opened = Records.open(event, type: "checkout", encryption_key: keys.encryption_key, address: keys.address,
                                 author: VECTOR["author"]) { |value, _| value }
    assert_equal VECTOR["value"], opened.value
    record = CheckoutLinks.parse_value(VECTOR["value"])
    assert_equal [21, "shop.example"], [record.sats, record.redirect_shown]
  end

  test "is a link holding exactly the vector's value, in an event of its own author that its URL's key opens" do
    invoice, received = make
    # 0.02 CHF at 98 000 CHF/BTC: ⌈2 × 10^8 / 9 800 000⌉ = ⌈20.4…⌉ = 21 sats.
    assert_equal [VECTOR["sats"], VECTOR["invoice"], VECTOR["verifyUrl"], VECTOR["paymentHash"], VECTOR["expiresAt"]],
                 [invoice.sats, invoice.bolt11, invoice.verify_url, invoice.payment_hash, invoice.expires_at]
    url = invoice.checkout_url
    origin_and_path, fragment_text = url.split("#", 2)
    assert_equal "#{VECTOR["origin"]}/pay", origin_and_path
    marker, author, key, relays = fragment_text.split(".")
    assert_equal ["c", Relays.encode_list(VECTOR["relays"])], [marker, relays]
    fragment = CheckoutLinks.parse_fragment(fragment_text)
    assert_equal [:link, VECTOR["relays"]], [fragment.status, fragment.relays]
    assert_equal [author, key], [Base64.encode_url(hex(fragment.author)), Base64.encode_url(fragment.link_key)]
    keys = CheckoutLinks.keys(fragment.link_key)
    event = received.find { |candidate| candidate["pubkey"] == fragment.author }
    assert Events.valid?(event)
    assert_equal 30_078, event["kind"]
    assert_equal [["d", keys.address], ["expiration", (invoice.expires_at + 604_800).to_s]], event["tags"]
    plaintext = Nip44.decrypt(event["content"], keys.encryption_key)
    assert_equal 0, plaintext.bytesize % 256
    envelope = Json.parse(plaintext)
    assert_equal "checkout", envelope["t"]
    assert_equal VECTOR["value"], envelope["v"]
    # Its author's secret is gone with the call: the author is no key of the integration.
    refute_includes [Events.public_key(TestMerchant.bytes(2)), @merchant.team], fragment.author
  end
end
