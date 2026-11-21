# frozen_string_literal: true

require_relative "test_helper"
require "English"

# What the gem gives and takes (SPEC.md §3), as JSON exactly: the names and order of every field,
# amounts as strings of digits, dates as integers; an invoice another implementation stored is
# checked, and the other way round.
class ModelsTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  NOW = 1_791_378_000
  PAYMENT_HASH = TestLightning.preimage_pair(10)[1]
  BOLT11 = TestLightning.make_invoice(payment_hash: PAYMENT_HASH, timestamp: NOW, amount_msat: 49_000_000,
                                      description_hash: TestLightning.metadata_hash("[]"), expiry_seconds: 900)
  ADDRESS = TestChain.deposit_address(1)

  def invoice(**fields)
    Invoice.new(ref: "ORD-1", bolt11: BOLT11, payment_hash: PAYMENT_HASH,
                verify_url: "https://breez.tips/lnurlp/verify/#{PAYMENT_HASH}", onchain_address: ADDRESS,
                payment_uri: Addresses.payment_uri(ADDRESS, 49_000, BOLT11), sats: "49000",
                fiat: Fiat.new(amount: "24.50", currency: "CHF", minor: "2450", digits: 2),
                rate: RateInfo.new(source: "kraken", currency: "CHF", price: "69012.5", fetched_at: NOW, time: nil),
                note: "Order 1", created_at: NOW, expires_at: NOW + 900, checkout_url: nil,
                redirect_url: nil, **fields)
  end

  test "writes an Invoice with the specification's names, in its order" do
    assert_equal %w[ref bolt11 paymentHash verifyUrl onchainAddress paymentUri sats fiat rate note createdAt expiresAt
                    checkoutUrl redirectUrl], invoice.to_h.keys
    assert_equal %w[amount currency minor digits], invoice.to_h["fiat"].keys
    assert_equal %w[source currency price fetchedAt time], invoice.to_h["rate"].keys
    assert_equal Json.generate(invoice.to_h), invoice.to_json
    assert_equal invoice.to_h, invoice.as_json
    assert_equal invoice.to_json, invoice.to_json(:any, :arguments)
  end

  test "writes a DeclaredInvoice, a Merchant, a Rest" do
    declared = DeclaredInvoice.new(**invoice.to_h.then do |json|
      { ref: json["ref"], bolt11: json["bolt11"], payment_hash: json["paymentHash"], verify_url: json["verifyUrl"],
        onchain_address: json["onchainAddress"], payment_uri: json["paymentUri"], sats: json["sats"],
        fiat: invoice.fiat, note: json["note"], created_at: json["createdAt"], expires_at: json["expiresAt"],
        declared_at: NOW + 3 }
    end)
    assert_equal %w[ref bolt11 paymentHash verifyUrl onchainAddress paymentUri sats fiat note createdAt expiresAt
                    declaredAt], declared.to_h.keys
    assert_equal({ "businessName" => "Sunrise Bakery", "minSats" => "1", "maxSats" => "100000000",
                   "onchainAddresses" => 3 },
                 Merchant.new(business_name: "Sunrise Bakery", min_sats: "1", max_sats: "100000000",
                              onchain_addresses: 3).to_h)
    assert_equal %w[sats bolt11 paymentUri], Rest.new(sats: "29000", bolt11: nil, payment_uri: nil).to_h.keys
  end

  # Every type an integrator holds, as SPEC.md §3 writes it: [name, value, its JSON].
  def held_types
    rest = Rest.new(sats: "29000", bolt11: nil, payment_uri: "bitcoin:#{ADDRESS}?amount=0.00029")
    declared = DeclaredInvoice.new(ref: "ORD-1", bolt11: nil, payment_hash: nil, verify_url: nil,
                                   onchain_address: ADDRESS, payment_uri: "bitcoin:#{ADDRESS}?amount=0.00049",
                                   sats: "49000", fiat: nil, note: "ORD-1", created_at: NOW, expires_at: NOW + 900,
                                   declared_at: NOW + 3)
    merchant = Merchant.new(business_name: "Sunrise Bakery", min_sats: "1", max_sats: "100000000", onchain_addresses: 3)
    [["Invoice", invoice, Json.generate(invoice.to_h)],
     ["DeclaredInvoice", declared,
      "{\"ref\":\"ORD-1\",\"bolt11\":null,\"paymentHash\":null,\"verifyUrl\":null,\"onchainAddress\":\"#{ADDRESS}\"," \
      "\"paymentUri\":\"bitcoin:#{ADDRESS}?amount=0.00049\",\"sats\":\"49000\",\"fiat\":null,\"note\":\"ORD-1\"," \
      "\"createdAt\":#{NOW},\"expiresAt\":#{NOW + 900},\"declaredAt\":#{NOW + 3}}"],
     ["Merchant", merchant,
      '{"businessName":"Sunrise Bakery","minSats":"1","maxSats":"100000000","onchainAddresses":3}'],
     ["Rest", rest, "{\"sats\":\"29000\",\"bolt11\":null,\"paymentUri\":\"bitcoin:#{ADDRESS}?amount=0.00029\"}"],
     ["Fiat", invoice.fiat, '{"amount":"24.50","currency":"CHF","minor":"2450","digits":2}'],
     ["RateInfo", invoice.rate,
      "{\"source\":\"kraken\",\"currency\":\"CHF\",\"price\":\"69012.5\",\"fetchedAt\":#{NOW},\"time\":null}"],
     ["open", PaymentStatus.open(expires_at: NOW, received: "20000", rest: rest),
      "{\"state\":\"open\",\"expiresAt\":#{NOW},\"received\":\"20000\",\"rest\":#{rest.to_json}}"],
     ["unconfirmed", PaymentStatus.unconfirmed(received: "49000", confirmations: 1, txids: ["ab" * 32]),
      "{\"state\":\"unconfirmed\",\"received\":\"49000\",\"confirmations\":1,\"txids\":[\"#{"ab" * 32}\"]}"],
     ["paid in Lightning", PaymentStatus.paid_lightning("cd" * 32),
      "{\"state\":\"paid\",\"method\":\"lightning\",\"preimage\":\"#{"cd" * 32}\"}"],
     ["paid on-chain", PaymentStatus.paid_onchain(received: "49000", txids: ["ab" * 32]),
      "{\"state\":\"paid\",\"method\":\"onchain\",\"received\":\"49000\",\"txids\":[\"#{"ab" * 32}\"]}"],
     ["paid mixed", PaymentStatus.paid_mixed(received: "49000", txids: [], preimages: ["cd" * 32]),
      "{\"state\":\"paid\",\"method\":\"mixed\",\"received\":\"49000\",\"txids\":[],\"preimages\":[\"#{"cd" * 32}\"]}"],
     ["expired", PaymentStatus.expired(received: "0"), '{"state":"expired","received":"0"}']]
  end

  test "writes every type an integrator holds as SPEC.md §3 does, with the json gem too" do
    require "json"
    held_types.each do |name, value, json|
      assert_equal json, value.to_json, name
      assert_equal Json.parse(json), Json.parse(Json.generate(value.as_json)), name
      # The json gem asks each object its to_json, in a document too.
      assert_equal json, JSON.generate(value), name
      assert_equal "{\"order\":[#{json}]}", JSON.generate({ "order" => [value] }), name
    end
  end

  # What a process with ActiveSupport's as_json and to_json (test/support/active_support_json.rb)
  # writes of each value it reads ([its class's name, its JSON], on standard input): its as_json,
  # its to_json, and a document holding it.
  ACTIVE_SUPPORT_SCRIPT = <<~RUBY
    json = Sattleme::Checkout::Internal::Json
    written = json.parse($stdin.read).map do |name, text|
      value = Sattleme::Checkout.const_get(name).from_json(text)
      [json.generate(value.as_json), value.to_json, { "order" => [value] }.to_json]
    end
    puts json.generate(written)
  RUBY

  test "writes every type an integrator holds as SPEC.md §3 does, with ActiveSupport too (Rails)" do
    types = held_types
    input = Json.generate(types.map { |_, value, json| [value.class.name.split("::").last, json] })
    output = IO.popen([RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-I", File.join(ROOT, "test"),
                       "-r", "support/active_support_json", "-r", "sattleme/checkout", "-e", ACTIVE_SUPPORT_SCRIPT],
                      "r+") do |io|
      io.write(input)
      io.close_write
      io.read
    end
    assert_predicate $CHILD_STATUS, :success?
    Json.parse(output).zip(types).each do |(as_json, to_json, document), (name, _, json)|
      assert_equal Json.parse(json), Json.parse(as_json), name
      assert_equal json, to_json, name
      assert_equal({ "order" => [Json.parse(json)] }, Json.parse(document), name)
    end
  end

  test "writes each PaymentStatus with the members of its state alone" do
    rest = Rest.new(sats: "29000", bolt11: nil, payment_uri: "bitcoin:#{ADDRESS}?amount=0.00029")
    {
      PaymentStatus.open(expires_at: NOW, received: "0", rest: nil) =>
        '{"state":"open","expiresAt":1791378000,"received":"0","rest":null}',
      PaymentStatus.open(expires_at: NOW, received: "20000", rest: rest) =>
        '{"state":"open","expiresAt":1791378000,"received":"20000","rest":{"sats":"29000","bolt11":null,' \
        "\"paymentUri\":\"bitcoin:#{ADDRESS}?amount=0.00029\"}}",
      PaymentStatus.unconfirmed(received: "49000", confirmations: 1, txids: ["ab" * 32]) =>
        "{\"state\":\"unconfirmed\",\"received\":\"49000\",\"confirmations\":1,\"txids\":[\"#{"ab" * 32}\"]}",
      PaymentStatus.paid_lightning("cd" * 32) =>
        "{\"state\":\"paid\",\"method\":\"lightning\",\"preimage\":\"#{"cd" * 32}\"}",
      PaymentStatus.paid_onchain(received: "49000", txids: ["ab" * 32]) =>
        "{\"state\":\"paid\",\"method\":\"onchain\",\"received\":\"49000\",\"txids\":[\"#{"ab" * 32}\"]}",
      PaymentStatus.paid_mixed(received: "49000", txids: [], preimages: ["cd" * 32]) =>
        "{\"state\":\"paid\",\"method\":\"mixed\",\"received\":\"49000\",\"txids\":[]," \
        "\"preimages\":[\"#{"cd" * 32}\"]}",
      PaymentStatus.expired(received: "0") => '{"state":"expired","received":"0"}'
    }.each do |status, json|
      assert_equal json, status.to_json
      assert_equal status, PaymentStatus.from_json(json)
      assert_equal status.final?, status.paid? || status.expired?
    end
    # Frozen: what the gem gives is never changed under it.
    assert_predicate PaymentStatus.paid_onchain(received: "1", txids: ["ab" * 32]).txids, :frozen?
  end

  test "reads back what it writes, its dates as integers, String or Symbol names" do
    read = Invoice.from_json(invoice.to_json)
    assert_equal invoice, read
    assert_kind_of Integer, read.created_at
    assert_kind_of Integer, read.fiat.digits
    assert_kind_of Fiat, read.fiat
    assert_kind_of RateInfo, read.rate
    assert_equal invoice, Invoice.from_h(invoice.to_h.transform_keys(&:to_sym))
    assert_raises(ArgumentError) { Invoice.from_json("{") }
    assert_raises(ArgumentError) { Invoice.from_h([]) }
    status = PaymentStatus.from_json('{"state":"unconfirmed","received":"1","confirmations":2.0,"txids":[]}')
    assert_equal 2, status.confirmations
    assert_kind_of Integer, status.confirmations
  end

  test "reads back no member left out: absent is not null (SPEC.md §2), but an Invoice's onchainAddress" do
    json = Json.parse(invoice.to_json)
    (json.keys - ["onchainAddress"]).each do |name|
      error = assert_raises(ArgumentError, name) { Invoice.from_h(json.except(name)) }
      assert_includes error.message, name
      assert_raises(ArgumentError, name) { Invoice.from_json(Json.generate(json.except(name))) }
    end
    %w[amount currency minor digits].each do |name|
      assert_raises(ArgumentError, name) { Invoice.from_h(json.merge("fiat" => json["fiat"].except(name))) }
    end
    # A rate its source did not date holds `time` as null, never without it.
    assert_raises(ArgumentError) { Invoice.from_h(json.merge("rate" => json["rate"].except("time"))) }
    # An invoice stored without an address may leave its address out (SPEC.md §22): none.
    assert_nil Invoice.from_h(json.except("onchainAddress")).onchain_address
    declared = json.except("rate", "checkoutUrl", "redirectUrl").merge("declaredAt" => NOW)
    assert_equal NOW, DeclaredInvoice.from_h(declared).declared_at
    assert_raises(ArgumentError) { DeclaredInvoice.from_h(declared.except("declaredAt")) }
    assert_nil DeclaredInvoice.from_h(declared.except("onchainAddress")).onchain_address
    merchant = { "businessName" => "Sunrise Bakery", "minSats" => "1", "maxSats" => "2", "onchainAddresses" => 0 }
    assert_raises(ArgumentError) { Merchant.from_h(merchant.except("onchainAddresses")) }
    assert_raises(ArgumentError) { Rest.from_h({ "sats" => "29000", "bolt11" => nil }) }
  end

  test "reads back a PaymentStatus with the members of its state, each there" do
    assert_equal PaymentStatus.expired(received: "0"), PaymentStatus.from_h({ "state" => "expired", "received" => "0" })
    assert_raises(ArgumentError) { PaymentStatus.from_h({ "state" => "expired" }) }
    assert_raises(ArgumentError) { PaymentStatus.from_json('{"state":"open","expiresAt":1,"received":"0"}') }
    assert_raises(ArgumentError) { PaymentStatus.from_h({ "state" => "paid", "method" => "lightning" }) }
    assert_raises(ArgumentError) { PaymentStatus.from_h({ "state" => "paid", "preimage" => "cd" * 32 }) }
    # A method is no state, nor a state a method.
    assert_raises(ArgumentError) { PaymentStatus.from_h({ "state" => "lightning", "preimage" => "cd" * 32 }) }
    open = { "expiresAt" => 1, "received" => "0", "rest" => nil }
    assert_raises(ArgumentError) { PaymentStatus.from_h(open.merge("state" => "paid", "method" => "open")) }
    assert_raises(ArgumentError) { PaymentStatus.from_h({ "state" => "settled" }) }
    assert_raises(ArgumentError) { PaymentStatus.from_h([]) }
  end

  # The JSON text another implementation stores: its numbers as JavaScript writes them.
  def stored_elsewhere
    "{\"ref\":\"ORD-1\",\"bolt11\":\"#{BOLT11}\",\"paymentHash\":\"#{PAYMENT_HASH}\"," \
      "\"verifyUrl\":\"https://breez.tips/lnurlp/verify/#{PAYMENT_HASH}\",\"onchainAddress\":\"#{ADDRESS}\"," \
      "\"paymentUri\":\"#{invoice.payment_uri}\",\"sats\":\"49000\"," \
      "\"fiat\":{\"amount\":\"24.50\",\"currency\":\"CHF\",\"minor\":\"2450\",\"digits\":2}," \
      "\"rate\":{\"source\":\"kraken\",\"currency\":\"CHF\",\"price\":\"69012.5\",\"fetchedAt\":#{NOW}," \
      "\"time\":null}," \
      "\"note\":\"Order 1\",\"createdAt\":#{NOW},\"expiresAt\":#{NOW + 900},\"checkoutUrl\":null,\"redirectUrl\":null}"
  end

  test "is the JSON another implementation stores, and checks the invoices it stored" do
    assert_equal stored_elsewhere, invoice.to_json
    expected = Order::Stored.new(ref: "ORD-1",
                                 lightning: Lnurl::LightningInvoice.new(bolt11: BOLT11, payment_hash: PAYMENT_HASH,
                                                                        verify_url: invoice.verify_url,
                                                                        expires_at: NOW + 900),
                                 onchain_address: ADDRESS, sats: 49_000, expires_at: NOW + 900)
    [stored_elsewhere, Json.parse(stored_elsewhere), Json.parse(stored_elsewhere).transform_keys(&:to_sym), invoice,
     Invoice.from_json(stored_elsewhere)].each do |stored|
      assert_equal expected, Order.check_stored_invoice(stored)
    end
    # A DeclaredInvoice is one too.
    declared = DeclaredInvoice.from_h(Json.parse(stored_elsewhere).merge("declaredAt" => NOW))
    assert_equal expected, Order.check_stored_invoice(declared)
  end

  {
    "sats as a number" => ->(json) { json.merge("sats" => 49_000) },
    "sats of another amount" => ->(json) { json.merge("sats" => "48000") },
    "an end that is not the invoice's" => ->(json) { json.merge("expiresAt" => json["expiresAt"] + 1) },
    "an end in a string" => ->(json) { json.merge("expiresAt" => json["expiresAt"].to_i.to_s) },
    "another payment hash" => ->(json) { json.merge("paymentHash" => "00" * 32) },
    "a payment hash in upper case" => ->(json) { json.merge("paymentHash" => json["paymentHash"].upcase) },
    "a verify URL in http" => ->(json) { json.merge("verifyUrl" => "http://breez.tips/x") },
    "a payment hash without an invoice" => ->(json) { json.merge("bolt11" => nil) },
    "neither an invoice nor an address" => lambda do |json|
      json.merge("bolt11" => nil, "paymentHash" => nil, "verifyUrl" => nil, "onchainAddress" => nil)
    end,
    "an address of testnet" => lambda { |json|
      json.merge("onchainAddress" => "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
    },
    "an address without its reference" => ->(json) { json.except("ref") },
    "an invoice of testnet" => lambda do |json|
      testnet = TestLightning.make_invoice(payment_hash: PAYMENT_HASH, timestamp: NOW, amount_msat: 49_000_000,
                                           network: "tb", expiry_seconds: 900)
      json.merge("bolt11" => testnet)
    end
  }.each do |name, change|
    test "refuses a stored invoice with #{name}" do
      error = assert_raises(InvalidOrderError) { Order.check_stored_invoice(change.call(Json.parse(stored_elsewhere))) }
      assert_equal "invoice", error.param
    end
  end

  test "refuses what is no stored invoice at all" do
    [nil, 5, "", "[]", "not JSON", [], Object.new].each do |value|
      assert_raises(InvalidOrderError, value.inspect) { Order.check_stored_invoice(value) }
    end
  end

  test "reads an invoice of an order paid on-chain only, and one without an address field" do
    onchain = Json.parse(stored_elsewhere).merge("bolt11" => nil, "paymentHash" => nil, "verifyUrl" => nil)
    stored = Order.check_stored_invoice(onchain)
    assert_equal [nil, ADDRESS], [stored.lightning, stored.onchain_address]
    lightning = Order.check_stored_invoice(Json.parse(stored_elsewhere).except("onchainAddress", "ref"))
    assert_nil lightning.onchain_address
    assert_nil lightning.ref
  end
end
