# frozen_string_literal: true

require_relative "test_helper"

# The gem's half of the cross-check with the merchant's web app for the rest of an on-chain
# underpayment (vectors/app/checkout-rest.json): a checkout link to an invoice with an address
# (create_invoice with `checkout: true`), then a payment check that sees 20 000 of its 49 000 sats
# on-chain and asks an invoice of the rest, end to end. Everything deterministic equals the vector
# (the rest key, rest author, rest encryption key, rest record address, the link's value with its
# rest author and key, the rest record's value, the status), and the events are valid and open
# with those keys. The vector's own events open too.
class CheckoutRestVectorTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTOR = SpecVectors.read("vectors/app/checkout-rest.json")
  ADDRESS = TestChain.deposit_address("checkout-rest")

  def teardown
    @merchant&.stop
  end

  def make
    @merchant = merchant = TestMerchant.new
    merchant.key_relays = VECTOR["relays"]
    merchant.now = 1_791_382_000
    merchant.pay = VECTOR["payRequest"]
    merchant.start
    merchant.publish_channel(merchant.channel_value(merchant.now - 60, "checkout" => { "origin" => VECTOR["origin"] }),
                             merchant.now - 60)
    merchant.publish_lot([ADDRESS], merchant.now - 30)
    order = VECTOR["order"]
    client = Client.new(key: merchant.key, http_client: merchant.http, websocket_client: merchant.net.websocket_client,
                        now: -> { merchant.now }, logger: QUIET)
    invoice = client.create_invoice(ref: order["ref"], sats: order["sats"], note: order["note"],
                                    duration_seconds: order["durationSeconds"].to_i, checkout: order["checkout"],
                                    redirect_url: order["redirectUrl"])
    # 20 000 sats in the mempool, a minute later: the check asks an invoice of the 29 000 left.
    merchant.now += 60
    merchant.chain.add(ADDRESS, TestChain.payment(TestChain.txid("checkout-rest"), ADDRESS, 20_000))
    status = client.get_status(invoice)
    [invoice, status, merchant.net.get("wss://relay.example").received]
  end

  def rest_keys
    Derive.rest_keys(hex(VECTOR["integrationKey"]), VECTOR["order"]["ref"], VECTOR["onchainAddress"],
                     VECTOR["expiresAt"].to_i)
  end

  test "derives the vector's rest keys, and opens its link's and rest's events with them" do
    keys = rest_keys
    rest = VECTOR["rest"]
    assert_equal [rest["restKey"], rest["restAuthor"], rest["encryptionKey"]],
                 [to_hex(keys.key), keys.author, to_hex(keys.encryption_key)]
    assert_equal rest["address"], Derive.rest_record_address(keys.key, rest["paymentHash"])
    link = VECTOR["link"]
    link_keys = CheckoutLinks.keys(hex(link["linkKey"]))
    opened = Records.open(link["event"], type: "checkout", encryption_key: link_keys.encryption_key,
                                         address: link_keys.address, author: link["author"]) { |value, _| value }
    assert_equal link["value"], opened.value
    record = CheckoutLinks.parse_value(link["value"])
    assert_equal [rest["restAuthor"], rest["restKey"]], [record.rest[0], to_hex(record.rest[1])]
    terms = Rests::LinkTerms.new(sats: Integer(VECTOR["sats"], 10), created_at: VECTOR["createdAt"].to_i,
                                 expires_at: VECTOR["expiresAt"].to_i)
    found = Rests.open_record(rest["event"], keys, terms)
    assert_equal [rest["invoice"], 29_000], [found.invoice.bolt11, found.invoice.sats]
    assert_equal rest["value"], Json.parse(Nip44.decrypt(rest["event"]["content"], keys.encryption_key))["v"]
  end

  test "makes the vector's link value and rest record, in events that open with the vector's keys" do
    invoice, status, received = make
    assert_equal [VECTOR["onchainAddress"], VECTOR["sats"], VECTOR["createdAt"], VECTOR["expiresAt"]],
                 [invoice.onchain_address, invoice.sats, invoice.created_at, invoice.expires_at]
    assert_equal VECTOR["status"], status.to_h
    url = invoice.checkout_url
    fragment = CheckoutLinks.parse_fragment(url[url.index("#")..])
    link_keys = CheckoutLinks.keys(fragment.link_key)
    link_event = received.find { |event| event["pubkey"] == fragment.author }
    assert Events.valid?(link_event)
    assert_equal [["d", link_keys.address], ["expiration", (invoice.expires_at + 604_800).to_s]], link_event["tags"]
    link_plaintext = Nip44.decrypt(link_event["content"], link_keys.encryption_key)
    assert_equal 0, link_plaintext.bytesize % 256
    assert_equal({ "t" => "checkout", "v" => VECTOR["link"]["value"] }, Json.parse(link_plaintext))
    keys = rest_keys
    rest = VECTOR["rest"]
    rest_event = received.find { |event| event["pubkey"] == keys.author }
    assert Events.valid?(rest_event)
    assert_equal [["d", rest["address"]], ["expiration", (VECTOR["expiresAt"].to_i + 604_800).to_s]], rest_event["tags"]
    rest_plaintext = Nip44.decrypt(rest_event["content"], keys.encryption_key)
    assert_equal 0, rest_plaintext.bytesize % 256
    assert_equal({ "t" => "checkout-rest", "v" => rest["value"] }, Json.parse(rest_plaintext))
    assert_equal({ "sats" => "29000", "bolt11" => rest["invoice"],
                   "paymentUri" => "bitcoin:#{VECTOR["onchainAddress"]}?amount=0.00029&lightning=#{rest["invoice"]}" },
                 status.rest.to_h)
  end
end
