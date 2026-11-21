# frozen_string_literal: true

require_relative "test_helper"

# create_invoice and find_invoices (SPEC.md §17 to §21, §24): the order checked, the invoice asked
# and checked, declared on a majority of the merchant's relays; one order, one invoice at a time;
# the relays of one call; rates by name.
class InvoiceTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100, "relays" => @merchant.key_relays), 100)
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  # Every declaration the relays received.
  def declarations
    @merchant.key_relays.flat_map { |url| @merchant.net.get(url).received.select { |event| event["kind"] == 30_078 } }
  end

  def made_invoices = @merchant.made_invoices

  def query_of(url) = URI.decode_www_form(URI.parse(url).query || "").to_h

  def invoice_call = @merchant.http.calls.find { |call| URI.parse(call.url).path.end_with?("/invoice") }

  # create_invoice

  test "keeps the callback's own query parameters and drops its fragment" do
    @merchant.pay = @merchant.pay.merge("callback" => "#{TestMerchant::CALLBACK}?k=1#tag")
    client.create_invoice(ref: "ORD-1", sats: 1000)
    url = URI.parse(invoice_call.url)
    assert_nil url.fragment
    assert_equal({ "k" => "1", "amount" => "1000000", "expiry" => "900", "comment" => "ORD-1" },
                 query_of(invoice_call.url))
  end

  test "refuses a pay request whose callback is not an https URL" do
    ["https://10.0.0.1/cb", "https://pay.localhost/cb", "https://user@breez.tips/cb"].each do |callback|
      @merchant.pay = @merchant.pay.merge("callback" => callback)
      assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "ORD-1", sats: 1000) }
    end
    assert(@merchant.http.calls.none? { |call| URI.parse(call.url).path.end_with?("/cb") })
  end

  test "refuses a pay request whose metadata holds a lone surrogate: it has no UTF-8 to hash" do
    # Valid JSON (an escape), but no text (SPEC.md §6, §16): neither its bytes as JSON reads them
    # nor U+FFFD in its place (TextEncoder's) are hashed.
    metadata = Internal::Json.parse('"[[\\"text/plain\\",\\"Pay \\ud800\\"]]"')
    refute Internal::Text.well_formed?(metadata)
    @merchant.pay = @merchant.pay.merge("metadata" => metadata)
    @merchant.tamper = lambda do |made|
      { pr: TestLightning.make_invoice(amount_msat: made.amount_msat, payment_hash: made.payment_hash,
                                       description_hash: TestLightning.metadata_hash(metadata),
                                       timestamp: @merchant.now, expiry_seconds: made.expiry) }
    end
    assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "ORD-1", sats: 1000) }
    assert_nil invoice_call
    assert_empty declarations
  end

  test "fails with NetworkError on a callback whose host the HTTP client cannot reach" do
    # An https URL by its rule (SPEC.md §15), but a punycode label that decodes to nothing.
    @merchant.pay = @merchant.pay.merge("callback" => "https://xn--abc.example/cb")
    assert_raises(NetworkError) { client.create_invoice(ref: "ORD-1", sats: 1000) }
  end

  test "asks, checks and declares the invoice of an order in sats" do
    invoice = client.create_invoice(ref: "ORD-1042", sats: 49_000, note: "Order 1042")
    made = made_invoices[0]
    assert_equal({ "ref" => "ORD-1042", "bolt11" => made.pr, "paymentHash" => made.payment_hash,
                   "verifyUrl" => made.verify,
                   # Within the Lightning address's bounds, and no lot of addresses: Lightning only.
                   "onchainAddress" => nil, "paymentUri" => "lightning:#{made.pr}", "sats" => "49000", "fiat" => nil,
                   "rate" => nil, "note" => "Order 1042", "createdAt" => @merchant.now,
                   "expiresAt" => @merchant.now + 900,
                   # No checkout link was asked.
                   "checkoutUrl" => nil, "redirectUrl" => nil }, invoice.to_h)
    # JSON as is: an integrator stores it with the order.
    assert_equal invoice, Invoice.from_json(invoice.to_json)
    assert_equal({ "amount" => "49000000", "expiry" => "900", "comment" => "Order 1042" }, query_of(invoice_call.url))
    # Every request, with the User-Agent every implementation sends (SPEC.md §15).
    client.get_status(invoice)
    assert_operator @merchant.http.calls.size, :>=, 3
    @merchant.http.calls.each do |call|
      assert_equal({ "Accept" => "application/json", "User-Agent" => "sattleme-Checkout/1" }, call.headers)
    end

    # Declared on every relay of the account (a majority before the call returns, the others
    # meanwhile), signed by the order's sale.
    events = eventually { declarations.then { |list| list.size == 3 && list } }
    sale_key, _, sale_author = Derive.sale_keys(@merchant.integration_key, "ORD-1042")
    assert Events.valid?(events[0])
    assert_equal sale_author, events[0]["pubkey"]
    assert_equal({ "version" => 1, "invoice" => made.pr, "verifyUrl" => made.verify,
                   "sale" => { "key" => to_hex(sale_key),
                               "fiat" => { "minor" => 49_000, "digits" => 0, "currency" => "SAT" },
                               "note" => "Order 1042" },
                   "taker" => Derive.taker_tag(Derive.taker_key(@merchant.integration_key), sale_author) },
                 Owner.open_declaration(events[0], @merchant.registry_key, @merchant.reader_secret))
  end

  test "names the order by its reference without a note, and comments only as allowed" do
    client.create_invoice(ref: "A-1", sats: 100)
    @merchant.pay = @merchant.pay.merge("commentAllowed" => 2)
    client.create_invoice(ref: "A-2", sats: "100", duration_seconds: 60)
    @merchant.pay = @merchant.pay.except("commentAllowed")
    client.create_invoice(ref: "A-3", sats: 100, duration_seconds: 3600)
    assert_equal([["A-1", 900], [nil, 60], [nil, 3600]], made_invoices.map { |made| [made.comment, made.expiry] })
    assert_equal "A-1", Owner.open_declaration(declarations[0], @merchant.registry_key,
                                               @merchant.reader_secret)["sale"]["note"]
  end

  [["ref", { sats: 1 }], ["ref", { ref: "", sats: 1 }], ["ref", { ref: "x" * 65, sats: 1 }],
   ["ref", { ref: "CMD 1", sats: 1 }], ["ref", { ref: "CMD/1", sats: 1 }], ["ref", { ref: "Bestellung-ä", sats: 1 }],
   ["ref", { ref: 1042, sats: 1 }], ["ref", { ref: :"A-1", sats: 1 }], ["ref", { ref: nil, sats: 1 }],
   ["sats", { ref: "A" }], ["sats", { ref: "A", sats: 1, fiat: { amount: "1", currency: "CHF" } }],
   ["sats", { ref: "A", sats: 0 }], ["sats", { ref: "A", sats: -1 }], ["sats", { ref: "A", sats: 1.5 }],
   ["sats", { ref: "A", sats: "0x10" }], ["sats", { ref: "A", sats: "1e3" }], ["sats", { ref: "A", sats: true }],
   ["sats", { ref: "A", sats: (2**53) + 1 }], ["sats", { ref: "A", sats: 2_100_000_000_000_001 }],
   ["sats", { ref: "A", sats: " 1" }], ["sats", { ref: "A", sats: "1" * 19 }],
   ["duration_seconds", { ref: "A", sats: 1, duration_seconds: 59 }],
   ["duration_seconds", { ref: "A", sats: 1, duration_seconds: 3601 }],
   ["duration_seconds", { ref: "A", sats: 1, duration_seconds: 90.5 }],
   ["duration_seconds", { ref: "A", sats: 1, duration_seconds: "900" }],
   ["note", { ref: "A", sats: 1, note: "n" * 101 }], ["note", { ref: "A", sats: 1, note: "line\nbreak" }],
   ["note", { ref: "A", sats: 1, note: 5 }],
   ["note", { ref: "A", sats: 1, note: "bad \xFF".dup.force_encoding("UTF-8") }],
   ["fiat", { ref: "A", fiat: { amount: 24.5, currency: "CHF" } }],
   ["fiat", { ref: "A", fiat: { amount: "24.50", currency: "SAT" } }],
   ["rate_source", { ref: "A", sats: 1, rate_source: ->(_) { "1" } }],
   ["rate_source", { ref: "A", sats: 1, rate_source: "kraken" }],
   ["rate_source", { ref: "A", fiat: { amount: "1", currency: "CHF" }, rate_source: "bitstamp" }],
   ["rate_source", { ref: "A", fiat: { amount: "1", currency: "CHF" }, rate_source: [] }],
   ["rate_source", { ref: "A", fiat: { amount: "1", currency: "CHF" }, rate_source: nil }],
   ["rate_source", { ref: "A", fiat: { amount: "1", currency: "CHF" }, rate_source: %w[kraken kraken] }],
   ["rate_source", { ref: "A", sats: 1, rate_source: %w[kraken coingecko] }],
   ["order", { ref: "A", sats: 1, amount: 1 }]].each_with_index do |(param, order), index|
    test "refuses an invalid #{param} before any request #{index}: #{order.inspect}" do
      error = assert_raises(InvalidOrderError) { client.create_invoice(**order) }
      assert_equal param, error.param
      assert_empty @merchant.invoices
      assert_empty declarations
      assert_empty @merchant.http.calls
    end
  end

  test "takes nil as a parameter not given, but for rate_source (SPEC.md §26: null is no source)" do
    invoice = client.create_invoice(ref: "A-1", sats: 100, fiat: nil, duration_seconds: nil, note: nil, checkout: nil,
                                    redirect_url: nil)
    assert_equal ["A-1", 900, nil], [invoice.note, invoice.expires_at - invoice.created_at, invoice.checkout_url]
  end

  test "accepts the edges: 64 characters, 100 for the note, 60 and 3600 seconds" do
    client.create_invoice(ref: "#{"A" * 60}.:_-", sats: 1, note: "é" * 100, duration_seconds: 60)
    eventually { declarations.size == 3 }
  end

  test "keeps an amount within the Lightning address's bounds, rounded inwards" do
    @merchant.pay = @merchant.pay.merge("minSendable" => 10_001, "maxSendable" => 1_000_999)
    sattleme = client
    found = sattleme.merchant
    assert_equal %w[11 1000], [found.min_sats, found.max_sats]
    below = assert_raises(InvalidOrderError) { sattleme.create_invoice(ref: "B-10", sats: 10) }
    assert_equal "sats", below.param
    # From 1 000 sats on, on-chain only: no address without a lot.
    above = assert_raises(OnchainUnavailableError) { sattleme.create_invoice(ref: "B-1001", sats: 1001) }
    assert_predicate above, :retryable?
    sattleme.create_invoice(ref: "B-11", sats: 11)
    sattleme.create_invoice(ref: "B-1000", sats: 1000)
    assert_equal 2, @merchant.invoices.size
  end

  def remade(made, **fields)
    TestLightning.make_invoice(amount_msat: made.amount_msat, payment_hash: made.payment_hash,
                               description_hash: TestLightning.metadata_hash(TestMerchant::METADATA),
                               timestamp: @merchant.now, expiry_seconds: 900, **fields)
  end

  {
    "an invoice of another network" => ->(m) { { pr: remade(m, network: "tb") } },
    "another amount" => ->(m) { { pr: remade(m, amount_msat: m.amount_msat - 1000) } },
    "no amount" => ->(m) { { pr: remade(m, amount_msat: nil) } },
    "another merchant's invoice" => ->(m) { { pr: remade(m, description_hash: TestLightning.metadata_hash("[]")) } },
    "a longer expiry" => ->(m) { { pr: remade(m, expiry_seconds: 901) } },
    "no expiry (3600 s)" => ->(m) { { pr: remade(m, expiry_seconds: nil) } },
    "a date 5 minutes off" => ->(m) { { pr: remade(m, timestamp: @merchant.now - 301) } },
    "a date in the future" => ->(m) { { pr: remade(m, timestamp: @merchant.now + 301) } },
    "a verify URL in http" => ->(m) { { verify: "http://breez.tips/lnurlp/verify/#{m.payment_hash}" } },
    "a verify URL on another host" => ->(m) { { verify: "https://evil.test/verify/#{m.payment_hash}" } },
    "not an invoice" => ->(_) { { pr: "lnbc1nope" } }
  }.each do |name, tamper|
    test "refuses #{name}, and declares nothing" do
      @merchant.tamper = ->(made) { instance_exec(made, &tamper) }
      assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "C-1", sats: 1000) }
      assert_empty declarations
    end
  end

  test "refuses an invoice dated within 5 minutes but already over" do
    @merchant.tamper = ->(m) { { pr: remade(m, timestamp: @merchant.now - 200, expiry_seconds: 60) } }
    assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "C-3", sats: 1000, duration_seconds: 60) }
    assert_empty declarations
  end

  test "refuses a valid invoice too large to be declared, as an InvalidInvoiceError" do
    # 70 unknown fields of 1023 words: some 72 000 characters, more than a NIP-44 plaintext holds.
    @merchant.tamper = ->(m) { { pr: remade(m, extra: Array.new(70) { [31, [0] * 1023] }) } }
    error = assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "C-4", sats: 1000) }
    assert_match(/too large to be declared/, error.message)
    assert_empty declarations
  end

  test "accepts an invoice dated within 5 minutes" do
    @merchant.tamper = ->(m) { { pr: remade(m, timestamp: @merchant.now - 300, expiry_seconds: 899) } }
    assert_equal @merchant.now - 300 + 899, client.create_invoice(ref: "C-2", sats: 1000).expires_at
  end

  test "refuses an answer without an invoice, or the service's refusal" do
    on_invoice = ->(answer) { ->(url) { url.path.end_with?("/invoice") ? answer : nil } }
    @merchant.override = on_invoice.call(FakeHttp.answer({ "verify" => "https://breez.tips/v" }))
    assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "D-1", sats: 1) }
    @merchant.override = on_invoice.call(FakeHttp.answer({ "status" => "ERROR", "reason" => "Amount out of range" },
                                                         400))
    assert_raises(NetworkError) { client.create_invoice(ref: "D-2", sats: 1) }
    @merchant.override = on_invoice.call(FakeHttp.answer({}, 502))
    assert_raises(NetworkError) { client.create_invoice(ref: "D-3", sats: 1) }
    assert_empty declarations
  end

  test "gives the invoice once a majority of the relays took its declaration" do
    @merchant.net.get("wss://relay-a.test").behaviour = { refuse: "blocked: no" }
    assert_equal "E-1", client.create_invoice(ref: "E-1", sats: 1).ref
  end

  test "gives no invoice without a majority: refusals, an unreachable relay" do
    @merchant.net.get("wss://relay-a.test").behaviour = { refuse: "blocked: no" }
    @merchant.net.get("wss://relay-b.test").behaviour = { refuse: "error: internal error" }
    assert_raises(NetworkError) { client.create_invoice(ref: "E-2", sats: 1) }
    @merchant.net.get("wss://relay-b.test").behaviour = {}
    @merchant.net.remove("wss://relay-c.test")
    assert_raises(NetworkError) { client.create_invoice(ref: "E-3", sats: 1) }
  end

  test "authenticates to a relay as the order's sale (NIP-42)" do
    @merchant.net.get("wss://relay-a.test").behaviour = { require_auth: true }
    @merchant.net.get("wss://relay-b.test").behaviour = { require_auth: true }
    client.create_invoice(ref: "E-4", sats: 1)
    sale = Derive.sale_keys(@merchant.integration_key, "E-4")[2]
    relay = @merchant.net.get("wss://relay-b.test")
    # A majority before the call returns, the others meanwhile.
    eventually { relay.authenticated.include?(sale) }
    eventually { relay.events.one? { |event| event["pubkey"] == sale } }
  end

  test "declares on the account's relays the channel names" do
    @merchant.stop
    @merchant = TestMerchant.new.start(["wss://account-a.test", "wss://account-b.test"])
    account = ["wss://account-a.test", "wss://account-b.test"]
    @merchant.publish_channel(@merchant.channel_value(100, "relays" => account), 100, @merchant.key_relays + account)
    client.create_invoice(ref: "E-5", sats: 1)
    # The channel and the declaration.
    eventually { @merchant.net.get("wss://account-b.test").events.size == 2 }
    assert_empty @merchant.net.get("wss://relay-a.test").received
  end

  test "refuses once the merchant removed the integration" do
    @merchant.publish_channel({ "version" => 1, "status" => "removed", "updatedAt" => 200 }, 200)
    assert_raises(RevokedError) { client.create_invoice(ref: "F-1", sats: 1) }
    assert_empty @merchant.http.calls
  end

  test "converts a price in a currency at its rate, and declares the price" do
    sattleme = client(rate_source: ->(_) { "69012" })
    invoice = sattleme.create_invoice(ref: "G-1", fiat: { amount: "24.50", currency: "CHF" }, note: "Order 1042")
    assert_equal "35502", invoice.sats
    assert_equal({ "amount" => "24.50", "currency" => "CHF", "minor" => "2450", "digits" => 2 }, invoice.fiat.to_h)
    assert_equal({ "source" => "custom", "currency" => "CHF", "price" => "69012", "fetchedAt" => @merchant.now,
                   "time" => nil }, invoice.rate.to_h)
    assert_equal 35_502_000, made_invoices[0].amount_msat
    assert_equal({ "minor" => 2450, "digits" => 2, "currency" => "CHF" },
                 Owner.open_declaration(declarations[0], @merchant.registry_key,
                                        @merchant.reader_secret)["sale"]["fiat"])
    # Another source for one invoice.
    other = sattleme.create_invoice(ref: "G-2", fiat: { amount: "1500", currency: "JPY" }, rate_source: lambda { |_|
      "15000000"
    })
    assert_equal %w[10000 custom 15000000], [other.sats, other.rate.source, other.rate.price]
  end

  test "refuses a converted amount outside the bounds" do
    @merchant.pay = @merchant.pay.merge("minSendable" => 100_000)
    error = assert_raises(InvalidOrderError) do
      client(rate_source: ->(_) { "100000" }).create_invoice(ref: "G-3", fiat: { amount: "0.05", currency: "CHF" })
    end
    assert_equal "fiat", error.param
  end

  # One order, one invoice at a time

  test "refuses a second invoice while the first may be paid, then allows one" do
    sattleme = client
    first = sattleme.create_invoice(ref: "H-1", sats: 1, duration_seconds: 60)
    pending = assert_raises(InvoicePendingError) { sattleme.create_invoice(ref: "H-1", sats: 1) }
    assert_equal [first.bolt11, first.expires_at, "1", nil, "H-1"],
                 [pending.invoice.bolt11, pending.invoice.expires_at, pending.invoice.sats, pending.invoice.fiat,
                  pending.invoice.note]
    # Its end, then the 120 s a late payment may still be reported in.
    @merchant.now = first.expires_at + 119
    assert_raises(InvoicePendingError) { sattleme.create_invoice(ref: "H-1", sats: 1) }
    @merchant.now = first.expires_at + 120
    second = sattleme.create_invoice(ref: "H-1", sats: 1)
    refute_equal first.bolt11, second.bolt11
    # Another order is another sale.
    sattleme.create_invoice(ref: "H-2", sats: 1)
  end

  test "refuses a new invoice for an order already paid" do
    sattleme = client
    first = sattleme.create_invoice(ref: "H-3", sats: 1, duration_seconds: 60)
    @merchant.pay_invoice(first.payment_hash)
    @merchant.now = first.expires_at + 600
    error = assert_raises(OrderPaidError) { sattleme.create_invoice(ref: "H-3", sats: 1) }
    assert_equal @merchant.invoices.fetch(first.payment_hash).preimage, error.preimage
  end

  test "refuses a new invoice for an order paid while its invoice may still be paid, never handing it out again" do
    sattleme = client
    first = sattleme.create_invoice(ref: "H-4", sats: 1, checkout: false)
    @merchant.pay_invoice(first.payment_hash)
    # Within its time: its payment checked even alone (SPEC.md §21, step 1).
    error = assert_raises(OrderPaidError) { sattleme.create_invoice(ref: "H-4", sats: 1) }
    assert_equal first.bolt11, error.invoice.bolt11
    assert_equal({ "state" => "paid", "method" => "lightning",
                   "preimage" => @merchant.invoices.fetch(first.payment_hash).preimage }, error.status.to_h)
  end

  test "gives the error of the payment check of the only invoice that may still be paid" do
    sattleme = client
    first = sattleme.create_invoice(ref: "H-5", sats: 1)
    # Its Lightning address does not answer: it may have been paid.
    @merchant.override = ->(url) { url.to_s.start_with?("https://breez.tips/lnurlp/verify/") ? { status: 503, text: "" } : nil }
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "H-5", sats: 1) }
    @merchant.override = nil
    pending = assert_raises(InvoicePendingError) { sattleme.create_invoice(ref: "H-5", sats: 1) }
    assert_equal first.bolt11, pending.invoice.bolt11
  end

  test "declares a pending invoice on a majority again before handing it out" do
    sattleme = client
    @merchant.net.get("wss://relay-a.test").behaviour = { refuse: "blocked: no" }
    @merchant.net.get("wss://relay-b.test").behaviour = { refuse: "blocked: no" }
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "H-7", sats: 1) }
    made = made_invoices[0]
    # Only relay-c holds its declaration. relay-a answers reads late: relay-b and relay-c are the
    # majority read, and the declaration found is not handed out while the others refuse it.
    @merchant.net.get("wss://relay-a.test").behaviour = { refuse: "blocked: no", query_delay_ms: 300 }
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "H-7", sats: 1) }
    # Now a majority takes it again: then, and only then, it is handed out.
    @merchant.net.get("wss://relay-a.test").behaviour = { query_delay_ms: 300 }
    @merchant.net.get("wss://relay-b.test").behaviour = {}
    pending = assert_raises(InvoicePendingError) { sattleme.create_invoice(ref: "H-7", sats: 1) }
    assert_equal made.pr, pending.invoice.bolt11
    sale = Derive.sale_keys(@merchant.integration_key, "H-7")[2]
    @merchant.key_relays.each do |url|
      eventually { @merchant.net.get(url).events.one? { |event| event["pubkey"] == sale } }
    end
    assert_equal 1, @merchant.invoices.size
  end

  test "may make another invoice when the majority read lacks one never handed out" do
    sattleme = client
    @merchant.net.get("wss://relay-a.test").behaviour = { refuse: "blocked: no" }
    @merchant.net.get("wss://relay-b.test").behaviour = { refuse: "blocked: no" }
    # Declared on relay-c alone: "do not show this invoice".
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "H-10", sats: 1) }
    # relay-a and relay-b answer first, without it: a new invoice, declared on a majority.
    @merchant.net.get("wss://relay-a.test").behaviour = {}
    @merchant.net.get("wss://relay-b.test").behaviour = {}
    @merchant.net.get("wss://relay-c.test").behaviour = { query_delay_ms: 300 }
    second = sattleme.create_invoice(ref: "H-10", sats: 1)
    assert_equal 2, @merchant.invoices.size
    assert_equal made_invoices[1].pr, second.bolt11
  end

  test "refuses a new invoice for a paid order even when another check gets no answer" do
    sattleme = client
    first = sattleme.create_invoice(ref: "H-8", sats: 1, duration_seconds: 60)
    @merchant.now = first.expires_at + 120
    second = sattleme.create_invoice(ref: "H-8", sats: 1, duration_seconds: 60)
    @merchant.pay_invoice(second.payment_hash)
    @merchant.now = second.expires_at + 600
    @merchant.override = ->(url) { url.path.end_with?(first.payment_hash) ? FakeHttp.answer({}, 502) : nil }
    error = assert_raises(OrderPaidError) { sattleme.create_invoice(ref: "H-8", sats: 1) }
    assert_equal second.bolt11, error.invoice.bolt11
    # Unpaid, one check without an answer: retry later.
    other = sattleme.create_invoice(ref: "H-9", sats: 1, duration_seconds: 60)
    @merchant.now = other.expires_at + 120
    @merchant.override = ->(url) { url.path.end_with?(other.payment_hash) ? FakeHttp.answer({}, 502) : nil }
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "H-9", sats: 1) }
  end

  test "makes one invoice when two calls for one order race" do
    sattleme = client
    results = Array.new(2) do
      Thread.new do
        sattleme.create_invoice(ref: "H-4", sats: 1)
        :fulfilled
      rescue InvoicePendingError
        :rejected
      end
    end.map(&:value)
    assert_equal %i[fulfilled rejected], results.sort
    assert_equal 1, @merchant.invoices.size
  end

  test "finds the invoices declared for an order, and needs a majority to" do
    sattleme = client(rate_source: ->(_) { "69012" })
    first = sattleme.create_invoice(ref: "H-5", fiat: { amount: "24.50", currency: "CHF" }, duration_seconds: 60)
    @merchant.now = first.expires_at + 120
    second = sattleme.create_invoice(ref: "H-5", sats: 7)
    found = sattleme.find_invoices("H-5")
    assert_equal [first.bolt11, second.bolt11], found.map(&:bolt11)
    assert_equal({ "ref" => "H-5", "bolt11" => first.bolt11, "paymentHash" => first.payment_hash,
                   "verifyUrl" => first.verify_url, "onchainAddress" => nil,
                   "paymentUri" => "lightning:#{first.bolt11}", "sats" => "35502",
                   "fiat" => { "amount" => "24.50", "currency" => "CHF", "minor" => "2450", "digits" => 2 },
                   "note" => "H-5", "createdAt" => first.created_at, "expiresAt" => first.expires_at,
                   "declaredAt" => first.created_at }, found[0].to_h)
    assert_equal ["7", nil], [found[1].sats, found[1].fiat]
    # As JSON, read back.
    assert_equal found[0], DeclaredInvoice.from_json(found[0].to_json)
    assert_empty sattleme.find_invoices("H-6")
    assert_raises(InvalidOrderError) { sattleme.find_invoices("H 6") }
    @merchant.net.remove("wss://relay-a.test")
    @merchant.net.remove("wss://relay-b.test")
    assert_raises(NetworkError) { sattleme.find_invoices("H-5") }
  end

  test "warns of a record of the order's sale of a newer format, and reads the others" do
    logger = TestLogger.new
    sattleme = client(logger: logger)
    invoice = sattleme.create_invoice(ref: "W-1", sats: 1000)
    sale = Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader),
                       "W-1")
    newer = Events.sign(sale.secret_key, SecureRandom.method(:random_bytes),
                        created_at: @merchant.now, kind: 30_078, tags: [["d", "cd" * 32]], content: "#")
    @merchant.key_relays.each { |url| @merchant.net.get(url).take(newer) }
    assert_equal [invoice.bolt11], sattleme.find_invoices("W-1").map(&:bolt11)
    assert_equal ["sattleme-checkout: a declaration or a lease of this order has a newer format than this version " \
                  "reads; update the gem"], logger.messages
  end

  # Relays: one connection each per call, a majority waited for

  test "makes an invoice over one connection per relay, earlier invoices read included" do
    sattleme = client
    first = sattleme.create_invoice(ref: "R-1", sats: 1, duration_seconds: 60)
    assert_equal({ "wss://relay-a.test" => 1, "wss://relay-b.test" => 1, "wss://relay-c.test" => 1 },
                 @merchant.net.connections)
    @merchant.now = first.expires_at + 120
    # The channel, the order's declarations page after page, the new declaration: one connection.
    sattleme.create_invoice(ref: "R-1", sats: 1, duration_seconds: 60)
    assert_equal({ "wss://relay-a.test" => 2, "wss://relay-b.test" => 2, "wss://relay-c.test" => 2 },
                 @merchant.net.connections)
    @merchant.key_relays.each do |url|
      relay = @merchant.net.get(url)
      # Every subscription closed once read, and every connection once the call is done.
      refute_empty relay.closed_subscriptions
      eventually { relay.server.open_connections.empty? }
    end
  end

  %w[mute blackhole].each do |kind|
    test "is not slowed by a relay that never answers (#{kind})" do
      if kind == "mute"
        @merchant.net.get("wss://relay-c.test").behaviour = { mute: true }
      else
        @merchant.net.remove("wss://relay-c.test")
        @merchant.net.add_blackhole("wss://relay-c.test")
      end
      sattleme = client(relay_timeout_ms: 5000)
      started = Clock.now
      sattleme.create_invoice(ref: "R-2", sats: 1)
      assert_operator Clock.now - started, :<, 1.5
      assert_equal 1, sattleme.find_invoices("R-2").size
      assert_operator Clock.now - started, :<, 3
    end
  end

  test "stops when its cancellation is cancelled, and closes its connections" do
    @merchant.key_relays.each { |url| @merchant.net.get(url).behaviour = { query_delay_ms: 2000 } }
    cancellation = Cancellation.new
    Thread.new do
      sleep 0.1
      cancellation.cancel("checkout left")
    end
    started = Clock.now
    error = assert_raises(Cancelled) do
      client(relay_timeout_ms: 5000).create_invoice(ref: "R-3", sats: 1, cancellation: cancellation)
    end
    assert_equal "checkout left", error.message
    # Not the relays' 2 s.
    assert_operator Clock.now - started, :<, 1.5
    # The relays see each connection close a moment later (a busy machine: up to a second).
    @merchant.key_relays.each { |url| eventually(2) { @merchant.net.get(url).server.open_connections.empty? } }
    assert_empty @merchant.invoices
  end

  test "stops at once with a cancellation cancelled before the call" do
    cancellation = Cancellation.new.cancel("too late")
    error = assert_raises(Cancelled) { client.create_invoice(ref: "R-4", sats: 1, cancellation: cancellation) }
    assert_equal "too late", error.reason
    assert_empty @merchant.net.connections
    error = assert_raises(InvalidOptionError) { client.create_invoice(ref: "R-4", sats: 1, cancellation: Object.new) }
    assert_equal "cancellation", error.param
  end

  # Rates by name

  test "takes a source by its name, CoinGecko with its Demo key" do
    @merchant.override = lambda do |url|
      case url.host
      when "api.coingecko.com" then FakeHttp.answer({ "bitcoin" => { "chf" => 69_012,
                                                                     "last_updated_at" => @merchant.now - 30 } })
      when "api.kraken.com" then FakeHttp.answer({ "error" => [],
                                                   "result" => { "XBTCHF" => { "c" => ["70000.0", "0.1"] } } })
      end
    end
    sattleme = client(rate_source: "coingecko", coingecko_api_key: "demo-key")
    invoice = sattleme.create_invoice(ref: "S-1", fiat: { amount: "24.50", currency: "CHF" })
    assert_equal %w[35502 coingecko 69012], [invoice.sats, invoice.rate.source, invoice.rate.price]
    call = @merchant.http.calls.find { |item| URI.parse(item.url).host == "api.coingecko.com" }
    assert_equal "demo-key", call.headers["x-cg-demo-api-key"]
    other = sattleme.create_invoice(ref: "S-2", fiat: { amount: "7", currency: "CHF" }, rate_source: :kraken)
    assert_equal %w[kraken 70000], [other.rate.source, other.rate.price]
  end

  test "refuses an unknown source when the client is made" do
    ["bitstamp", [], %w[kraken kraken], %w[kraken bitstamp], nil, "Kraken", [["kraken"]], 1].each do |rate_source|
      error = assert_raises(InvalidOptionError, rate_source.inspect) { client(rate_source: rate_source) }
      assert_equal "rate_source", error.param
    end
    [5, "", "with space", "é"].each do |key|
      error = assert_raises(InvalidOptionError, key.inspect) { client(coingecko_api_key: key) }
      assert_equal "coingecko_api_key", error.param
    end
  end

  test "without rate_source, asks the default list in order until one gives a price" do
    @merchant.override = lambda do |url|
      case url.host
      when "api.coingecko.com" then FakeHttp.answer({ "status" => { "error_code" => 429 } }, 429)
      when "mempool.space" then FakeHttp.answer({ "time" => @merchant.now - 10, "CHF" => 69_012 })
      end
    end
    logger = TestLogger.new
    invoice = client(logger: logger).create_invoice(ref: "D-1", fiat: { amount: "24.50", currency: "CHF" })
    assert_equal %w[35502 mempool 69012], [invoice.sats, invoice.rate.source, invoice.rate.price]
    asked = @merchant.http.calls.map { |call| URI.parse(call.url).host }.reject { |host| host.end_with?("breez.tips") }
    assert_equal ["api.coingecko.com", "mempool.space"], asked
    # No key given: CoinGecko is asked without one.
    call = @merchant.http.calls.find { |item| URI.parse(item.url).host == "api.coingecko.com" }
    refute call.headers.key?("x-cg-demo-api-key")
    assert_equal ["Rate source coingecko failed (network): coingecko answered HTTP 429; trying mempool"],
                 logger.messages
  end

  test "asks an order's list, in its order, and only that list" do
    @merchant.override = lambda do |url|
      case url.host
      when "api.kraken.com" then FakeHttp.answer({ "error" => ["EQuery:Unknown asset pair"] })
      when "api.coinbase.com" then FakeHttp.answer({ "data" => { "currency" => "BTC",
                                                                 "rates" => { "CHF" => "69012.00" } } })
      end
    end
    invoice = client(rate_source: "coingecko").create_invoice(ref: "D-2", fiat: { amount: "24.50", currency: "CHF" },
                                                              rate_source: %w[kraken coinbase])
    assert_equal %w[coinbase 69012], [invoice.rate.source, invoice.rate.price]
    hosts = @merchant.http.calls.map { |call| URI.parse(call.url).host }
    assert_includes hosts, "api.kraken.com"
    refute_includes hosts, "api.coingecko.com"
  end

  test "gives the last network or rate error when no source of the list has a price" do
    @merchant.override = lambda do |url|
      case url.host
      when "api.kraken.com" then FakeHttp.answer({ "error" => ["EQuery:Unknown asset pair"] })
      when "api.coinbase.com" then FakeHttp.answer({}, 503)
      end
    end
    sattleme = client
    assert_raises(NetworkError) do
      sattleme.create_invoice(ref: "D-3", fiat: { amount: "1", currency: "CHF" }, rate_source: %w[coinbase kraken])
    end
    # Only sources without the currency: unsupported_currency, naming them.
    error = assert_raises(UnsupportedCurrencyError) do
      sattleme.create_invoice(ref: "D-4", fiat: { amount: "1", currency: "THB" }, rate_source: %w[kraken mempool])
    end
    assert_equal ["None of kraken, mempool has a price in THB", "THB"], [error.message, error.currency]
    assert_empty @merchant.invoices
  end

  test "puts an order's pending invoice before a failing rate source" do
    client(rate_source: ->(_) { "69012" }).create_invoice(ref: "S-3", fiat: { amount: "1", currency: "CHF" })
    failing = client(rate_source: ->(_) { raise NetworkError, "down" })
    assert_raises(InvoicePendingError) { failing.create_invoice(ref: "S-3", fiat: { amount: "1", currency: "CHF" }) }
    assert_raises(NetworkError) { failing.create_invoice(ref: "S-4", fiat: { amount: "1", currency: "CHF" }) }
    assert_equal 1, @merchant.invoices.size
  end
end
