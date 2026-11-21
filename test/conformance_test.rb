# frozen_string_literal: true

require_relative "test_helper"

# The gem against the conformance vectors every implementation shares (the pinned copy of the
# specification, spec/vectors/), one test per case. The vectors name parameters as the
# specification does (`rateSource`); the gem as Ruby does (`rate_source`): `outcome` writes the
# gem's as the vectors' (CONFORMANCE.camel).
class ConformanceTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  # The app's key: a client of the vectors that asks nothing in its constructor.
  KEY = SpecVectors.app["secretKey"]
  RANDOM = SecureRandom.method(:random_bytes)

  def self.vectors(name) = SpecVectors.read("vectors/#{name}")

  # A parameter's name as the vectors write it: `rate_source` is `rateSource`.
  def self.camel(param) = param.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }

  # One test per case of `cases`, named after its file, its index and its name.
  def self.each_case(file, cases, name = ->(item) { item["name"] }, &block)
    cases.each_with_index do |item, index|
      test("#{file} #{index}: #{name.call(item)}") { instance_exec(item, &block) }
    end
  end

  # The value of the block, or its error as the vectors write it: `{ error: code, param? }`.
  def outcome
    yield
  rescue Sattleme::Checkout::Error => e
    param = e.respond_to?(:param) ? e.param : nil
    { "error" => e.code }.merge(param ? { "param" => ConformanceTest.camel(param) } : {})
  end

  def http(fake) = Http::Context.new(client: fake, timeout_ms: 1000, stop: Stop.new(Cancellation::NONE))

  test "currencies.json is the gem's table" do
    assert_equal ConformanceTest.vectors("../currencies.json")["currencies"], Currencies::DIGITS
  end

  # integration-keys.json

  each_case("integration-keys.json", vectors("integration-keys.json")["cases"]) do |item|
    read = outcome do
      parsed = IntegrationKey.parse(item["key"])
      { "teamPublicKey" => parsed.team_public_key, "integrationKey" => to_hex(parsed.key),
        "relays" => parsed.relays }
    end
    assert_equal item["expected"], read
    # The client takes what the parser takes, and refuses the rest with the same error.
    built = outcome { Client.new(key: item["key"]).to_h }
    if item["expected"].key?("error")
      assert_equal item["expected"], built
    else
      assert_equal({ "teamPublicKey" => item["expected"]["teamPublicKey"],
                     "relays" => item["expected"]["relays"] }, built)
    end
  end

  # relay-urls.json

  each_case("relay-urls.json", vectors("relay-urls.json")["cases"], lambda { |item|
    "#{item["url"]}: #{item["valid"]}"
  }) do |item|
    assert_equal item["valid"], Relays.url?(item["url"])
  end

  test "relay addresses beyond relay-urls.json: a path holding a lone surrogate is refused (SPEC.md §6), a pair taken" do
    lone = Json.parse('"\\ud800"')
    refute Relays.url?("wss://relay.example/#{lone}")
    refute Relays.url?("wss://relay.example/a#{Json.parse('"\\udc00"')}b")
    assert Relays.url?("wss://relay.example/#{Json.parse('"\\ud83d\\ude00"')}")
  end

  # https-urls.json

  https = vectors("https-urls.json")

  each_case("https-urls.json urls", https["urls"], ->(item) { item["url"] }) do |item|
    url = Urls.https_url(item["url"])
    assert_value item["expected"], url && { "host" => url.host, "port" => url.port }
  end

  each_case("https-urls.json sameHost", https["sameHost"], ->(item) { "#{item["a"]} and #{item["b"]}" }) do |item|
    assert_equal item["expected"], Urls.same_host?(Urls.https_url(item["a"]), Urls.https_url(item["b"]))
  end

  each_case("https-urls.json lightningAddresses", https["lightningAddresses"], ->(item) { item["address"] }) do |item|
    assert_value item["payUrl"], Lnurl.address_url(item["address"])
  end

  # bolt11.json

  # Through the serialization the check of every event's id hashes (Events.valid_id?).
  each_case("nostr-events.json", vectors("nostr-events.json")["cases"]) do |item|
    event = item["event"]
    fields = event.values_at("pubkey", "created_at", "kind", "tags", "content")
    assert_equal item["serialized"], Events.serialization(*fields)
    assert_equal item["id"], Text.hex(Events.hash_of(*fields))
    # Signed so, the event checks out by that id.
    assert Events.valid_id?(event.merge("id" => item["id"], "sig" => "00" * 64))
  end

  each_case("bolt11.json", vectors("bolt11.json")["cases"]) do |item|
    decoded = Bolt11.decode(item["invoice"])
    read = decoded && { "network" => decoded.network, "amountMsat" => decoded.amount_msat&.to_s,
                        "timestamp" => decoded.timestamp, "expirySeconds" => decoded.expiry_seconds,
                        "paymentHash" => decoded.payment_hash, "descriptionHash" => decoded.description_hash }
    assert_value item["expected"], read
  end

  # fiat.json

  each_case("fiat.json", vectors("fiat.json")["cases"], ->(item) { item["input"].values.join(" ") }) do |item|
    assert_equal(item["expected"], outcome { Rates.parse_fiat(item["input"]).to_h })
    # As the caller gives it: Symbol names.
    symbols = item["input"].transform_keys(&:to_sym)
    assert_equal(item["expected"], outcome { Rates.parse_fiat(symbols).to_h })
  end

  # The gem's public function (SPEC.md §4, Functions), as an integrator calls it.
  each_case("fiat.json digits", vectors("fiat.json")["digits"], ->(item) { item["code"].inspect }) do |item|
    assert_value item["expected"], Sattleme::Checkout.currency_digits(item["code"])
  end

  # prices.json

  prices = vectors("prices.json")

  def read_price(text)
    decimal = text && Rates.parse_decimal(text)
    decimal && Rates.format_decimal(decimal)
  end

  each_case("prices.json text", prices["text"], ->(item) { item["price"] }) do |item|
    assert_value item["expected"], read_price(item["price"]), item["price"]
  end

  each_case("prices.json numbers", prices["numbers"], ->(item) { item["json"] }) do |item|
    assert_value item["expected"], read_price(Rates.number_text(Json.parse(item["json"])))
  end

  # conversions.json

  each_case("conversions.json", vectors("conversions.json")["cases"],
            ->(item) { "#{item["fiat"].values.join(" ")} at #{item["price"]}" }) do |item|
    assert_equal item["sats"], Rates.fiat_to_sats(item["fiat"], item["price"]).to_s
  end

  # order-text.json

  text = vectors("order-text.json")

  each_case("order-text.json refs", text["refs"], ->(item) { "#{item["ref"]}: #{item["valid"]}" }) do |item|
    expected = item["valid"] ? item["ref"] : { "error" => "invalid_order", "param" => "ref" }
    assert_equal(expected, outcome { Order.check_ref(item["ref"]) })
  end

  each_case("order-text.json notes", text["notes"], ->(item) { item["note"].inspect }) do |item|
    order = { ref: item["ref"], sats: 1 }
    order[:note] = item["note"] unless item["note"].nil?
    assert_equal(item["expected"], outcome { { "label" => Order.check(order, []).label } })
  end

  each_case("order-text.json comments", text["comments"],
            ->(item) { "#{item["label"]}, commentAllowed #{item["commentAllowed"]}" }) do |item|
    fake = FakeHttp.new { FakeHttp.answer({ "pr" => "lnbc1", "verify" => "https://x.example/v" }) }
    pay = Lnurl::PayRequest.new(callback: "https://x.example/cb", min_sendable_msat: 1000,
                                max_sendable_msat: 1_000_000, metadata: "[]",
                                comment_allowed: item["commentAllowed"].to_i)
    Lnurl.request_invoice(pay, sats: 1, expiry_seconds: 60, comment: item["label"], http: http(fake))
    sent = URI.decode_www_form(URI.parse(fake.calls[0].url).query).to_h["comment"]
    assert_value(item["sent"] ? item["label"] : nil, sent)
  end

  # invoice-checks.json

  checks = vectors("invoice-checks.json")
  # Which check an InvalidInvoiceError names, by its message.
  CHECKS = [[/Not a BOLT11/, "bolt11"], [/mainnet/, "network"], [/amount/, "amount"],
            [/does not pay the merchant/, "description_hash"], [/verify URL/, "verify_url"],
            [/longer than asked/, "duration"], [/clock/, "clock"], [/no time left/, "expired"]].freeze
  PAY = Lnurl::PayRequest.new(callback: checks["payRequest"]["callback"], min_sendable_msat: 1000,
                              max_sendable_msat: 100_000_000, metadata: checks["payRequest"]["metadata"],
                              comment_allowed: 0)

  each_case("invoice-checks.json", checks["cases"]) do |item|
    answer = Lnurl::InvoiceAnswer.new(pr: item["answer"]["pr"], verify: item["answer"]["verify"])
    result = begin
      Lnurl.check_invoice(answer, pay: PAY, sats: Integer(item["sats"], 10),
                                  duration_seconds: item["durationSeconds"].to_i, now: item["now"].to_i)
      { "valid" => true }
    rescue InvalidInvoiceError => e
      { "error" => e.code, "check" => CHECKS.find { |pattern, _| pattern.match?(e.message) }&.last || e.message }
    end
    assert_equal item["expected"], result
  end

  # payments.json

  payments = vectors("payments.json")
  INVOICE = Lnurl::LightningInvoice.new(bolt11: payments["invoice"]["bolt11"],
                                        payment_hash: payments["invoice"]["paymentHash"],
                                        verify_url: payments["invoice"]["verifyUrl"],
                                        expires_at: payments["invoice"]["expiresAt"].to_i)

  # The pay request of the merchant's Lightning address, as create_invoice reads it (Lnurl.pay_request,
  # its sendable sats, the description hash the check of its invoices compares).
  each_case("pay-requests.json", vectors("pay-requests.json")["cases"]) do |item|
    answer = item["http"]
    body = answer.key?("bodyText") ? { text: answer["bodyText"] } : { json: answer["body"] }
    fake = FakeHttp.new { { status: answer["status"].to_i }.merge(body) }
    result = outcome do
      pay = Lnurl.pay_request("shop@breez.tips", http(fake))
      min, max = pay.sendable_sats
      { "callback" => pay.callback, "sendable" => { "min" => min.to_s, "max" => max.to_s },
        "commentAllowed" => pay.comment_allowed, "descriptionHash" => pay.description_hash }
    end
    assert_equal item["expected"], result
    assert_equal ["https://breez.tips/.well-known/lnurlp/shop"], fake.calls.map(&:url)
  end

  each_case("payments.json", payments["cases"]) do |item|
    answer = item["http"]
    body = answer.key?("bodyText") ? { text: answer["bodyText"] } : { json: answer["body"] }
    fake = FakeHttp.new { { status: answer["status"].to_i }.merge(body) }
    now = item["now"].to_i
    # An invoice without an address: its status is its Lightning part's.
    result = outcome do
      part = Lnurl.verify_payment(INVOICE, http(fake), now)
      Payments.combine(Payments::Terms.new(sats: 1, expires_at: INVOICE.expires_at, address: nil), now,
                       Settled.ok(part), nil).to_h
    end
    assert_equal item["expected"], result
  end

  # The stored invoices, checked before anything is asked (SPEC.md §22).
  each_case("payments.json stored", payments["stored"]) do |item|
    valid = ->(invoice) { Order.check_stored_invoice(invoice) && { "valid" => true } }
    assert_equal(item["expected"], outcome { valid.call(item["invoice"]) })
    # As the shop stores it: its JSON text, read as every implementation reads it.
    assert_equal(item["expected"], outcome { valid.call(Json.generate(item["invoice"])) })
  end

  # rate-sources.json

  sources = vectors("rate-sources.json")

  # A source's answer of any status but 2xx (SPEC.md §26), a redirect included (§15).
  each_case("rate-sources.json statuses", sources["statuses"], ->(item) { "HTTP #{item["status"]}" }) do |item|
    fake = FakeHttp.new { { status: item["status"].to_i, json: { "bitcoin" => { "chf" => 69_012 } } } }
    context = Rates::Context.new(http: http(fake), coingecko_api_key: nil)
    assert_equal(item["expected"], outcome { Rates.fetch_rate("coingecko", "CHF", context, 1_791_378_000) })
  end

  test "rate-sources.json: the default list" do
    assert_equal sources["default"], Rates::DEFAULT_SOURCES
  end

  each_case("rate-sources.json values", sources["values"]) do |item|
    absent = !item.key?("rateSource")
    value = item["rateSource"]
    expected = item["expected"]
    if expected.key?("error")
      assert_nil Rates.source_list(value)
      assert_equal(expected, outcome { Client.new(key: KEY, rate_source: value) })
    else
      assert_equal expected["sources"], absent ? Rates::DEFAULT_SOURCES : Rates.source_list(value)
      Client.new(key: KEY, **(absent ? {} : { rate_source: value }))
    end
    # An order: invalid_order, and the client's sources when it has none.
    order = { ref: "A-1", fiat: { amount: "1", currency: "CHF" } }
    order[:rate_source] = value unless absent
    checked = outcome { Order.check(order, ["kraken"]) }
    if expected.key?("error")
      assert_equal({ "error" => "invalid_order", "param" => "rateSource" }, checked)
    else
      assert_equal absent ? ["kraken"] : expected["sources"], checked.rate_sources
    end
  end

  lists = sources["lists"]

  each_case("rate-sources.json lists", lists["cases"]) do |item|
    asked = []
    ask = lambda do |source, currency, context, now|
      asked << source
      answer = item["answers"][source]
      raise NetworkError, "#{source} is down" if answer == "network"
      raise RateError, "#{source} gave no price" if answer == "rate"
      raise UnsupportedCurrencyError.new(currency, source) if answer == "unsupported_currency"

      # The price, checked as a source's: §25.
      price, info = Rates.fetch_rate(->(_currency) { answer }, currency, context, now)
      [price, info.with(source: source)]
    end
    logger = TestLogger.new
    context = Rates::Context.new(http: http(FakeHttp.new { raise "No request" }), coingecko_api_key: nil)
    result = begin
      _, info = Rates.fetch_first_rate(item["sources"], lists["currency"], context, -> { lists["now"].to_i }, logger,
                                       ask: ask)
      { "source" => info.source, "price" => info.price, "asked" => asked }
    rescue Sattleme::Checkout::Error => e
      { "error" => e.code, "asked" => asked }
    end
    assert_equal item["expected"], result
    # Each failure the next source replaces is logged, never the last one.
    assert_equal asked.size - 1, logger.messages.size
  end

  # redirect-urls.json

  each_case("redirect-urls.json", vectors("redirect-urls.json")["cases"], ->(item) { item["url"] }) do |item|
    result = outcome { Order.check({ ref: "A-1", sats: 1, checkout: true, redirect_url: item["url"] }, []) }
    if item["expected"].key?("error")
      assert_equal item["expected"], result
      assert_nil CheckoutLinks.redirect_shown(item["url"])
    else
      assert_equal item["url"], result.redirect_url
      assert_equal item["expected"], { "shown" => CheckoutLinks.redirect_shown(item["url"]) }
    end
  end

  # checkout-links.json

  links = vectors("checkout-links.json")

  each_case("checkout-links.json origins", links["origins"], ->(item) { Json.generate(item["checkout"]) }) do |item|
    assert_value item["expected"], CheckoutLinks.origin_of(item["checkout"])
    # Whatever it holds, the channel stays valid.
    channel = { "version" => 1, "status" => "active", "role" => "integration",
                "profile" => { "businessName" => "Sunrise Bakery", "lightningAddress" => "a@breez.tips" },
                "registryKey" => "11" * 32,
                "registryReader" => "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
                "checkout" => item["checkout"], "updatedAt" => 100 }
    assert_value item["expected"], Channels.parse(channel, 100).checkout_origin
  end

  each_case("checkout-links.json derivations", links["derivations"], ->(item) { item["linkKey"] }) do |item|
    keys = CheckoutLinks.keys(hex(item["linkKey"]))
    assert_equal [item["address"], item["encryptionKey"]], [keys.address, to_hex(keys.encryption_key)]
  end

  each_case("checkout-links.json urls", links["urls"], ->(item) { item["url"] }) do |item|
    assert_equal item["url"], CheckoutLinks.url(item["origin"], item["author"], hex(item["linkKey"]), item["relays"])
  end

  each_case("checkout-links.json fragments", links["fragments"]) do |item|
    read = CheckoutLinks.parse_fragment(item["fragment"])
    shown = if read.status == :link
              { "author" => read.author, "linkKey" => to_hex(read.link_key), "relays" => read.relays }
            else
              read.status.to_s
            end
    assert_equal item["expected"], shown
  end

  each_case("checkout-links.json records", links["records"]) do |item|
    read = begin
      record = CheckoutLinks.parse_value(item["value"])
      if record
        { "sats" => record.sats.to_s, "paymentHash" => record.payment_hash, "onchainAddress" => record.onchain_address,
          "expiresAt" => record.expires_at, "redirect" => record.redirect_shown,
          "rest" => record.rest && { "author" => record.rest[0], "key" => to_hex(record.rest[1]) } }
      else
        "invalid"
      end
    rescue Records::Newer
      "newer"
    end
    assert_equal item["expected"], read
  end
end
