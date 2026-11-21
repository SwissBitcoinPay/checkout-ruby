# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/tls"

# The gem's WebSocket client (RFC 6455), against servers that follow the protocol and servers that
# break it: its handshake (its headers, no extension, no redirect, bounded in time and size), its
# frames (masked, reassembled, bounded at the limit before they are read), its close.
class WebSocketClientTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # A server that answers the handshake, then hands the raw socket to the test.
  class RawServer
    attr_reader :port

    def initialize(answer: nil, &handler)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @answer = answer
      @handler = handler
      @thread = Thread.new { accept_loop }
      @thread.report_on_exception = false
    end

    def close
      @server.close
    rescue IOError, SystemCallError
      nil
    end

    # The answer to a handshake of key `key`: 101 and its accept.
    def self.accept_of(key) = [OpenSSL::Digest::SHA1.digest(key + GUID)].pack("m0")

    private

    def accept_loop
      loop do
        socket = @server.accept
        thread = Thread.new(socket) { |client| serve(client) }
        thread.report_on_exception = false
      end
    rescue IOError, SystemCallError
      nil
    end

    def serve(socket)
      head = +"".b
      until head.end_with?("\r\n\r\n")
        byte = socket.read(1)
        return if byte.nil?

        head << byte
      end
      key = head[/^Sec-WebSocket-Key: (\S+)\r$/i, 1].to_s
      answer = if @answer
                 @answer.call(key)
               else
                 "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\n\r\n"
               end
      socket.write(answer) unless answer.empty?
      @handler&.call(socket)
    rescue IOError, SystemCallError
      nil
    ensure
      begin
        socket.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end

  def teardown
    @servers&.each(&:close)
  end

  def serve(answer: nil, &handler)
    RawServer.new(answer: answer, &handler).tap { |server| (@servers ||= []) << server }
  end

  def client_of(server, **)
    WebSocketClient.new(connector: ->(_host, _port, _timeout) { TCPSocket.new("127.0.0.1", server.port) }, **)
  end

  def connect(server, url = "wss://relay.test", **)
    client_of(server, **).connect(url, timeout: 2)
  end

  # A frame as a server writes it (unmasked unless `mask`), with the bits given.
  def frame(opcode, payload, fin: true, rsv: 0, mask: nil, length: nil)
    payload = payload.b
    first = (fin ? 0x80 : 0) | (rsv << 4) | opcode
    size = length || payload.bytesize
    head = [first].pack("C")
    mask_bit = mask ? 0x80 : 0
    head << if size <= 125
              [mask_bit | size].pack("C")
            elsif size <= 0xFFFF
              [mask_bit | 126, size].pack("Cn")
            else
              [mask_bit | 127, size].pack("CQ>")
            end
    return head + payload unless mask

    head + mask + payload.bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*")
  end

  # The next frame a client sent: [fin, opcode, masked, payload unmasked].
  def read_frame(socket)
    first, second = socket.read(2).unpack("CC")
    length = second & 0x7F
    length = socket.read(2).unpack1("n") if length == 126
    length = socket.read(8).unpack1("Q>") if length == 127
    mask = second.anybits?(0x80) ? socket.read(4) : nil
    payload = socket.read(length)
    payload = payload.bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*") if mask
    [first.anybits?(0x80), first & 0x0F, !mask.nil?, payload]
  end

  # The handshake

  test "asks the handshake RFC 6455 asks, with the headers given, and nothing more" do
    handshakes = Queue.new
    server = TestWebSocketServer.new
    (@servers ||= []) << server
    net = RelayNet.new
    net.add_server("wss://relay.test/nostr", server)
    net.add_server("wss://relay.test:8443", server)
    begin
      net.websocket_client.connect("wss://relay.test/nostr", timeout: 2,
                                                             headers: { "User-Agent" => "sattleme-Checkout/1" }).close
      net.websocket_client.connect("wss://relay.test:8443", timeout: 2).close
      server.handshakes.each { |headers| handshakes << headers }
      first = handshakes.pop
      assert_equal ["relay.test", "websocket", "Upgrade", "13", "sattleme-Checkout/1"],
                   first.values_at("host", "upgrade", "connection", "sec-websocket-version", "user-agent")
      assert_equal 16, first["sec-websocket-key"].unpack1("m0").bytesize
      refute first.key?("sec-websocket-extensions")
      refute first.key?("sec-websocket-protocol")
      refute first.key?("origin")
      assert_equal "relay.test:8443", handshakes.pop["host"]
      # The server keeps a connection once it answered its handshake, each in a thread of its own:
      # in any order. Each asked its URL's path.
      eventually { server.connections.size == 2 }
      assert_equal({ "relay.test" => "GET /nostr HTTP/1.1", "relay.test:8443" => "GET / HTTP/1.1" },
                   server.connections.to_h { |connection| [connection.headers["host"], connection.request_line] })
    ensure
      net.close
    end
  end

  test "refuses a header that would split the request" do
    server = serve
    [{ "X-A" => "a\r\nB: c" }, { "Bad Name" => "x" }, { "X-B" => "\x00" }].each do |headers|
      assert_raises(ArgumentError) { client_of(server).connect("wss://relay.test", timeout: 2, headers: headers) }
    end
  end

  {
    "a redirect" => ->(_) { "HTTP/1.1 301 Moved Permanently\r\nLocation: wss://other.test/\r\n\r\n" },
    "a refusal" => ->(_) { "HTTP/1.1 403 Forbidden\r\n\r\n" },
    "no HTTP" => ->(_) { "SSH-2.0-OpenSSH\r\n\r\n" },
    "a wrong accept" => lambda do |_|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n"
    end,
    "no upgrade" => lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\n\r\n"
    end,
    "no connection upgrade" => lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\n\r\n"
    end,
    "an extension not offered" => lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
    end,
    "a subprotocol not offered" => lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\nSec-WebSocket-Protocol: chat\r\n\r\n"
    end,
    "a malformed header" => lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\nno colon here\r\n\r\n"
    end,
    "an answer of more than 16 KiB" => lambda { |_|
      "HTTP/1.1 101 Switching Protocols\r\n#{"X-Pad: #{"a" * 100}\r\n" * 200}\r\n"
    },
    # SPEC.md §15: what a client holds of the answer to the handshake is bounded too.
    "a header of 11 MiB" => lambda { |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\nX-Pad: #{"a" * (11 << 20)}\r\n\r\n"
    }
  }.each do |name, answer|
    test "fails the handshake on #{name}" do
      server = serve(answer: answer)
      assert_raises(WebSocketClient::ProtocolError) { connect(server) }
    end
  end

  test "bounds the handshake in time, and gives it up when its cancellation is cancelled" do
    server = serve(answer: ->(_) { "" }, &:read)
    started = Clock.now
    assert_raises(IO::TimeoutError) { client_of(server).connect("wss://relay.test", timeout: 0.3) }
    assert_operator Clock.now - started, :<, 1.5
    cancellation = Cancellation.after(0.1)
    started = Clock.now
    assert_raises(StandardError) do
      client_of(server).connect("wss://relay.test", timeout: 5, cancellation: cancellation)
    end
    assert_operator Clock.now - started, :<, 1.5
  end

  test "keeps the first frames a server sent with its handshake answer" do
    answer = lambda do |key|
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{RawServer.accept_of(key)}\r\n\r\n#{frame(0x1, '["AUTH","x"]')}"
    end
    server = serve(answer: answer, &:read)
    session = connect(server)
    assert_equal '["AUTH","x"]', session.receive
    session.close
  end

  # Frames

  test "masks every frame it sends, with a fresh key" do
    frames = Queue.new
    server = serve do |socket|
      2.times { frames << read_frame(socket) }
      socket.read
    end
    session = connect(server)
    session.send_text("hello")
    session.send_text("hello")
    first = frames.pop
    second = frames.pop
    assert_equal [true, 0x1, true, "hello"], first
    assert_equal first, second
    session.close
  end

  test "reassembles a fragmented message, answers a ping, skips a pong" do
    pongs = Queue.new
    server = serve do |socket|
      socket.write(frame(0x1, "hel", fin: false) + frame(0x9, "ping!") + frame(0xA, "pong") +
                   frame(0x0, "lo", fin: false) + frame(0x0, " world"))
      pongs << read_frame(socket)
      socket.read
    end
    session = connect(server)
    assert_equal "hello world", session.receive
    assert_equal [true, 0xA, true, "ping!"], pongs.pop
    session.close
  end

  test "gives a binary message as its bytes, refuses a text that is not UTF-8" do
    server = serve do |socket|
      socket.write(frame(0x2, "\xFF\x00".b) + frame(0x1, "\xFF".b))
      socket.read
    end
    session = connect(server)
    assert_equal "\xFF\x00".b, session.receive
    assert_raises(WebSocketClient::ProtocolError) { session.receive }
  ensure
    session&.close
  end

  {
    "a frame the server masked" => -> { frame(0x1, "x", mask: "abcd") },
    "reserved bits (no extension was negotiated)" => -> { frame(0x1, "x", rsv: 4) },
    "an unknown opcode" => -> { frame(0x3, "x") },
    "a control frame fragmented" => -> { frame(0x9, "x", fin: false) },
    "a control frame of more than 125 bytes" => -> { frame(0x9, "x" * 126) },
    "a continuation without a message" => -> { frame(0x0, "x") },
    "a message inside another" => -> { frame(0x1, "a", fin: false) + frame(0x1, "b") },
    "the connection ended within a frame" => -> { frame(0x1, "abc", length: 10) }
  }.each do |name, bytes|
    test "fails on #{name}" do
      sent = instance_exec(&bytes)
      server = serve { |socket| socket.write(sent) }
      session = connect(server)
      assert_raises(WebSocketClient::ProtocolError) { session.receive }
    ensure
      session&.close
    end
  end

  test "fails a message longer than its limit before reading it" do
    server = serve do |socket|
      # Only the header of a frame of 2000 bytes: never its payload.
      socket.write(frame(0x1, "", length: 2000))
      sleep 2
    end
    session = connect(server, max_message_bytes: 1000)
    started = Clock.now
    assert_match(/more than 1000 bytes/, assert_raises(WebSocketClient::ProtocolError) { session.receive }.message)
    # Not the server's 2 s.
    assert_operator Clock.now - started, :<, 1.5
    session.close
    # Fragments that add up past it, too; a message of exactly the limit is read.
    server = serve do |socket|
      socket.write(frame(0x1, "a" * 1000) + frame(0x1, "a" * 600, fin: false) + frame(0x0, "a" * 600))
    end
    session = connect(server, max_message_bytes: 1000)
    assert_equal 1000, session.receive.bytesize
    assert_raises(WebSocketClient::ProtocolError) { session.receive }
  ensure
    session&.close
  end

  test "answers the server's close, then gives nil; gives nil when the connection ends between frames" do
    closes = Queue.new
    server = serve do |socket|
      socket.write(frame(0x1, "last") + frame(0x8, [1001, "bye"].pack("na*")))
      closes << read_frame(socket)
    end
    session = connect(server)
    assert_equal "last", session.receive
    assert_nil session.receive
    assert_equal [true, 0x8, true, [1001].pack("n")], closes.pop
    assert_predicate session, :closed?
    server = serve(&:close)
    assert_nil connect(server).receive
  end

  test "closes with a close frame, once, and gives nil to a receive that was waiting" do
    frames = Queue.new
    server = serve do |socket|
      frames << read_frame(socket)
      socket.read
    end
    session = connect(server)
    waiting = Thread.new { session.receive }
    sleep 0.05
    session.close
    session.close
    assert_equal [true, 0x8, true, [1000].pack("n")], frames.pop
    assert_nil waiting.value
  end

  test "sends a message of any size in one frame, its length written as RFC 6455 asks" do
    frames = Queue.new
    server = serve do |socket|
      3.times { frames << read_frame(socket) }
      socket.read
    end
    session = connect(server)
    [125, 65_535, 70_000].each { |size| session.send_text("a" * size) }
    assert_equal [125, 65_535, 70_000], Array.new(3) { frames.pop[3].bytesize }
    session.close
  end

  # A TLS connector that reaches 127.0.0.1 whatever the name, trusting the test's authority.
  class LocalTls < TlsConnector
    def initialize = super(ssl_context: TestTls.client_context)

    private

    def resolve(_host, port, _timeout) = [Addrinfo.tcp("127.0.0.1", port)]
  end

  test "refuses a URL that is no wss:// address with ArgumentError, before any connection" do
    asked = []
    websocket = WebSocketClient.new(connector: ->(*args) { asked << args })
    ["https://relay.test", "wss://", "relay.test"].each do |url|
      assert_raises(ArgumentError) { websocket.connect(url, timeout: 2) }
    end
    assert_empty asked
  end

  # Writing to a closed connection

  [["TLS", true], ["plain TCP", false]].each do |name, tls|
    test "fails a write to a #{name} connection the peer closed, at once, never until its deadline" do
      server = TCPServer.new("127.0.0.1", 0)
      context = TestTls.server_context(names: ["closed.test"])
      accepted = Thread.new do
        socket = server.accept
        if tls
          ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
          ssl.sync_close = true
          ssl.accept
          socket = ssl
        end
        socket.close
      end
      io = tls ? LocalTls.new.call("closed.test", server.addr[1], 2) : TCPSocket.new("127.0.0.1", server.addr[1])
      accepted.join
      started = Clock.now
      error = assert_raises(IOError, SystemCallError, OpenSSL::SSL::SSLError) do
        # More than any socket buffer, in writes that each wait 20 s at most for room.
        20.times { WebSocketClient.write_all(io, "x" * (1 << 20), Clock.now + 20) }
      end
      refute_kind_of IO::TimeoutError, error
      assert_operator Clock.now - started, :<, 10
    ensure
      io&.close
      server&.close
    end
  end
end
