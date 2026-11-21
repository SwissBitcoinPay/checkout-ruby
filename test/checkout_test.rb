# frozen_string_literal: true

require_relative "test_helper"

# Checkout links (SPEC.md §30): asked with the order, published on a majority of the merchant's
# relays before the invoice is declared, read by the merchant's web app with what its URL holds
# alone.
class CheckoutTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(
      @merchant.channel_value(100, "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN }), 100
    )
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, rate_source: ->(_) { "99000" },
               **)
  end

  # Every event the relays received, in the order the first relay received them.
  def received = @merchant.net.get(@merchant.key_relays[0]).received

  def checkout?(event) = event["tags"].any? { |tag| tag[0] == "expiration" }

  # The link of a checkout URL, read as the page reads it, with its record from the relays: once
  # every relay holds it (`everywhere`), else a majority (a relay that asks to authenticate may
  # refuse a copy past the quorum, its connection authenticated by the next publication meanwhile).
  def open_link(url, everywhere: true)
    assert url.start_with?("#{ORIGIN}/pay#c."), "#{url} is no link of the web app"
    fragment = CheckoutLinks.parse_fragment(url[url.index("#")..])
    raise "Not a link: #{fragment.status}" unless fragment.status == :link

    keys = CheckoutLinks.keys(fragment.link_key)
    # On a majority before the call returns, on the others meanwhile.
    copies = eventually do
      found = fragment.relays.map do |relay|
        @merchant.net.get(relay).events.find do |value|
          value["pubkey"] == fragment.author && value["tags"].any? { |name, d| name == "d" && d == keys.address }
        end
      end
      held = found.count(&:itself)
      (everywhere ? held == found.size : held >= Relay.majority(found.size)) && found
    end
    event = copies.compact[0]
    assert Events.valid?(event)
    envelope = Json.parse(Nip44.decrypt(event["content"], keys.encryption_key))
    assert_equal "checkout", envelope["t"]
    { fragment: fragment, event: event, copies: copies, value: envelope["v"],
      record: CheckoutLinks.parse_value(envelope["v"]) }
  end

  # create_invoice with checkout

  test "publishes the link before the declaration, and gives its URL" do
    invoice = client.create_invoice(ref: "ORD-1042", fiat: { amount: "24.50", currency: "CHF" }, note: "Order 1042",
                                    checkout: true, redirect_url: "https://shop.example/orders/1042/thanks")
    made = @merchant.made_invoices[0]
    assert_equal "https://shop.example/orders/1042/thanks", invoice.redirect_url
    # JSON as is, with exactly the fields of SPEC.md §3: no secret of the link.
    assert_equal %w[ref bolt11 paymentHash verifyUrl onchainAddress paymentUri sats fiat rate note createdAt
                    expiresAt checkoutUrl redirectUrl].sort, Json.parse(invoice.to_json).keys.sort

    link = open_link(invoice.checkout_url)
    event = link[:event]
    # On every relay of the merchant, which the URL names.
    assert_equal @merchant.key_relays, link[:fragment].relays
    assert(link[:copies].all? { |copy| copy && copy["id"] == event["id"] })
    # The link first, then the declaration: a link never names an invoice its URL was not given for.
    eventually { received.size == 2 }
    assert_equal(%w[link declaration], received.map { |e| checkout?(e) ? "link" : "declaration" })
    # Its own author, not the sale's; dropped by the relays a week after the invoice's end.
    refute_equal Derive.sale_keys(@merchant.integration_key, "ORD-1042")[2], event["pubkey"]
    assert_equal [["d", CheckoutLinks.keys(link[:fragment].link_key).address],
                  ["expiration", (invoice.expires_at + 604_800).to_s]], event["tags"]
    assert_equal @merchant.now, event["created_at"]
    assert_equal({ "version" => 1, "businessName" => "Sunrise Bakery", "invoice" => made.pr, "verifyUrl" => made.verify,
                   "fiat" => { "minor" => 2450, "digits" => 2, "currency" => "CHF" }, "note" => "Order 1042",
                   "redirectUrl" => "https://shop.example/orders/1042/thanks" }, link[:value])
    assert_equal [Integer(invoice.sats, 10), "shop.example"], [link[:record].sats, link[:record].redirect_shown]
  end

  test "writes an order in sats without a price, and without a redirect URL" do
    invoice = client.create_invoice(ref: "A-1", sats: 49_000, checkout: true)
    assert_nil invoice.redirect_url
    value = open_link(invoice.checkout_url)[:value]
    assert_equal [nil, "A-1", nil], value.values_at("fiat", "note", "redirectUrl")
  end

  test "authenticates the link's publication as its author" do
    @merchant.key_relays.each { |relay| @merchant.net.get(relay).behaviour = { require_auth: true } }
    invoice = client.create_invoice(ref: "A-1", sats: 100, checkout: true)
    author = open_link(invoice.checkout_url, everywhere: false)[:fragment].author
    held = @merchant.key_relays.count { |relay| @merchant.net.get(relay).authenticated.include?(author) }
    assert_operator held, :>=, 2
  end

  test "gives a new link, with new keys, to each invoice" do
    first = client.create_invoice(ref: "A-1", sats: 100, checkout: true)
    second = client.create_invoice(ref: "A-2", sats: 100, checkout: true)
    a = open_link(first.checkout_url)[:fragment]
    b = open_link(second.checkout_url)[:fragment]
    refute_equal a.author, b.author
    refute_equal a.link_key, b.link_key
  end

  test "publishes nothing more without checkout" do
    invoice = client.create_invoice(ref: "A-1", sats: 100)
    assert_nil invoice.checkout_url
    assert_nil invoice.redirect_url
    assert_empty(received.select { |event| checkout?(event) })
  end

  test "refuses checkout when the merchant's app gives no web app, before any invoice" do
    invalid = [{}, { "checkout" => nil }, { "checkout" => "https://pay.example" },
               { "checkout" => { "origin" => "http://pay.example" } }]
    invalid.each_with_index do |checkout, index|
      value = @merchant.channel_value(200 + index, { "relays" => @merchant.key_relays }.merge(checkout))
      @merchant.publish_channel(value, 200 + index)
      assert_raises(CheckoutUnavailableError) { client.create_invoice(ref: "A-#{index}", sats: 100, checkout: true) }
      # The channel stays valid: an invoice without checkout is made.
      assert_nil client.create_invoice(ref: "B-#{index}", sats: 100).checkout_url
    end
    error = assert_raises(CheckoutUnavailableError) { client.create_invoice(ref: "C-1", sats: 100, checkout: true) }
    assert_equal ["checkout_unavailable", false], [error.code, error.retryable?]
    # Only the invoices made without checkout.
    assert_equal invalid.size, @merchant.invoices.size
  end

  [["checkout", { checkout: "yes" }], ["checkout", { checkout: 1 }],
   ["redirect_url", { redirect_url: "https://shop.example/thanks" }],
   ["redirect_url", { checkout: false, redirect_url: "https://shop.example/thanks" }],
   ["redirect_url", { checkout: true, redirect_url: "http://shop.example/thanks" }],
   ["redirect_url", { checkout: true, redirect_url: "javascript://alert(1)" }],
   ["redirect_url", { checkout: true, redirect_url: "https://user:pass@shop.example/" }],
   ["redirect_url", { checkout: true, redirect_url: 42 }],
   ["redirect_url", { checkout: true, redirect_url: "" }]].each_with_index do |(param, fields), index|
    test "refuses an invalid #{param} before any request #{index}: #{fields.inspect}" do
      error = assert_raises(InvalidOrderError) { client.create_invoice(ref: "A-1", sats: 100, **fields) }
      assert_equal param, error.param
      assert_empty @merchant.http.calls
    end
  end

  test "takes a nil redirect URL as none" do
    assert_nil client.create_invoice(ref: "A-1", sats: 100, checkout: true, redirect_url: nil).redirect_url
  end

  test "declares nothing when fewer than a majority take the link" do
    refuse_links = { refuse_event: ->(event) { checkout?(event) ? "blocked: no" : nil } }
    @merchant.net.get("wss://relay-a.test").behaviour = refuse_links
    @merchant.net.get("wss://relay-b.test").behaviour = refuse_links
    assert_raises(NetworkError) { client.create_invoice(ref: "A-1", sats: 100, checkout: true) }
    assert_empty(received.reject { |event| checkout?(event) })
    # The order gets a new invoice at once: nothing was declared.
    @merchant.net.get("wss://relay-a.test").behaviour = {}
    @merchant.net.get("wss://relay-b.test").behaviour = {}
    assert_equal "A-1", client.create_invoice(ref: "A-1", sats: 100, checkout: true).ref
    assert_equal 2, @merchant.invoices.size
  end

  test "gives no URL when the declaration fails after the link" do
    refuse_declarations = { refuse_event: ->(event) { checkout?(event) ? nil : "blocked: no" } }
    @merchant.net.get("wss://relay-a.test").behaviour = refuse_declarations
    @merchant.net.get("wss://relay-b.test").behaviour = refuse_declarations
    assert_raises(NetworkError) { client.create_invoice(ref: "A-1", sats: 100, checkout: true) }
  end

  test "gives a new link to the pending invoice of an order, with this call's redirect URL" do
    first = client.create_invoice(ref: "ORD-7", fiat: { amount: "0.02", currency: "CHF" }, note: "Order 7",
                                  checkout: true, redirect_url: "https://shop.example/7")
    pending = assert_raises(InvoicePendingError) do
      client.create_invoice(ref: "ORD-7", fiat: { amount: "0.02", currency: "CHF" }, checkout: true,
                            redirect_url: "myshop://orders/7")
    end
    assert_equal first.bolt11, pending.invoice.bolt11
    refute_nil pending.checkout_url
    refute_equal first.checkout_url, pending.checkout_url
    link = open_link(pending.checkout_url)
    assert_equal({ "version" => 1, "businessName" => "Sunrise Bakery", "invoice" => first.bolt11,
                   "verifyUrl" => first.verify_url, "fiat" => { "minor" => 2, "digits" => 2, "currency" => "CHF" },
                   "note" => "Order 7", "redirectUrl" => "myshop://orders/7" }, link[:value])
    assert_equal "myshop://", link[:record].redirect_shown
    # Without checkout, no link.
    plain = assert_raises(InvoicePendingError) do
      client.create_invoice(ref: "ORD-7", fiat: { amount: "0.02", currency: "CHF" })
    end
    assert_equal "invoice_pending", plain.code
    assert_nil plain.checkout_url
  end

  test "keeps the declaration as it was: no redirect URL in the registry" do
    client.create_invoice(ref: "A-1", sats: 100, checkout: true, redirect_url: "https://shop.example/thanks")
    # The first relay may be past the majority that took it: it gets it a little later.
    declaration = eventually { received.find { |event| !checkout?(event) } }
    assert_equal %w[invoice sale taker verifyUrl version],
                 Owner.open_declaration(declaration, @merchant.registry_key, @merchant.reader_secret).keys.sort
  end

  # A link's parts

  test "reads a link's fragment back, and only the fragments of checkout links" do
    author = Events.public_key("\x07".b * 32)
    link_key = "\x08".b * 32
    url = CheckoutLinks.url(ORIGIN, author, link_key, ["wss://relay.example", "wss://nos.lol"])
    assert_equal CheckoutLinks::Fragment.new(status: :link, author: author, link_key: link_key,
                                             relays: ["wss://relay.example", "wss://nos.lol"]),
                 CheckoutLinks.parse_fragment(url[url.index("#")..])
    assert_equal :newer, CheckoutLinks.parse_fragment("#d.a.b.c").status
    assert_equal :newer, CheckoutLinks.parse_fragment("c2.a.b.c").status
    assert_equal :invalid, CheckoutLinks.parse_fragment("c.a.b").status
    # A payment link of the point of sale: its author first, 43 characters.
    assert_equal :other, CheckoutLinks.parse_fragment("#{"A" * 43}.#{"B" * 43}").status
  end

  test "shows the host of an https URL and the scheme of an app's link" do
    assert_equal "shop.example:8443", CheckoutLinks.redirect_shown("https://shop.example:8443/a?b#c")
    assert_equal "myshop://", CheckoutLinks.redirect_shown("myshop://orders/42")
    assert_nil CheckoutLinks.redirect_shown("https://shop.example\\@evil.example")
  end
end
