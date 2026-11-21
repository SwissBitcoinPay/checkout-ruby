# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/tls"
require_relative "support/websocket_server"

# How the gem's own clients reach the merchant's Bitcoin node (SPEC.md §15, §31): its URL follows
# a rule of its own (NodeUrl), which allows `http` to a host of a local network and `https` to an
# IPv4 address; every other rule of §15 holds for it (the User-Agent, no redirect, the bounds).
# Plain HTTP and `ws://` go to such a node alone, and only when the explorer reads a URL of a node
# URL: every other URL (LNURL callbacks, verify URLs, stored invoices, relays) stays https or wss.
class NodeTransportTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  def setup
    @closing = []
  end

  def teardown
    @closing.each(&:close)
  end

  def closing(resource)
    @closing << resource
    resource
  end

  def http_of(client, node: false)
    Http::Context.new(client: client, timeout_ms: 2000, stop: Stop.new(Cancellation::NONE), node: node)
  end

  # HttpClient

  test "asks a local node in clear HTTP, through a proxy's tunnel, with the headers of every request" do
    server = closing(TestHttpsServer.new(tls: false) { [200, {}, ["970000"]] })
    proxy = closing(TestConnectProxy.new(server.port))
    http = HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"))
    answer = Http.get_text("http://192.168.1.10:3006/api/blocks/tip/height", http_of(http, node: true))
    assert_equal [200, "970000"], [answer.status, answer.text]
    assert_equal ["CONNECT 192.168.1.10:3006 HTTP/1.1"], proxy.requests
    request = server.requests[0]
    assert_equal "GET /api/blocks/tip/height HTTP/1.1", request.line
    assert_equal ["sattleme-Checkout/1", "192.168.1.10:3006", "identity"],
                 request.headers.values_at("user-agent", "host", "accept-encoding")
    # Port 80, as http names none: the Host header without it.
    Http.get_text("http://umbrel.local/api/blocks/tip/height", http_of(http, node: true))
    assert_equal "CONNECT umbrel.local:80 HTTP/1.1", proxy.requests[1]
    assert_equal "umbrel.local", server.requests[1].headers["host"]
  end

  test "follows no redirect of a node asked in clear: no answer" do
    server = closing(TestHttpsServer.new(tls: false) { [302, { "Location" => "http://192.168.1.11/api" }, []] })
    proxy = closing(TestConnectProxy.new(server.port))
    http = HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"))
    error = assert_raises(NetworkError) { Http.get_json("http://192.168.1.10/api/x", http_of(http, node: true)) }
    assert_match(/redirect \(HTTP 302\)/, error.message)
    assert_equal 1, server.requests.size
  end

  test "asks a node at an IPv4 address over TLS, its certificate's address verified" do
    server = closing(TestHttpsServer.new(ips: ["8.8.8.8"]) { [200, {}, ["970000"]] })
    proxy = closing(TestConnectProxy.new(server.port))
    http = HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"), cert_store: TestTls.store)
    answer = Http.get_text("https://8.8.8.8/api/blocks/tip/height", http_of(http, node: true))
    assert_equal [200, "970000"], [answer.status, answer.text]
    # Another address than its certificate's: refused.
    error = assert_raises(NetworkError) { Http.get_text("https://8.8.4.4/api/x", http_of(http, node: true)) }
    assert_kind_of OpenSSL::SSL::SSLError, error.cause
  end

  [["http to a public name", "http://node.example/api/blocks/tip/height"],
   ["http to a public IPv4 address", "http://8.8.8.8/api/blocks/tip/height"],
   ["http to 172.32.0.1", "http://172.32.0.1/api/blocks/tip/height"],
   ["http to localhost", "http://localhost:3006/api/blocks/tip/height"],
   ["http to 127.0.0.1", "http://127.0.0.1:3006/api/blocks/tip/height"],
   ["https to 127.0.0.1", "https://127.0.0.1/api/blocks/tip/height"],
   ["http with a user name", "http://user@192.168.1.10/api/blocks/tip/height"],
   ["http to a name without a dot", "http://umbrel/api/blocks/tip/height"],
   ["ftp", "ftp://192.168.1.10/api/blocks/tip/height"]].each do |name, url|
    test "refuses a URL that is no node's, before any connection: #{name}" do
      server = closing(TestHttpsServer.new(tls: false) { [200, {}, ["1"]] })
      proxy = closing(TestConnectProxy.new(server.port))
      http = HttpClient.new(proxy: URI("http://127.0.0.1:#{proxy.port}"))
      assert_raises(ArgumentError) { http.get(url, headers: {}, timeout: 2) { |_| nil } }
      assert_raises(NetworkError) { Http.get_text(url, http_of(http, node: true)) }
      assert_empty proxy.requests
    end
  end

  test "asks in clear HTTP only when the explorer reads a node's URL, whatever the client" do
    fake = FakeHttp.new { { text: "970000" } }
    url = "http://192.168.1.10:3006/api/blocks/tip/height"
    # Not the explorer's (a callback, a verify URL, a stored invoice's): never asked.
    error = assert_raises(NetworkError) { Http.get_text(url, http_of(fake)) }
    assert_match(/cannot be asked/, error.message)
    assert_empty fake.calls
    assert_equal "970000", Http.get_text(url, http_of(fake, node: true)).text
    # The explorer's, but no local node: never asked either.
    assert_raises(NetworkError) { Http.get_text("http://node.example/api/blocks/tip/height", http_of(fake, node: true)) }
    # https to an IPv4 address: a node's alone, never another URL's.
    assert_raises(NetworkError) { Http.get_text("https://8.8.8.8/api/blocks/tip/height", http_of(fake)) }
    Http.get_text("https://8.8.8.8/api/blocks/tip/height", http_of(fake, node: true))
    assert_equal [url, "https://8.8.8.8/api/blocks/tip/height"], fake.calls.map(&:url)
  end

  test "reads a node only through the explorer of a call, http only to a local node URL" do
    explorer = CallExplorer.new(BitcoinNodes::Node.new(url: "http://192.168.1.10:3006", fallback: "none",
                                                       payers: false), NodeFailures.new, -> { 0 })
    fake = FakeHttp.new { { json: [] } }
    explorer.read(http_of(fake)) { |base, context| Explorer.address_transactions(base, "bc1x", context) }
    assert_equal ["http://192.168.1.10:3006/api/address/bc1x/txs"], fake.calls.map(&:url)
    # An invalid node is none: mempool.space.
    none = CallExplorer.new(BitcoinNodes::Node.new(url: "http://8.8.8.8", fallback: "none", payers: false),
                            NodeFailures.new, -> { 0 })
    assert_nil none.node
    assert_equal [CallExplorer::MEMPOOL], none.sources
  end

  # WebSocketClient

  # A plain connector that reaches `port` of 127.0.0.1 whatever the name and port asked, recording
  # what it was asked.
  class LocalPlain < PlainConnector
    attr_reader :asked
    attr_writer :port

    def initialize(...)
      super
      @asked = []
    end

    def call(host, port, timeout)
      @asked << [host, port]
      super
    end

    private

    def resolve(_host, _port, _timeout) = [Addrinfo.tcp("127.0.0.1", @port)]
  end

  test "connects to a local node's WebSocket in clear (ws://), with the User-Agent" do
    echo = lambda do |connection|
      Thread.new do
        while (message = connection.read_message)
          connection.send_text("echo #{message[1]}")
        end
      end
    end
    server = closing(TestWebSocketServer.new(on_connection: echo))
    plain = LocalPlain.new
    plain.port = server.port
    tls = Object.new
    tls.define_singleton_method(:call) { |*| raise "no TLS for a ws:// URL" }
    websocket = WebSocketClient.new(connector: tls, plain_connector: plain)
    session = websocket.connect("ws://192.168.1.10:3006/api/v1/ws",
                                timeout: 2, headers: { "User-Agent" => Protocol::USER_AGENT })
    begin
      session.send_text("hello")
      assert_equal "echo hello", session.receive
    ensure
      session.close
    end
    assert_equal [["192.168.1.10", 3006]], plain.asked
    headers = server.handshakes[0]
    assert_equal ["192.168.1.10:3006", "sattleme-Checkout/1"], headers.values_at("host", "user-agent")
    # Port 80, as ws names none: the Host header without it.
    session = websocket.connect("ws://umbrel.local/api/v1/ws", timeout: 2)
    session.close
    assert_equal ["umbrel.local", 80], plain.asked[1]
    assert_equal "umbrel.local", server.handshakes[1]["host"]
  end

  [["a public name", "ws://node.example/api/v1/ws"], ["a public IPv4 address", "ws://8.8.8.8/api/v1/ws"],
   ["127.0.0.1", "ws://127.0.0.1:3006/api/v1/ws"], ["localhost", "ws://localhost/api/v1/ws"],
   ["a user name", "ws://user@192.168.1.10/api/v1/ws"]].each do |name, url|
    test "refuses ws:// to a host that is no local node's: #{name}" do
      plain = LocalPlain.new
      websocket = WebSocketClient.new(plain_connector: plain)
      assert_raises(ArgumentError) { websocket.connect(url, timeout: 2) }
      assert_empty plain.asked
    end
  end
end
