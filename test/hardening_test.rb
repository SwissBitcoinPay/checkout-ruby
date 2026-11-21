# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/tls"

# What the gem refuses or bounds beyond the conformance vectors: options, strings Ruby can hold that
# are no text (a lone surrogate, broken UTF-8), HTTP answers and the platform's HTTP client, a
# custom rate source that fails, a channel whose reading key is off the curve, the fan-out of
# payment checks, the WebSocket handshake (no redirect, its User-Agent, no compression), TLS, what
# a read keeps of a relay's events, the witnesses of an invoice.
class HardeningTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  RANDOM = SecureRandom.method(:random_bytes)

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100), 100)
  end

  def teardown
    @merchant.stop
    @closing&.each(&:close)
  end

  def closing(*servers)
    (@closing ||= []).concat(servers)
    servers.first
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  # Options

  without_get = Object.new
  [["options", { colour: "blue" }], ["options", { relayTimeoutMs: 1000 }], ["rate_source", { rate_source: "bitstamp" }],
   ["coingecko_api_key", { coingecko_api_key: 5 }],
   # 1 or more visible ASCII characters (SPEC.md §4): empty is invalid, not absent.
   ["coingecko_api_key", { coingecko_api_key: "" }],
   ["coingecko_api_key", { coingecko_api_key: "CG-key with a space" }],
   ["coingecko_api_key", { coingecko_api_key: "CG-clé" }], ["coingecko_api_key", { coingecko_api_key: :key }],
   ["http_client", { http_client: without_get }], ["http_client", { http_client: "fetch" }],
   ["websocket_client", { websocket_client: {} }], ["relay_timeout_ms", { relay_timeout_ms: 3_000_000_000 }],
   ["relay_timeout_ms", { relay_timeout_ms: 0 }], ["relay_timeout_ms", { relay_timeout_ms: 99 }],
   ["relay_timeout_ms", { relay_timeout_ms: 1000.0 }], ["http_timeout_ms", { http_timeout_ms: 1.5 }],
   ["http_timeout_ms", { http_timeout_ms: 60_001 }], ["http_timeout_ms", { http_timeout_ms: "1000" }],
   ["logger", { logger: Object.new }], ["now", { now: 5 }],
   ["random", { random: "x" }]].each_with_index do |(param, options), index|
    test "refuses #{param} #{index}: #{options.inspect} as an InvalidOptionError" do
      error = assert_raises(InvalidOptionError) { Client.new(key: @merchant.key, **options) }
      assert_equal [param, "invalid_option", false], [error.param, error.code, error.retryable?]
    end
  end

  test "checks the key first, and never puts it in an error" do
    error = assert_raises(InvalidKeyError) { Client.new(key: "#{@merchant.key}x", rate_source: "bitstamp") }
    refute_includes error.message, @merchant.key
    refute_includes error.full_message, @merchant.key
    assert_raises(InvalidKeyError) { Client.new }
  end

  test "writes its warnings to standard error by default, a line each" do
    @merchant.publish_channel(@merchant.channel_value(200).merge("version" => 2), 200)
    sattleme = Client.new(key: @merchant.key, http_client: @merchant.http,
                          websocket_client: @merchant.net.websocket_client, now: -> { @merchant.now })
    assert_output(nil, "sattleme-checkout: the integration's channel has a newer format than this version reads; " \
                       "update the gem\n") do
      sattleme.merchant
    end
  end

  test "refuses an on_status that is not callable, before any request" do
    invoice = client.create_invoice(ref: "O-2", sats: 1)
    calls = @merchant.http.calls.size
    error = assert_raises(InvalidOptionError) { client.wait_for_payment(invoice, on_status: "log") }
    assert_equal "on_status", error.param
    assert_equal calls, @merchant.http.calls.size
  end

  test "bounds wait_for_payment's interval" do
    invoice = client.create_invoice(ref: "O-1", sats: 1)
    [100, 249, 3_000_000_000, 1000.5, 60_001, "2000"].each do |interval_ms|
      error = assert_raises(InvalidOptionError, interval_ms.inspect) do
        client.wait_for_payment(invoice, interval_ms: interval_ms)
      end
      assert_equal "interval_ms", error.param
    end
  end

  # Strings Ruby can hold that are no text

  test "refuses a note holding a lone surrogate, or broken UTF-8" do
    ["Order #{Json.parse('"\\ud800"')}", "Order \xFF".dup.force_encoding(Encoding::UTF_8),
     "Order".encode("UTF-16LE").byteslice(0, 3).force_encoding(Encoding::UTF_16LE)].each do |note|
      error = assert_raises(InvalidOrderError) { client.create_invoice(ref: "N-1", sats: 1, note: note) }
      assert_equal "note", error.param
    end
    assert_empty @merchant.http.calls
  end

  test "reads a note in another encoding as its text" do
    invoice = client.create_invoice(ref: "N-3", sats: 1, note: "Commande n° 7".encode("ISO-8859-1"))
    assert_equal ["Commande n° 7", Encoding::UTF_8], [invoice.note, invoice.note.encoding]
  end

  test "counts a note in code points: 100 emojis fit" do
    invoice = client.create_invoice(ref: "N-2", sats: 1, note: "😀" * 100)
    assert_equal "😀" * 100, invoice.note
    # 400 bytes in UTF-8: more than breez.tips's 255, so not sent as the comment.
    assert_nil @merchant.made_invoices[0].comment
  end

  # HTTP answers

  # An HTTP client that answers `status` with `chunks`, recording what it was given.
  class StubHttp
    attr_reader :given

    def initialize(status, chunks)
      @status = status
      @chunks = chunks
    end

    def get(url, headers:, timeout:, cancellation:, &)
      @given = [url, headers, timeout, cancellation]
      @chunks.each(&)
      @status
    end
  end

  def get_json(fake, timeout_ms = 1000) = Http.get_json("https://breez.tips/x", http_of(fake, timeout_ms))

  def http_of(fake, timeout_ms = 1000, cancellation = Cancellation::NONE)
    Http::Context.new(client: fake, timeout_ms: timeout_ms, stop: Stop.new(cancellation))
  end

  test "follows no redirect" do
    error = assert_raises(NetworkError) { get_json(StubHttp.new(302, ["{}"])) }
    assert_match(/redirect \(HTTP 302\)/, error.message)
  end

  test "drops a body larger than 1 MiB, read chunk by chunk" do
    big = StubHttp.new(200, ["\"", "a" * (1 << 20), "\""])
    assert_match(/more than 1048576 bytes/, assert_raises(NetworkError) { get_json(big) }.message)
    assert_equal "a" * 1000, get_json(StubHttp.new(200, ["\"#{"a" * 1000}\""])).body
    # Exactly 1 MiB is read.
    exact = "\"#{"a" * ((1 << 20) - 2)}\""
    assert_equal (1 << 20) - 2, get_json(StubHttp.new(200, exact.scan(/.{1,4096}/m))).body.size
  end

  test "reads a body that is not UTF-8 as no JSON, and ignores one byte order mark before it" do
    assert_nil get_json(StubHttp.new(200, ["\"\xFF\"".b])).body
    assert_equal({ "a" => 1.0 }, get_json(StubHttp.new(200, ["\xEF\xBB\xBF{\"a\":1}".b])).body)
    # In chunks too, the mark split.
    assert_equal({ "a" => 1.0 }, get_json(StubHttp.new(200, ["\xEF".b, "\xBB\xBF{\"a\"".b, ":1}"])).body)
    # Two marks: the second is text, not JSON.
    assert_nil get_json(StubHttp.new(200, ["\xEF\xBB\xBF\xEF\xBB\xBF{}".b])).body
    # One inside a string is kept.
    assert_equal({ "a" => "\u{FEFF}" }, get_json(StubHttp.new(200, ["{\"a\":\"\xEF\xBB\xBF\"}".b])).body)
  end

  test "asks with the User-Agent, for JSON, within the timeout, and gives the client a cancellation" do
    stub = StubHttp.new(200, ["{}"])
    get_json(stub, 2500)
    url, headers, timeout, cancellation = stub.given
    assert_equal "https://breez.tips/x", url
    assert_equal({ "Accept" => "application/json", "User-Agent" => "sattleme-Checkout/1" }, headers)
    assert_in_delta 2.5, timeout
    assert_kind_of Cancellation, cancellation
  end

  test "gives up a client that does not answer in time, and tells it" do
    cancelled = Queue.new
    slow = Object.new
    slow.define_singleton_method(:get) do |_url, headers:, timeout:, cancellation:| # rubocop:disable Lint/UnusedBlockArgument
      cancellation.wait(5)
      cancelled << cancellation.cancelled?
      200
    end
    started = Clock.now
    assert_match(/in time/, assert_raises(NetworkError) { get_json(slow, 200) }.message)
    assert_operator Clock.now - started, :<, 1
    assert(cancelled.pop(timeout: 2))
  end

  test "stops a request with its call's cancellation" do
    slow = Object.new
    slow.define_singleton_method(:get) do |_url, headers:, timeout:, cancellation:| # rubocop:disable Lint/UnusedBlockArgument
      cancellation.wait(5)
      200
    end
    cancellation = Cancellation.new
    Thread.new do
      sleep 0.1
      cancellation.cancel("left")
    end
    started = Clock.now
    error = assert_raises(Cancelled) { Http.get_json("https://breez.tips/x", http_of(slow, 5000, cancellation)) }
    assert_equal "left", error.message
    assert_operator Clock.now - started, :<, 1
  end

  test "takes a client's failure as no answer, and a status that is no Integer as a failure" do
    failing = Object.new
    failing.define_singleton_method(:get) { |*, **| raise Errno::ECONNRESET }
    error = assert_raises(NetworkError) { get_json(failing) }
    assert_kind_of Errno::ECONNRESET, error.cause
    assert_raises(NetworkError) { get_json(StubHttp.new("200", ["{}"])) }
  end

  # The platform's HTTP client

  # An https server for breez.test (and, through the proxy, any name), and a client trusting it.
  def https(&)
    server = closing(TestHttpsServer.new(names: ["breez.test"], &))
    proxy = closing(TestConnectProxy.new(server.port))
    [server, proxy, HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"), cert_store: TestTls.store)]
  end

  def route_of(request) = request.line.split[1]

  test "asks over TLS through a proxy, with the headers it is given and no compression" do
    server, proxy, http = https { [200, { "Content-Type" => "application/json" }, ['{"tag":', '"payRequest"}']] }
    answer = Http.get_json("https://breez.test/.well-known/lnurlp/shop", http_of(http, 2000))
    assert_equal [200, { "tag" => "payRequest" }], [answer.status, answer.body]
    assert_equal ["CONNECT breez.test:443 HTTP/1.1"], proxy.requests
    request = server.requests[0]
    assert_equal "GET /.well-known/lnurlp/shop HTTP/1.1", request.line
    assert_equal ["sattleme-Checkout/1", "application/json", "identity", "breez.test"],
                 request.headers.values_at("user-agent", "accept", "accept-encoding", "host")
  end

  test "follows no redirect: a 3xx is no answer" do
    server, _, http = https do |request|
      route_of(request) == "/redirect" ? [302, { "Location" => "https://breez.test/target" }, []] : [200, {}, ["{}"]]
    end
    assert_equal 302, http.get("https://breez.test/redirect", headers: {}, timeout: 2) { |_chunk| nil }
    error = assert_raises(NetworkError) { Http.get_json("https://breez.test/redirect", http_of(http, 2000)) }
    assert_match(/redirect \(HTTP 302\)/, error.message)
    assert_equal(["/redirect", "/redirect"], server.requests.map { |request| route_of(request) })
  end

  test "stops reading a body at 1 MiB" do
    _, _, http = https { [200, {}, Array.new(64) { "a" * 32_768 }] }
    error = assert_raises(NetworkError) { Http.get_json("https://breez.test/big", http_of(http, 5000)) }
    assert_match(/more than 1048576 bytes/, error.message)
  end

  test "verifies the certificate and the host name" do
    server, proxy, http = https { [200, {}, ["{}"]] }
    # The system's store does not trust the test's authority.
    system = HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"))
    assert_raises(OpenSSL::SSL::SSLError) { system.get("https://breez.test/x", headers: {}, timeout: 2) { |_| nil } }
    error = assert_raises(NetworkError) { Http.get_json("https://breez.test/x", http_of(system, 2000)) }
    assert_kind_of OpenSSL::SSL::SSLError, error.cause
    # A name its certificate does not hold.
    assert_raises(OpenSSL::SSL::SSLError) { http.get("https://other.test/x", headers: {}, timeout: 2) { |_| nil } }
    assert_empty server.requests
    # Only https URLs.
    assert_raises(ArgumentError) { http.get("http://breez.test/x", headers: {}, timeout: 2) { |_| nil } }
  end

  test "gives up a request in time, and when its cancellation is cancelled" do
    _, _, http = https do
      sleep 3
      [200, {}, ["{}"]]
    end
    started = Clock.now
    assert_raises(NetworkError) { Http.get_json("https://breez.test/slow", http_of(http, 300)) }
    assert_operator Clock.now - started, :<, 1.5
    cancellation = Cancellation.new
    Thread.new do
      sleep 0.2
      cancellation.cancel
    end
    started = Clock.now
    assert_raises(StandardError) do
      http.get("https://breez.test/slow", headers: {}, timeout: 5, cancellation: cancellation) { |_| nil }
    end
    assert_operator Clock.now - started, :<, 1.5
  end

  test "takes only a proxy URI and a certificate store" do
    assert_raises(ArgumentError) { HttpClient.new(proxy: "http://proxy:3128") }
    assert_raises(ArgumentError) { HttpClient.new(cert_store: "/etc/ssl/certs") }
  end

  # An answer written as it is: `head` (a String), then the pieces `more` yields, each written
  # until a write fails (the client closed the connection): how many bytes of them were written
  # goes to `written`.
  def raw(head, written = [], &more)
    lambda do |socket|
      socket.write(head)
      sent = 0
      begin
        more&.call(->(piece) { socket.write(piece) && (sent += piece.bytesize) })
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        written << sent
      end
    end
  end

  # The error Http.get_json raises for the answer `route` writes, and its cause.
  def failure_of(timeout_ms = 10_000, &)
    _, _, http = https(&)
    started = Clock.now
    error = assert_raises(NetworkError) { Http.get_json("https://breez.test/x", http_of(http, timeout_ms)) }
    [error.cause, Clock.now - started]
  end

  test "reads at most 16 KiB of an answer's head: a longer header line fails before more of it is read" do
    written = []
    pad = "a" * (1 << 20)
    cause, seconds = failure_of do
      raw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Pad: ", written) do |write|
        64.times { write.call(pad) }
        sleep 5
      end
    end
    assert_kind_of HttpClient::ProtocolError, cause
    assert_match(/longer than/, cause.message)
    # A client that holds the head whole read the 64 MiB, and waited for the rest.
    assert_operator seconds, :<, 5
    eventually { !written.empty? }
    assert_operator written[0], :<, 32 << 20
  end

  test "reads at most 16 KiB of a status line, and of a chunked body's size line" do
    endless = ->(write) { 64.times { write.call("0" * (1 << 20)) } }
    [raw("HTTP/1.1 200 ", &endless),
     raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1", &endless)].each do |answer|
      cause, seconds = failure_of { answer }
      assert_kind_of HttpClient::ProtocolError, cause
      assert_operator seconds, :<, 5
    end
  end

  test "reads at most 10 MiB besides an answer's body, its chunks' size lines in all" do
    # 1 000 chunks of one byte, each size line 11 KiB long with its extension: 11 MB of framing.
    extension = ";x=#{"a" * 11_000}"
    cause, = failure_of(30_000) do
      raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n") do |write|
        1000.times { write.call("1#{extension}\r\na\r\n") }
        write.call("0\r\n\r\n")
      end
    end
    assert_kind_of HttpClient::ProtocolError, cause
    assert_match(/besides the body/, cause.message)
  end

  test "reads at most 10 MiB besides an answer's body, its trailers in all" do
    # SPEC.md §15: a chunked body's trailers count too. 11 MiB of them, each line well within a
    # head's line.
    trailer = "X-Trailer: #{"a" * 8000}\r\n"
    cause, = failure_of(30_000) do
      raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n") do |write|
        ((11 << 20) / trailer.bytesize).times { write.call(trailer) }
        write.call("\r\n")
      end
    end
    assert_kind_of HttpClient::ProtocolError, cause
    assert_match(/besides the body/, cause.message)
  end

  def status_and_body(http)
    answer = Http.get_json("https://breez.test/x", http_of(http, 5000))
    [answer.status, answer.body]
  end

  test "reads an answer's body by its length, in chunks or until the end, past interim answers" do
    {
      raw("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"tag\":\"pay\"}") => { "tag" => "pay" },
      # Chunks with extensions, a trailer; a line end of LF alone.
      raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;a=b\r\n{\"ta\r\n9\r\ng\":\"pay\"}\r\n0\r\n" \
          "X-Trailer: 1\r\n\r\n") => { "tag" => "pay" },
      raw("HTTP/1.1 200 OK\nContent-Length: 2, 2\n\n{}") => {},
      # Early hints, then the answer; HTTP/1.0, until the connection ends.
      raw("HTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\nHTTP/1.0 200 OK\r\n\r\n[1]") => [1.0]
    }.each do |answer, body|
      _, _, http = https { answer }
      assert_equal [200, body], status_and_body(http)
    end
    _, _, http = https { raw("HTTP/1.1 204 No Content\r\n\r\n") }
    assert_equal [204, nil], status_and_body(http)
    # A status of no class is given as it is (SPEC.md §26 reads it).
    _, _, http = https { raw("HTTP/1.1 600 Odd\r\nContent-Length: 2\r\n\r\n{}") }
    assert_equal 600, Http.get_json("https://breez.test/x", http_of(http, 5000)).status
  end

  test "takes an answer cut short, a length that is no number or a switch of protocols as no answer" do
    ["HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}", "HTTP/1.1 200 OK\r\nContent-Length: 2, 3\r\n\r\n{}",
     "HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n{}", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{}",
     "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n{}\r\n0\r\n\r\n", "HTTP/1.1 101 Switching\r\n\r\n",
     "HTTP/2 200\r\n\r\n{}", "HTTP/1.1 200 OK\r\nBad header\r\n\r\n{}"].each do |answer|
      _, _, http = https { raw(answer) }
      assert_raises(NetworkError, answer) { Http.get_json("https://breez.test/x", http_of(http, 5000)) }
    end
  end

  # A custom rate source

  def rate_context
    Rates::Context.new(http: http_of(FakeHttp.new { FakeHttp.answer({}, 404) }), coingecko_api_key: nil)
  end

  test "turns a custom source's own errors into a RateError, with the cause" do
    cause = TypeError.new("fetch failed")
    error = assert_raises(RateError) { Rates.fetch_rate(->(_) { raise cause }, "CHF", rate_context, 1_791_378_000) }
    assert_same cause, error.cause
  end

  test "keeps the gem's errors a custom source raises" do
    [UnsupportedCurrencyError.new("XOF", "mine"), NetworkError.new("down")].each do |thrown|
      raised = assert_raises(thrown.class) do
        Rates.fetch_rate(lambda { |_|
          raise thrown
        }, "XOF", rate_context, 1_791_378_000)
      end
      assert_same thrown, raised
    end
  end

  # The channel

  test "ignores a channel whose reading key is off the curve" do
    @merchant.publish_channel(@merchant.channel_value(200, "registryReader" => "00" * 32), 200, @merchant.key_relays)
    # The newest valid copy stands: the one of 100.
    assert_equal "Sunrise Bakery", client.merchant.business_name
    @merchant.stop
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100, "registryReader" => "00" * 32), 100)
    assert_raises(ChannelNotFoundError) { client.merchant }
  end

  # The earlier invoices of an order

  # An HTTP client that counts the payment checks running at once.
  class CountingHttp
    attr_reader :most

    def initialize(inner)
      @inner = inner
      @mutex = Mutex.new
      @running = 0
      @most = 0
    end

    def get(url, headers:, timeout:, cancellation:, &)
      verify = url.include?("/verify/")
      if verify
        @mutex.synchronize do
          @running += 1
          @most = [@most, @running].max
        end
        sleep 0.05
      end
      @inner.get(url, headers: headers, timeout: timeout, cancellation: cancellation, &)
    ensure
      @mutex.synchronize { @running -= 1 } if verify
    end
  end

  test "checks the earlier invoices of an order four at a time" do
    sattleme = client
    6.times do
      sattleme.create_invoice(ref: "E-1", sats: 1, duration_seconds: 60)
      @merchant.now += 60 + 120
    end
    counting = CountingHttp.new(@merchant.http)
    client(http_client: counting).create_invoice(ref: "E-1", sats: 1)
    assert_equal 4, counting.most
    assert_equal 7, @merchant.invoices.size
  end

  # Relays

  # A pool of one call over `websocket`, each request bounded by `timeout_ms`, closed after the block.
  def with_pool(websocket = @merchant.net.websocket_client, timeout_ms: 2000)
    stop = Stop.new(Cancellation::NONE)
    pool = Relay::Pool.new(websocket: websocket, timeout_ms: timeout_ms, stop: stop, random: RANDOM,
                           now: -> { @merchant.now })
    yield pool
  ensure
    pool&.close
  end

  test "counts a relay whose request ran out of time waiting for its authentication as failed for the call" do
    # Relays that ask every request to authenticate (NIP-42), and never answer the AUTH.
    silent = { require_auth: true, mute_auth: true }
    reader = @merchant.net.add("wss://silent-read.test", silent)
    writer = @merchant.net.add("wss://silent-write.test", silent)
    others = %w[wss://a.test wss://b.test].map { |url| @merchant.net.add(url) && url }
    with_pool(timeout_ms: 1500) do |pool|
      started = Clock.now
      read = pool.query_relays(["wss://silent-read.test"], { "kinds" => [1] }, "\x07".b * 32,
                               paged: false, keep: ->(value) { value })
      # It ran out of time there, once: never a refusal asked again.
      refute read.answered
      assert_operator Clock.now - started, :>=, 1.5
      assert_equal 1, reader.queries.size
      assert pool.failed?("wss://silent-read.test")
      event = Events.sign("\x08".b * 32, RANDOM, created_at: @merchant.now, kind: 1, tags: [], content: "x")
      assert_raises(Relay::Failure) { pool.publish_to_quorum(["wss://silent-write.test"], event, "\x08".b * 32, 1) }
      assert pool.failed?("wss://silent-write.test")
      # A read on every relay neither asks them again nor waits for them.
      asked = reader.queries.size
      started = Clock.now
      read = pool.query_relays([*others, "wss://silent-read.test", "wss://silent-write.test"], { "kinds" => [1] },
                               "\x07".b * 32, paged: false, keep: ->(value) { value }, every_relay: true)
      # The two others alone answered: fewer than a majority of the four.
      assert_equal [others.sort, false], [read.answers.keys.sort, read.answered]
      assert_equal asked, reader.queries.size
      assert_empty writer.queries
      # Waiting for either would take one relay timeout.
      assert_operator Clock.now - started, :<, 1.5
    end
  end

  test "authenticates with NIP-42's AUTH message, never an EVENT, which the local relay refuses" do
    relay = @merchant.net.add("wss://auth.test", require_auth: true)
    relay.store({ "id" => "aa" * 32, "pubkey" => "ab" * 32, "created_at" => 1, "kind" => 30_078, "tags" => [],
                  "content" => "", "sig" => "00" * 64 })
    key = "\x07".b * 32
    read = with_pool do |pool|
      pool.query_relays(["wss://auth.test"], { "kinds" => [30_078] }, key, paged: false, keep: ->(value) { value })
    end
    assert_equal [true, 1], [read.answered, read.answers.fetch("wss://auth.test").size]
    assert_equal [Events.public_key(key)], relay.authenticated
    assert_empty(relay.received.select { |event| event["kind"] == Protocol::AUTH_KIND })
    # The relay itself: an authentication sent as an EVENT is refused, and authenticates nothing; as
    # NIP-42's AUTH, it does.
    socket = @merchant.net.websocket_client.connect("wss://auth.test", timeout: 2)
    _, challenge = Json.parse(socket.receive)
    auth = Events.sign(key, RANDOM, created_at: @merchant.now, kind: Protocol::AUTH_KIND,
                                    tags: [["relay", "wss://auth.test"], ["challenge", challenge]], content: "")
    socket.send_text(Json.generate(["EVENT", auth.to_h]))
    assert_equal ["OK", auth.id, false], Json.parse(socket.receive).first(3)
    socket.send_text(Json.generate(["REQ", "s", { "kinds" => [30_078] }]))
    assert_equal %w[CLOSED s], Json.parse(socket.receive).first(2)
    socket.send_text(Json.generate(["AUTH", auth.to_h]))
    assert_equal ["OK", auth.id, true], Json.parse(socket.receive).first(3)
    # Even from an author that authenticated: never kept as an event.
    socket.send_text(Json.generate(["EVENT", auth.to_h]))
    assert_equal ["OK", auth.id, false], Json.parse(socket.receive).first(3)
    assert_empty(relay.events.select { |event| event["kind"] == Protocol::AUTH_KIND })
    socket.close
  end

  test "fails a relay whose handshake answer holds a header of 11 MiB: a failed connection" do
    # SPEC.md §15: what the client holds of a WebSocket handshake's answer is bounded too.
    padded = closing(TestWebSocketServer.new(
                       handshake: ->(_) { "HTTP/1.1 101 Switching Protocols\r\nX-Pad: #{"a" * (11 << 20)}\r\n\r\n" }
                     ))
    @merchant.net.add_server("wss://padded.test", padded)
    started = Clock.now
    read = with_pool do |pool|
      pool.query_relays(["wss://padded.test"], { "kinds" => [30_078] }, "\x07".b * 32,
                        paged: false, keep: ->(value) { value })
    end
    assert_equal [{}, false], [read.answers, read.answered]
    # At the bound, not at the timeout.
    assert_operator Clock.now - started, :<, 1.5
    error = assert_raises(WebSocketClient::ProtocolError) do
      @merchant.net.websocket_client.connect("wss://padded.test", timeout: 2)
    end
    assert_match(/too long/, error.message)
  end

  test "never follows a redirect of the WebSocket handshake: a failed connection" do
    # Where the redirect points: a relay that would answer.
    target = @merchant.net.add("wss://target.test")
    redirect = closing(TestWebSocketServer.new(
                         handshake: ->(_) { "HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.1:#{target.port}/\r\n\r\n" }
                       ))
    @merchant.net.add_server("wss://relay.test", redirect)
    started = Clock.now
    read = with_pool do |pool|
      pool.query_relays(["wss://relay.test"], { "kinds" => [30_078] }, "\x07".b * 32,
                        paged: false, keep: ->(value) { value })
    end
    assert_equal [{}, false], [read.answers, read.answered]
    # Failed at the redirect, not at the timeout; the target never asked.
    assert_operator Clock.now - started, :<, 1.5
    assert_empty target.queries
    error = assert_raises(WebSocketClient::ProtocolError) do
      @merchant.net.websocket_client.connect("wss://relay.test", timeout: 2)
    end
    assert_match(/redirect \(HTTP 302\)/, error.message)
  end

  test "sends the User-Agent of every request in the WebSocket handshake of the relays" do
    # Relays behind a bot protection (Cloudflare's, nostr.wine's) refuse a handshake without one.
    client.merchant
    @merchant.key_relays.each do |url|
      handshakes = @merchant.net.get(url).handshakes
      refute_empty handshakes
      handshakes.each { |headers| assert_equal "sattleme-Checkout/1", headers["user-agent"] }
    end
  end

  test "sends the User-Agent in the WebSocket handshake of the explorer" do
    socket = closing(@merchant.start_explorer_socket)
    address = TestChain.deposit_address("watched")
    explorer = CallExplorer.new(nil, NodeFailures.new, -> { 0 })
    watch = Watch.new(@merchant.net.websocket_client, explorer, address, 2) { nil }
    begin
      eventually { socket.messages.size == 2 }
      assert_equal [{ "action" => "want", "data" => ["blocks"] }, { "track-address" => address }], socket.messages
      assert_equal(["sattleme-Checkout/1"], socket.handshakes.map { |headers| headers["user-agent"] })
      refute socket.handshakes[0].key?("sec-websocket-extensions")
    ensure
      watch.close
    end
  end

  test "offers no WebSocket compression (permessage-deflate), and refuses an extension it did not offer" do
    client.merchant
    @merchant.key_relays.each do |url|
      @merchant.net.get(url).handshakes.each { |headers| refute headers.key?("sec-websocket-extensions") }
    end
    offering = closing(TestWebSocketServer.new(handshake: lambda do |headers|
      accept = [OpenSSL::Digest::SHA1.digest(headers["sec-websocket-key"] + TestWebSocketServer::GUID)].pack("m0")
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
    end))
    @merchant.net.add_server("wss://deflate.test", offering)
    error = assert_raises(WebSocketClient::ProtocolError) do
      @merchant.net.websocket_client.connect("wss://deflate.test", timeout: 2)
    end
    assert_match(/extension that was not offered/, error.message)
  end

  test "speaks to a relay over TLS, its certificate and host name verified" do
    echo = lambda do |connection|
      Thread.new do
        while (message = connection.read_message)
          connection.send_text("echo #{message[1]}")
        end
      end
    end
    context = TestTls.server_context(names: ["relay.test"], ips: ["127.0.0.1"])
    server = closing(TestWebSocketServer.new(ssl_context: context, on_connection: echo))
    tls = TlsConnector.new(ssl_context: TestTls.client_context)
    asked = []
    websocket = WebSocketClient.new(connector: lambda do |host, port, timeout|
      asked << [host, port]
      tls.call("127.0.0.1", server.port, timeout)
    end)
    session = websocket.connect("wss://relay.test", timeout: 2, headers: { "User-Agent" => Protocol::USER_AGENT })
    begin
      session.send_text("hello")
      assert_equal "echo hello", session.receive
      # A large message, in many TLS records.
      session.send_text("x" * 200_000)
      assert_equal 200_005, session.receive.bytesize
    ensure
      session.close
    end
    assert_equal [["relay.test", 443]], asked
    # The system's store does not trust the test's authority; a certificate of another name.
    assert_raises(OpenSSL::SSL::SSLError) { TlsConnector.new.call("127.0.0.1", server.port, 2) }
    other = closing(TestWebSocketServer.new(ssl_context: TestTls.server_context(names: ["other.test"])))
    assert_raises(OpenSSL::SSL::SSLError) { tls.call("127.0.0.1", other.port, 2) }
  end

  # A connector whose name resolution takes 0.3 s, then gives the local address, recording the time
  # each connection is given.
  class SlowResolution < TlsConnector
    attr_reader :given

    def initialize(...)
      super
      @given = []
    end

    private

    def resolve(_host, port, _timeout)
      sleep 0.3
      [Addrinfo.tcp("127.0.0.1", port)]
    end

    def connect_to(address, timeout)
      @given << timeout
      super
    end
  end

  test "bounds a relay's name resolution, its connection and TLS by one deadline" do
    # Takes the connection, never answers TLS.
    silent = closing(TCPServer.new("127.0.0.1", 0))
    connector = SlowResolution.new(ssl_context: TestTls.client_context)
    started = Clock.now
    error = assert_raises(IO::TimeoutError) { connector.call("relay.test", silent.addr[1], 0.5) }
    assert_match(/TLS handshake timed out/, error.message)
    assert_operator connector.given[0], :<=, 0.21
    assert_operator Clock.now - started, :<, 1.5
  end

  test "counts the wait for the connection, the name's resolution included, in a relay request's timeout" do
    # A resolver that answers late, then nothing.
    late = WebSocketClient.new(connector: lambda do |_host, _port, _timeout|
      sleep 2
      raise SocketError, "no address"
    end)
    sattleme = Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: late,
                          now: -> { @merchant.now }, relay_timeout_ms: 300, logger: QUIET)
    started = Clock.now
    assert_raises(NetworkError) { sattleme.merchant }
    assert_operator Clock.now - started, :<, 1.5
  end

  test "keeps of what a relay sends only what the read keeps, and still pages through the rest" do
    relay = @merchant.net.get(@merchant.key_relays[0])
    filler = "x" * 60_000
    300.times do |i|
      relay.store({ "id" => i.to_s(16).rjust(64, "0"), "pubkey" => "ab" * 32, "created_at" => 1_000_000 - i,
                    "kind" => 30_078, "tags" => [["d", "cd" * 32]], "content" => filler, "sig" => "00" * 64 })
    end
    wanted = "#{"0" * 62}ff"
    keep = ->(value) { value["id"] == wanted ? value : nil }
    [false, true].each do |paged|
      # 18 MB through the gem's WebSocket client: a page may take a while on a busy machine.
      read = with_pool(timeout_ms: 30_000) do |pool|
        pool.query_relays([@merchant.key_relays[0]], { "kinds" => [30_078] }, "\x00".b * 32,
                          paged: paged, keep: keep)
      end
      assert read.answered
      kept = read.answers.fetch(@merchant.key_relays[0])
      assert_equal([[wanted, filler]], kept.map { |event| [event["id"], event["content"]] })
    end
    # A complete read: 300 events in pages of 100, one kept; the read complete.
    complete = with_pool(timeout_ms: 30_000) do |pool|
      pool.query_complete([@merchant.key_relays[0]], { "kinds" => [30_078] }, "\x00".b * 32, keep: keep)
    end
    assert_equal [true, true], [complete.answered, complete.complete]
    assert_equal 1, complete.answers.fetch(@merchant.key_relays[0]).size
    assert_equal(4, relay.queries.count { |filter| filter["limit"] == 100 })
  end

  test "reads a relay's copies of one event once per query, and keeps nothing a relay adds to it" do
    url = "wss://copies.test"
    relay = @merchant.net.add(url)
    event = @merchant.channel_event(@merchant.channel_value(100), 100).to_h
    # Copies that check out: the id and the signature cover none of what a relay adds.
    50.times { relay.store(event.merge("padding" => "x" * 100_000)) }
    _, encryption_key = Derive.channel_keys(@merchant.integration_key)
    open = Records.that_open { encryption_key }
    opened = 0
    keep = lambda do |value|
      opened += 1
      open.call(value)
    end
    filter = { "kinds" => [30_078] }
    reads = [
      ->(pool) { pool.query_relays([url], filter, "\x00".b * 32, paged: false, keep: keep) },
      ->(pool) { pool.query_relays([url], filter, "\x00".b * 32, paged: true, keep: keep) },
      ->(pool) { pool.query_complete([url], filter, "\x00".b * 32, keep: keep) }
    ]
    reads.each_with_index do |read, index|
      opened = 0
      asked = relay.queries.size
      answers = with_pool(timeout_ms: 10_000) { |pool| read.call(pool) }.answers
      assert_equal [event], answers.fetch(url), index
      assert_equal %w[id pubkey created_at kind tags content sig], answers.fetch(url)[0].keys, index
      # One opening per query that sent the copies (a paged read asks their second again).
      sent = relay.queries.drop(asked).count do |filter|
        filter["until"].nil? || filter["until"] >= event["created_at"]
      end
      assert_equal sent, opened, index
    end
  end

  test "pages on while the last page held an event with a string id and a safe integer created_at, valid or not" do
    url = @merchant.key_relays[0]
    relay = @merchant.net.get(url)
    relay.clear
    relay.behaviour = { cap: 2 }
    # Events no read keeps (their signature is none), each with a string id and a safe date.
    6.times do |i|
      relay.store({ "id" => format("%064x", i), "pubkey" => "ab" * 32, "created_at" => 1_000 - (i * 10),
                    "kind" => 30_078, "tags" => [], "content" => "", "sig" => "00" * 64 })
    end
    wanted = "ff" * 32
    relay.store({ "id" => wanted, "pubkey" => "ab" * 32, "created_at" => 900, "kind" => 30_078, "tags" => [],
                  "content" => "", "sig" => "00" * 64 })
    keep = ->(value) { value["id"] == wanted ? value : nil }
    read = with_pool do |pool|
      pool.query_relays([url], { "kinds" => [30_078] }, "\x00".b * 32, paged: true, keep: keep)
    end
    assert_equal([wanted], read.answers.fetch(url).map { |event| event["id"] })
    # `until` the oldest date of the last page, minus 1 when it held nothing new.
    assert_equal([nil, 990, 980, 970, 960, 950, 900, 899], relay.queries.map { |filter| filter["until"]&.to_i })
    # A page whose events have no string id, or no safe integer date, ends the read.
    relay.clear
    [{ "id" => 7, "created_at" => 2_000 }, { "id" => "a" * 64, "created_at" => 2_000.5 },
     { "id" => "b" * 64, "created_at" => 2**53 }, { "id" => wanted, "created_at" => 900 }].each do |fields|
      relay.store({ "pubkey" => "ab" * 32, "kind" => 30_078, "tags" => [], "content" => "", "sig" => "00" * 64,
                    **fields })
    end
    asked = relay.queries.size
    relay.behaviour = { cap: 3 }
    read = with_pool do |pool|
      pool.query_relays([url], { "kinds" => [30_078] }, "\x00".b * 32, paged: true, keep: keep)
    end
    assert_equal [[], 1], [read.answers.fetch(url), relay.queries.size - asked]
  end

  test "counts as answered only the relays whose read ended: one still reading sent pages, as events only" do
    relays = ["wss://ended.test", "wss://gone.test", "wss://reading.test"]
    # Late: the other relay's first page is in by then.
    ended = @merchant.net.add(relays[0], query_delay_ms: 300)
    # A full page of events without a string id: its read ends there, incomplete.
    100.times do |i|
      ended.store({ "id" => i, "pubkey" => "ab" * 32, "created_at" => 2_000, "kind" => 30_078, "tags" => [],
                    "content" => "", "sig" => "00" * 64 })
    end
    # wss://gone.test refuses connections: failed at once. A full page, then no answer: still reading.
    reading = @merchant.net.add(relays[2], mute_query: ->(filter) { filter.key?("until") })
    100.times do |i|
      reading.store({ "id" => format("%064x", i), "pubkey" => "ab" * 32, "created_at" => 2_000 - i, "kind" => 30_078,
                      "tags" => [], "content" => "", "sig" => "00" * 64 })
    end
    started = Clock.now
    read = with_pool do |pool|
      pool.query_complete(relays, { "kinds" => [30_078] }, "\x00".b * 32,
                          keep: ->(value) { value }, every_relay: true)
    end
    # No wait: a majority can no longer read completely. One relay answered (its read ended), the one
    # still reading did not: fewer than a majority answered.
    assert_operator Clock.now - started, :<, 1.5
    assert_equal [false, false], [read.answered, read.complete]
    # Its pages kept, as events: that is all.
    assert_equal 100, read.answers.fetch(relays[2]).size
  end

  test "goes on one timeout after a majority answered: a relay still reading has not answered, its pages kept" do
    relays = ["wss://first.test", "wss://second.test", "wss://reading.test"]
    event = lambda do |id, created_at|
      { "id" => format("%064x", id), "pubkey" => "ab" * 32, "created_at" => created_at, "kind" => 30_078,
        "tags" => [], "content" => "", "sig" => "00" * 64 }
    end
    @merchant.net.add(relays[0], pages: [[event.call(1, 2_000)]])
    @merchant.net.add(relays[1], pages: [[event.call(2, 2_000)]])
    # A page every 400 ms, well within the timeout, each with a new event: 20 pages, 8 s, far longer
    # than the read waits.
    @merchant.net.add(relays[2], pages: Array.new(20) { |i| [event.call(100 + i, 2_000 - i)] }, query_delay_ms: 400)
    started = Clock.now
    read = with_pool(timeout_ms: 2000) do |pool|
      pool.query_relays(relays, { "kinds" => [30_078] }, "\x00".b * 32, paged: true,
                                                                        keep: ->(value) { value }, every_relay: true)
    end
    # One timeout after the majority answered, not the 8 s of the relay still reading.
    assert_operator Clock.now - started, :<, 6
    assert read.answered
    assert_operator read.answers.fetch(relays[2]).size, :>=, 1
  end

  test "drops a relay's message larger than 1 MiB: the connection fails" do
    relay = @merchant.net.get(@merchant.key_relays[0])
    relay.store({ "id" => "aa" * 32, "pubkey" => "ab" * 32, "created_at" => 1, "kind" => 30_078, "tags" => [],
                  "content" => "x" * (1 << 20), "sig" => "00" * 64 })
    read = with_pool do |pool|
      pool.query_relays([@merchant.key_relays[0]], { "kinds" => [30_078] }, "\x00".b * 32,
                        paged: false, keep: ->(value) { value })
    end
    assert_equal [{}, false], [read.answers, read.answered]
  end

  # A socket of a WebSocket client that tells `sent` each message it sends (its relay's URL, the
  # message).
  RecordedSocket = Struct.new(:socket, :url, :sent) do
    def send_text(text)
      sent.call(url, text)
      socket.send_text(text)
    end

    def receive = socket.receive
    def close = socket.close
  end

  # `websocket`, its sockets recorded (RecordedSocket).
  def recording(websocket, &sent)
    Object.new.tap do |client|
      client.define_singleton_method(:connect) do |url, **options|
        RecordedSocket.new(websocket.connect(url, **options), url, sent)
      end
    end
  end

  test "asks nothing more of a read's dropped relays: no page, no authentication, no random bytes" do
    # A majority that answers its (empty) first page 300 ms late. Of the others, one answers its
    # first page at once and would page on (its events have a string id and a safe integer
    # created_at), one asks at once to authenticate: both are dropped when the read goes on.
    late = %w[wss://late-a.test wss://late-b.test wss://late-c.test]
    late.each { |url| @merchant.net.add(url, query_delay_ms: 300) }
    pager = @merchant.net.add("wss://pager.test")
    3.times do |i|
      pager.store({ "id" => format("%064x", i), "pubkey" => "ab" * 32, "created_at" => 2_000 - i, "kind" => 30_078,
                    "tags" => [], "content" => "", "sig" => "00" * 64 })
    end
    authing = @merchant.net.add("wss://authing.test", require_auth: true)
    # Once the read returned: what started then (a draw of random bytes, a reading of the clock) and
    # what was sent then. The draws past the first pages' subscription ids (the pager's next page,
    # the authentication's signature) and the clock (the authentication's date) are held until the
    # read returned, a second at most: a dropped relay's reader that would still ask is caught at it.
    returned = Cancellation.new
    mutex = Mutex.new
    late_calls = []
    late_sends = []
    draws = 0
    random = lambda do |length|
      after = returned.cancelled?
      mutex.synchronize { late_calls << :random if after }
      returned.wait(1) if mutex.synchronize { draws += 1 } > 5
      RANDOM.call(length)
    end
    now = lambda do
      after = returned.cancelled?
      mutex.synchronize { late_calls << :clock if after }
      returned.wait(1)
      @merchant.now
    end
    websocket = recording(@merchant.net.websocket_client) do |url, text|
      after = returned.cancelled?
      mutex.synchronize { late_sends << [url, Json.parse(text)[0]] if after }
    end
    relays = [*late, "wss://pager.test", "wss://authing.test"]
    pool = Relay::Pool.new(websocket: websocket, timeout_ms: 5000, stop: Stop.new(Cancellation::NONE),
                           random: random, now: now)
    begin
      read = pool.query_relays(relays, { "kinds" => [30_078] }, "\x07".b * 32, paged: true, keep: ->(value) { value })
      returned.cancel
      # Its readers ended before it returned.
      assert_empty(Thread.list.select { |thread| thread.name == "sattleme-checkout relay read" && thread.alive? })
      assert_equal [true, late.sort], [read.answered, read.answers.keys.sort]
      # What a dropped relay's reader would still do comes by then.
      sleep 1.5
    ensure
      pool.close
    end
    # Once the read returned: no request, page or authentication, no random bytes, no clock (but
    # the end of a dropped request: CLOSE).
    assert_empty(late_sends.reject { |_, type| type == "CLOSE" })
    assert_empty late_calls
    # Nor before, once the read went on: no second page, no authentication.
    assert_equal [1, 1, []], [pager.queries.size, authing.queries.size, authing.authenticated]
  end

  test "asks nothing more of a relay a read went on without, even once its authentication ends" do
    # checkout-node a9ad1cd's case (SPEC.md §13): the third relay's authentication ends after the
    # read went on, which must neither draw a subscription id nor send the query again. The two
    # that answer do so once the third asked for authentication and was sent it.
    fast = %w[wss://answers-1.test wss://answers-2.test]
    fast.each { |url| @merchant.net.add(url, query_delay_ms: 150) }
    slow = @merchant.net.add("wss://authenticates-late.test", require_auth: true, auth_delay_ms: 600)
    went_on = Cancellation.new
    drawn_after = Queue.new
    random = lambda do |length|
      drawn_after << length if went_on.cancelled?
      RANDOM.call(length)
    end
    pool = Relay::Pool.new(websocket: @merchant.net.websocket_client, timeout_ms: 2000,
                           stop: Stop.new(Cancellation::NONE), random: random, now: -> { @merchant.now })
    begin
      read = pool.query_relays([*fast, "wss://authenticates-late.test"], { "kinds" => [30_078] }, "\x07".b * 32,
                               paged: false, keep: ->(value) { value })
      went_on.cancel
      assert read.answered
      assert_equal 1, slow.queries.size
      # Its authentication is answered meanwhile.
      sleep 0.9
      assert_equal 1, slow.authenticated.size
      assert_equal 1, slow.queries.size
      assert_empty drawn_after
    ensure
      pool.close
    end
  end

  # The witnesses of an invoice

  SEEN = Derive.seen_keys("\x02".b * 32)
  ADDRESS = TestChain.deposit_address("this")
  ELSEWHERE = TestChain.deposit_address("elsewhere")
  SALE = "ab" * 32
  EXPIRES_AT = 1_791_379_180

  def witness(of, tx, sale)
    witness = Witnesses::Witness.new(address: of, txid: TestChain.txid(tx), sale: sale, sats: 1000, inputs: [],
                                     replacement: false, expires_at: sale.nil? ? nil : EXPIRES_AT)
    Witnesses.event(SEEN, witness, 1_791_378_400, RANDOM)
  end

  # A record of a newer format (its content `#`) at the witness address of `tx` at `of`.
  def newer(of, tx, tags, signed: true)
    d = Witnesses.witness_address(SEEN.address_key, of, TestChain.txid(tx), SALE)
    event = Events.sign(SEEN.secret_key, RANDOM, created_at: 1_791_378_400, kind: 30_078, tags: [["d", d], *tags],
                                                 content: "#")
    signed ? event : event.with(sig: "00" * 64)
  end

  def read_witnesses(events) = Witnesses.of_order(events, SEEN, ADDRESS, SALE, EXPIRES_AT)

  # A witness of `tx` at ADDRESS for `sale` holding `value`, sealed and tagged as Witnesses.event
  # seals one.
  def witness_holding(value, tx, sale)
    Records.seal(type: Protocol::WITNESS_RECORD_TYPE, value: value, signer: SEEN.secret_key,
                 encryption_key: SEEN.encryption_key,
                 address: Witnesses.witness_address(SEEN.address_key, ADDRESS, TestChain.txid(tx), sale),
                 created_at: 1_791_378_400, random: RANDOM,
                 tags: [["o", Witnesses.order_tag(SEEN.address_key, ADDRESS, sale)],
                        ["o", Witnesses.address_tag(SEEN.address_key, ADDRESS)]])
  end

  test "opens no witness without its sale member: null is none, absent is no witness" do
    none = { "version" => 1, "address" => ADDRESS, "txid" => TestChain.txid("t"), "sale" => nil, "sats" => 1000,
             "inputs" => [], "replacement" => false, "expiresAt" => nil }
    assert_equal :ok, Witnesses.open(witness_holding(none, "t", nil).to_h, SEEN).status
    assert_nil Witnesses.open(witness_holding(none.except("sale"), "t", nil).to_h, SEEN)
    assert_nil Witnesses.open(witness_holding(none.except("expiresAt"), "t", nil).to_h, SEEN)
    of_sale = none.merge("sale" => SALE, "expiresAt" => EXPIRES_AT)
    assert_equal SALE, Witnesses.open(witness_holding(of_sale, "t", SALE).to_h, SEEN).witness.sale
    # Without it, the record is no witness of the read: neither of none nor of the sale.
    read = read_witnesses([witness_holding(none.except("sale"), "t", nil).to_h,
                           witness_holding(of_sale.except("sale"), "u", SALE).to_h])
    assert_equal [0, 0, 0, 0], [read.sale.size, read.others.size, read.none.size, read.newer.size]
  end

  test "reads the witnesses of this read: of the sale, of none, of another sale at the address" do
    witnesses = read_witnesses([witness(ADDRESS, "mine", SALE), witness(ADDRESS, "none", nil),
                                witness(ADDRESS, "another's", "cd" * 32)].map(&:to_h))
    assert_equal [[TestChain.txid("mine")], [TestChain.txid("none")], [TestChain.txid("another's")]],
                 [witnesses.sale.keys, witnesses.none.keys, witnesses.others.keys]
  end

  test "ignores a witness at another address: a transaction paying two orders pays each its part" do
    witnesses = read_witnesses([witness(ELSEWHERE, "batch", "cd" * 32).to_h])
    assert_equal [0, 0, 0], [witnesses.sale.size, witnesses.others.size, witnesses.none.size]
  end

  test "keeps a witness of a newer format only with the read's tags and the author's signature" do
    tag = [["o", Witnesses.address_tag(SEEN.address_key, ADDRESS)]]
    other_tag = [["o", Witnesses.address_tag(SEEN.address_key, ELSEWHERE)]]
    assert_equal 1, read_witnesses([newer(ADDRESS, "t", tag).to_h]).newer.size
    # Another address's, which a relay sends against the filter: of no invoice of this read.
    assert_equal 0, read_witnesses([newer(ADDRESS, "t", other_tag).to_h]).newer.size
    # Without the seen secret's signature: nothing (SPEC.md §12), not an undecided payment.
    assert_equal 0, read_witnesses([newer(ADDRESS, "t", tag, signed: false).to_h]).newer.size
  end
end
