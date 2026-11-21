# frozen_string_literal: true

require_relative "test_helper"

# Prices in a currency and their rate sources (SPEC.md §25, §26): exact conversions, each source's
# answers, custom sources, lists of sources.
class RatesTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  NOW = 1_791_385_300

  def context(fake, coingecko_api_key = nil, cancellation = Cancellation::NONE)
    Rates::Context.new(http: Http::Context.new(client: fake, timeout_ms: 1000, stop: Stop.new(cancellation)),
                       coingecko_api_key: coingecko_api_key)
  end

  # The rate `source` gives in `currency`, its HTTP answered by `route`: [RateInfo, the requests].
  def price_of(source, currency, coingecko_api_key = nil, &)
    fake = FakeHttp.new(&)
    _, info = Rates.fetch_rate(source, currency, context(fake, coingecko_api_key), NOW)
    [info, fake.calls]
  end

  def answer(json, status = 200) = FakeHttp.answer(json, status)

  # Exact conversion

  test "rounds up to the next whole sat: 24.50 CHF at 69 012 CHF/BTC" do
    # ⌈2450 × 10^8 / 6 901 200⌉: the exact quotient is 35 501.07…
    assert_equal 35_501, (2450 * 100_000_000) / 6_901_200
    refute_equal 0, (2450 * 100_000_000) % 6_901_200
    assert_equal 35_502, Sattleme::Checkout.fiat_to_sats({ amount: "24.50", currency: "CHF" }, "69012")
    assert_equal 35_502, Sattleme::Checkout.fiat_to_sats({ "amount" => "24.5", "currency" => "CHF" }, "69012.000")
  end

  test "gives exactly the quotient when it is whole" do
    # 1 CHF at 100 000 CHF/BTC: 1000 sats exactly.
    assert_equal 1000, Sattleme::Checkout.fiat_to_sats({ amount: "1.00", currency: "CHF" }, "100000")
  end

  test "reads a price as its exact decimal, a Coinbase string with 16 decimals included" do
    price = "69025.1084416666694295"
    assert_equal price, Rates.format_decimal(Rates.parse_decimal(price))
    # ⌈2450 × 10^8 × 10^16 / (690251084416666694295 × 10^2)⌉, on integers.
    dividend = 2450 * 100_000_000 * (10**16)
    divisor = 690_251_084_416_666_694_295 * 100
    assert_equal (dividend + divisor - 1) / divisor,
                 Sattleme::Checkout.fiat_to_sats({ amount: "24.50", currency: "CHF" }, price)
  end

  test "reads exponent notation" do
    assert_equal Rates::Decimal.new(units: 8, scale: 8), Rates.parse_decimal("8e-8")
    assert_equal "0.00000008", Rates.format_decimal(Rates.parse_decimal("8e-8"))
    assert_equal Rates::Decimal.new(units: 1_500_000_000_000_000_000_000, scale: 0), Rates.parse_decimal("1.5e+21")
    assert_equal Rates::Decimal.new(units: 69_012, scale: 0), Rates.parse_decimal("6.9012e4")
    assert_equal Rates::Decimal.new(units: 690_125, scale: 1), Rates.parse_decimal("69012.50")
  end

  [0, 69_012, Float::NAN, "0", "0.000", "-69012", "", "abc", "1,5", " ", " 69012", "69012\n", "0x10", "1e65",
   "1" * 65, nil, :"69012"].each_with_index do |price, index|
    test "refuses the price #{index}: #{price.inspect}" do
      assert_nil Rates.parse_decimal(price)
      assert_raises(RateError) { Sattleme::Checkout.fiat_to_sats({ amount: "1", currency: "CHF" }, price) }
    end
  end

  test "takes the currency's decimals from its table, whatever the platform's locale data" do
    assert_equal([2, 0, 3], %w[CHF JPY BHD].map { |code| Sattleme::Checkout.currency_digits(code) })
    # The app's decimals (Intl), not ISO 4217's 2: the app leaves out sales of other decimals.
    assert_equal 0, Sattleme::Checkout.currency_digits("RSD")
    # Not currencies an order is priced in: any three letters, a fund, gold, bitcoin, lower case.
    ["ABC", "CHE", "XAU", "XXX", "BTC", "SAT", "chf", "hasOwnProperty", :CHF, nil].each do |code|
      assert_nil Sattleme::Checkout.currency_digits(code), code.inspect
    end
    assert_equal({ "amount" => "1500", "currency" => "JPY", "minor" => "1500", "digits" => 0 },
                 Rates.parse_fiat({ amount: "1500", currency: "JPY" }).to_h)
    assert_equal({ "amount" => "24.50", "currency" => "CHF", "minor" => "2450", "digits" => 2 },
                 Rates.parse_fiat({ amount: "24.500", currency: "CHF" }).to_h)
    # A string in another encoding is read as its text.
    read = Rates.parse_fiat({ amount: "24.50".encode("UTF-16LE"), currency: "CHF".encode("UTF-16LE") })
    assert_equal ["24.50", "CHF", Encoding::UTF_8], [read.amount, read.currency, read.currency.encoding]
  end

  test "gives a code's decimals as create_invoice reads an order's currency: a string in any encoding as its text" do
    codes = ["CHF", "CHF".encode("UTF-16LE"), "CHF".encode("UTF-32BE"), "KWD".encode("UTF-16BE"), "JPY".b,
             "CHF".encode("US-ASCII"), "CHF".encode("ISO-8859-1"), Class.new(String).new("CHF"),
             # Not its text: broken bytes, a lower case code in another encoding.
             "CH\xFF".b, "CHF\xFF".dup.force_encoding("UTF-8"), "chf".encode("UTF-16LE"), "\xD8\x00".b]
    codes.each do |code|
      fiat = begin
        Rates.parse_fiat({ amount: "1", currency: code })
      rescue InvalidOrderError
        nil
      end
      assert_value fiat&.digits, Sattleme::Checkout.currency_digits(code), code.inspect
    end
    assert_equal([2, 2, 2, 3, 0], codes.first(5).map { |code| Sattleme::Checkout.currency_digits(code) })
  end

  [{ amount: "24.505", currency: "CHF" }, { amount: "1.5", currency: "JPY" }, { amount: "0", currency: "CHF" },
   { amount: "0.00", currency: "CHF" }, { amount: "-1", currency: "CHF" }, { amount: "1e3", currency: "CHF" },
   { amount: 24.5, currency: "CHF" }, { amount: "24.50", currency: "SAT" }, { amount: "24.50", currency: "CHFX" },
   { amount: "99999999999999999", currency: "CHF" }, { amount: "24.50" }, { currency: "CHF" }, [], "24.50 CHF",
   { amount: "24.5\xFF", currency: "CHF" }, { amount: "24.50", currency: :CHF }].each_with_index do |fiat, index|
    test "refuses the price in a currency #{index}: #{fiat.inspect}" do
      error = assert_raises(InvalidOrderError) { Rates.parse_fiat(fiat) }
      assert_equal "fiat", error.param
    end
  end

  # Rate sources

  test "knows its sources by name, and the default list" do
    assert_equal %w[coingecko mempool opennode coinbase kraken], Sattleme::Checkout::RATE_SOURCES
    assert_equal %w[coingecko mempool coinbase kraken opennode], Sattleme::Checkout::DEFAULT_RATE_SOURCES
    assert_predicate Sattleme::Checkout::RATE_SOURCES, :frozen?
  end

  test "CoinGecko, dated, with or without a Demo key" do
    route = lambda do |url|
      if url.path.end_with?("/simple/price")
        answer({ "bitcoin" => { "chf" => 69_012, "last_updated_at" => NOW - 30 } })
      else
        answer({}, 404)
      end
    end
    info, calls = price_of("coingecko", "CHF", &route)
    assert_equal({ "source" => "coingecko", "currency" => "CHF", "price" => "69012", "fetchedAt" => NOW,
                   "time" => NOW - 30 }, info.to_h)
    assert_equal "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=chf&include_last_updated_at=true",
                 calls[0].url
    refute calls[0].headers.key?("x-cg-demo-api-key")
    # CoinGecko answers HTTP 403 to a request without a User-Agent (SPEC.md §15).
    assert_equal "sattleme-Checkout/1", calls[0].headers["User-Agent"]
    _, demo = price_of("coingecko", "CHF", "demo", &route)
    assert_equal ["demo", "sattleme-Checkout/1"], demo[0].headers.values_at("x-cg-demo-api-key", "User-Agent")
    assert_raises(UnsupportedCurrencyError) { price_of("coingecko", "XYZ") { answer({ "bitcoin" => {} }) } }
    assert_raises(RateError) { price_of("coingecko", "CHF") { answer({ "nope" => 1 }) } }
  end

  test "mempool.space, dated, its 7 currencies" do
    body = { "time" => NOW - 60, "USD" => 82_977, "EUR" => 74_000, "GBP" => 63_000, "CAD" => 118_000,
             "CHF" => 69_080, "AUD" => 119_000, "JPY" => 13_187_638 }
    info, calls = price_of("mempool", "CHF") { answer(body) }
    assert_equal ["mempool", "69080", NOW - 60], [info.source, info.price, info.time]
    assert_equal "https://mempool.space/api/v1/prices", calls[0].url
    assert_raises(UnsupportedCurrencyError) { price_of("mempool", "SEK") { answer(body) } }
    assert_raises(RateError) { price_of("mempool", "CHF") { answer(body.except("time")) } }
  end

  test "OpenNode" do
    # OpenNode's answer names each currency too, which is read nowhere: left out here.
    body = { "data" => { "BTCCHF" => { "CHF" => 68_991.16, "BTC" => 0.00001449 },
                         "BTCJPY" => { "JPY" => 13_185_808.44, "BTC" => 8e-8 } } }
    info, calls = price_of("opennode", "CHF") { answer(body) }
    assert_equal "68991.16", info.price
    assert_equal "https://api.opennode.com/v1/rates", calls[0].url
    assert_raises(UnsupportedCurrencyError) { price_of("opennode", "SEK") { answer(body) } }
    assert_raises(RateError) { price_of("opennode", "CHF") { answer({ "data" => [] }) } }
  end

  test "Coinbase, its decimal strings kept as written" do
    body = { "data" => { "currency" => "BTC", "rates" => { "CHF" => "69025.1084416666694295", "USD" => "83000.1" } } }
    info, calls = price_of("coinbase", "CHF") { answer(body) }
    assert_equal "69025.1084416666694295", info.price
    assert_equal "https://api.coinbase.com/v2/exchange-rates?currency=BTC", calls[0].url
    assert_raises(UnsupportedCurrencyError) { price_of("coinbase", "SEK") { answer(body) } }
    assert_raises(RateError) do
      price_of("coinbase", "CHF") { answer({ "data" => body["data"].merge("currency" => "ETH") }) }
    end
  end

  test "Kraken, whatever the result's key, its errors read" do
    ticker = lambda { |key|
      answer({ "error" => [], "result" => { key => { "c" => ["69050.00000", "0.1"], "a" => ["1"] } } })
    }
    info, calls = price_of("kraken", "CHF") { ticker.call("XBTCHF") }
    assert_equal "69050", info.price
    assert_equal "https://api.kraken.com/0/public/Ticker?pair=XBTCHF", calls[0].url
    assert_equal "69050", price_of("kraken", "USD") { ticker.call("XXBTZUSD") }[0].price
    assert_raises(UnsupportedCurrencyError) do
      price_of("kraken", "ZZZ") { answer({ "error" => ["EQuery:Unknown asset pair"] }) }
    end
    assert_raises(RateError) { price_of("kraken", "CHF") { answer({ "error" => ["EService:Unavailable"] }) } }
    assert_raises(RateError) do
      price_of("kraken", "CHF") do
        answer({ "error" => [], "result" => { "A" => { "c" => ["1"] }, "B" => { "c" => ["2"] } } })
      end
    end
  end

  test "refuses a name it does not know" do
    assert_raises(RateError) { price_of("bitstamp", "CHF") { answer({}) } }
  end

  test "a custom source: a string or a dated price, never a number" do
    none = ->(_url) { answer({}, 404) }
    assert_equal({ "source" => "custom", "currency" => "CHF", "price" => "70000.5", "fetchedAt" => NOW, "time" => nil },
                 price_of(->(_currency) { "70000.5" }, "CHF", &none)[0].to_h)
    # A number may already have lost digits: refused.
    assert_raises(RateError) { price_of(->(_currency) { 70_000 }, "CHF", &none) }
    assert_equal NOW - 5, price_of(->(_currency) { { price: "70000", time: NOW - 5 } }, "CHF", &none)[0].time
    assert_equal NOW - 5, price_of(->(_currency) { { "price" => "70000", "time" => NOW - 5 } }, "CHF", &none)[0].time
    [0, -5, "abc", Float::INFINITY, nil, { price: 70_000 }, { price: "70000", time: "now" },
     { price: "70000", time: NOW - 0.5 }].each do |bad|
      assert_raises(RateError, bad.inspect) { price_of(->(_currency) { bad }, "CHF", &none) }
    end
    assert_raises(UnsupportedCurrencyError) do
      price_of(->(currency) { raise UnsupportedCurrencyError.new(currency, "mine") }, "CHF", &none)
    end
    # Any other error it raises is a RateError, its cause kept.
    error = assert_raises(RateError) { price_of(->(_currency) { raise ArgumentError, "broken" }, "CHF", &none) }
    assert_equal "broken", error.cause.message
    # An object with call, a Method too.
    source = Object.new
    def source.call(_currency) = "71000"
    assert_equal "71000", price_of(source, "CHF", &none)[0].price
  end

  test "a custom source that takes two parameters is given a cancellation, cancelled with the call's" do
    seen = nil
    cancellation = Cancellation.new
    source = lambda do |currency, told|
      before = told.cancelled?
      cancellation.cancel("left")
      seen = [currency, before, told.cancelled?, told.reason]
      "70000"
    end
    fake = FakeHttp.new { raise "No request" }
    assert_raises(Cancelled) { Rates.fetch_rate(source, "CHF", context(fake, nil, cancellation), NOW) }
    assert_equal ["CHF", false, true, "left"], seen
  end

  test "a custom source's cancellation is cancelled too once the call no longer needs the price" do
    # Another step of the call failed meanwhile: what waits for the price stops.
    seen = nil
    stop = Stop.new(Cancellation::NONE)
    given = Rates::Context.new(http: Http::Context.new(client: FakeHttp.new { raise "No request" }, timeout_ms: 1000,
                                                       stop: stop.child),
                               coingecko_api_key: nil)
    source = lambda do |_currency, told|
      before = told.cancelled?
      stop.stop
      seen = [before, told.cancelled?, told.reason]
      "70000"
    end
    assert_raises(Stopped) { Rates.fetch_rate(source, "CHF", given, NOW) }
    assert_equal [false, true, nil], seen
  end

  test "refuses a price older than an hour, or dated in the future" do
    none = ->(_url) { answer({}, 404) }
    dated = ->(time) { ->(_currency) { { price: "69000", time: time } } }
    assert_equal NOW - 3600, price_of(dated.call(NOW - 3600), "CHF", &none)[0].time
    assert_raises(RateError) { price_of(dated.call(NOW - 3601), "CHF", &none) }
    assert_raises(RateError) { price_of(dated.call(NOW + 3600), "CHF", &none) }
    # 5 minutes ahead at most: another server's clock.
    assert_equal NOW + 300, price_of(dated.call(NOW + 300), "CHF", &none)[0].time
    assert_raises(RateError) { price_of(dated.call(NOW + 301), "CHF", &none) }
  end

  test "an HTTP failure is a network error, retryable" do
    error = assert_raises(NetworkError) { price_of("coinbase", "CHF") { answer({}, 503) } }
    assert_predicate error, :retryable?
    assert_raises(NetworkError) { price_of("coinbase", "CHF") { raise SocketError, "fetch failed" } }
  end

  test "is a network error for 500 to 599, 408 and 429 only, and for a redirect; any other status is no price" do
    [500, 502, 599, 408, 429].each do |status|
      assert_raises(NetworkError, status.to_s) { price_of("coinbase", "CHF") { answer({}, status) } }
    end
    # A redirect is no answer (SPEC.md §15).
    [301, 302, 307, 308].each do |status|
      assert_raises(NetworkError, status.to_s) { price_of("coinbase", "CHF") { answer({}, status) } }
    end
    [100, 199, 400, 403, 404, 407, 410, 428, 430, 499, 600, 601, 999].each do |status|
      assert_raises(RateError, status.to_s) { price_of("coinbase", "CHF") { answer({}, status) } }
    end
  end

  # Lists of rate sources

  test "keeps a list of callables and names in its order, a callable alone too" do
    mine = ->(_currency) { "1" }
    assert_equal [mine], Rates.source_list(mine)
    assert_equal [mine, "kraken", mine], Rates.source_list([mine, "kraken", mine])
    assert_nil Rates.source_list(["kraken", mine, "kraken"])
    # A name as a Symbol is that name.
    assert_equal %w[kraken coingecko], Rates.source_list(%i[kraken coingecko])
    assert_nil Rates.source_list(%i[kraken kraken])
  end

  test "asks custom sources one at a time, and logs each failure replaced" do
    asked = []
    source = lambda do |name, &run|
      lambda do |_currency|
        asked << name
        run.call
      end
    end
    logger = TestLogger.new
    list = [source.call("a") { raise NetworkError, "down" }, source.call("b") { raise "broken" },
            source.call("c") { "69012.50" }, source.call("d") { "1" }]
    _, info = Rates.fetch_first_rate(list, "CHF", context(FakeHttp.new { raise "No request" }), -> { NOW }, logger)
    assert_equal %w[custom 69012.5], [info.source, info.price]
    assert_equal %w[a b c], asked
    assert_equal ["Rate source custom failed (network): down; trying custom",
                  "Rate source custom failed (rate): The custom rate source failed; trying custom"], logger.messages
  end

  test "stops at a cancellation, and at an error of another kind" do
    cancellation = Cancellation.new
    second = false
    list = [lambda do |_currency|
      cancellation.cancel("left")
      raise NetworkError, "down"
    end, lambda do |_currency|
      second = true
      "1"
    end]
    error = assert_raises(Cancelled) do
      Rates.fetch_first_rate(list, "CHF", context(FakeHttp.new { raise "No request" }, nil, cancellation), -> { NOW },
                             QUIET)
    end
    assert_equal "left", error.message
    refute second
    invalid = InvalidOrderError.new("fiat", "not for this shop")
    raised = assert_raises(InvalidOrderError) do
      Rates.fetch_first_rate([->(_currency) { raise invalid }, list[1]], "CHF",
                             context(FakeHttp.new { raise "No request" }), -> { NOW }, QUIET)
    end
    assert_same invalid, raised
    refute second
  end

  test "keeps a single source's own error" do
    own = UnsupportedCurrencyError.new("XAF", "mine")
    raised = assert_raises(UnsupportedCurrencyError) do
      Rates.fetch_first_rate([->(_currency) { raise own }], "XAF", context(FakeHttp.new { raise "No request" }),
                             -> { NOW }, QUIET)
    end
    assert_same own, raised
    assert_equal "XAF", raised.currency
  end
end
