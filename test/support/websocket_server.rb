# frozen_string_literal: true

require "openssl"
require "socket"

# A WebSocket server for tests (RFC 6455), on a free port of 127.0.0.1, in threads of its own:
# the local relays and the explorer's WebSocket. It records each handshake's request (its headers),
# can answer it otherwise (a redirect, an extension the client did not offer), and hands each text
# message to the test's handler.
class TestWebSocketServer
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # One client's connection.
  class Connection
    attr_reader :headers, :request_line

    def initialize(socket, headers, request_line)
      @socket = socket
      @headers = headers
      @request_line = request_line
      @write = Mutex.new
      @closed = false
    end

    # Sends a text message (a frame of the server: not masked).
    def send_text(text)
      frame(0x1, text.b)
    end

    # Sends raw bytes as they are (a test of a broken frame).
    def send_raw(bytes)
      @write.synchronize { @socket.write(bytes) }
    rescue IOError, SystemCallError
      nil
    end

    def frame(opcode, payload)
      length = payload.bytesize
      header = [0x80 | opcode].pack("C")
      header << if length <= 125
                  [length].pack("C")
                elsif length <= 0xFFFF
                  [126, length].pack("Cn")
                else
                  [127, length].pack("CQ>")
                end
      @write.synchronize { @socket.write(header + payload) }
      true
    rescue IOError, SystemCallError
      false
    end

    # Closes the connection at once (no close frame): a lost connection.
    def terminate
      @closed = true
      @socket.close
    rescue IOError, SystemCallError
      nil
    end

    def closed? = @closed

    # The next message of the client: [:text, String], [:binary, String], or nil once closed.
    def read_message
      read_next_message.tap { |message| @closed = true if message.nil? }
    end

    private

    def read_next_message
      message = nil
      kind = nil
      loop do
        head = read_bytes(2)
        return nil unless head

        first, second = head.unpack("CC")
        opcode = first & 0x0F
        fin = first.anybits?(0x80)
        length = second & 0x7F
        length = read_bytes(2).unpack1("n") if length == 126
        length = read_bytes(8).unpack1("Q>") if length == 127
        mask = second.anybits?(0x80) ? read_bytes(4) : nil
        payload = read_bytes(length) || (return nil)
        payload = unmask(payload, mask) if mask
        case opcode
        when 0x8
          frame(0x8, payload.byteslice(0, 2) || "".b)
          terminate
          return nil
        when 0x9 then frame(0xA, payload)
        when 0xA then next
        when 0x0 then message << payload
        else
          message = payload
          kind = opcode == 0x1 ? :text : :binary
        end
        return [kind, kind == :text ? message.force_encoding(Encoding::UTF_8) : message] if fin && message
      end
    end

    def unmask(payload, mask)
      key = mask.bytes
      payload.bytes.each_with_index.map { |byte, index| byte ^ key[index % 4] }.pack("C*")
    end

    def read_bytes(count)
      return "".b if count.zero?

      data = @socket.read(count)
      data&.bytesize == count ? data : nil
    rescue IOError, SystemCallError
      nil
    end
  end

  attr_reader :port, :handshakes

  # `on_connection` receives each Connection once its handshake is answered; `handshake`, when
  # given, answers it instead: it receives the request's headers and gives the answer's text, or
  # nil for the WebSocket's 101. With `ssl_context`, over TLS.
  def initialize(on_connection: nil, handshake: nil, ssl_context: nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @on_connection = on_connection
    @handshake = handshake
    @ssl_context = ssl_context
    @connections = []
    @handshakes = []
    @mutex = Mutex.new
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def connections
    @mutex.synchronize { @connections.dup }
  end

  # The connections whose client has not closed them (nor the server dropped).
  def open_connections
    connections.reject(&:closed?)
  end

  # Drops every client's connection.
  def drop_all
    connections.each(&:terminate)
  end

  def close
    @server.close
    drop_all
  rescue IOError, SystemCallError
    nil
  end

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
    if @ssl_context
      socket = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
      socket.sync_close = true
      socket.accept
    end
    head = +"".b
    until head.end_with?("\r\n\r\n")
      byte = socket.read(1)
      return socket.close if byte.nil?

      head << byte
    end
    lines = head.split("\r\n")
    request_line = lines.shift
    headers = lines.each_with_object({}) do |line, all|
      name, value = line.split(":", 2)
      all[name.strip.downcase] = value.to_s.strip
    end
    @mutex.synchronize { @handshakes << headers }
    custom = @handshake&.call(headers)
    if custom
      socket.write(custom)
      sleep 0.05
      return socket.close
    end
    accept = [OpenSSL::Digest::SHA1.digest(headers["sec-websocket-key"].to_s + GUID)].pack("m0")
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
    connection = Connection.new(socket, headers, request_line)
    @mutex.synchronize { @connections << connection }
    @on_connection&.call(connection)
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    begin
      socket.close
    rescue IOError, SystemCallError
      nil
    end
  end
end
