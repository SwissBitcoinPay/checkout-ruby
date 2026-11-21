# frozen_string_literal: true

require "openssl"
require "securerandom"
require "socket"
require "io/wait"

module Sattleme
  module Checkout
    # Opens the TCP connection, then TLS, of a WebSocket: to `host` and `port`, certificate and
    # host name verified against the system's store, TLS 1.2 at least, the whole bounded by
    # `timeout` seconds: the name's resolution, the connection to its addresses (one after the
    # other) and the TLS handshake share one deadline (SPEC.md §13: the wait for the connection is
    # part of a request). Inject another (WebSocketClient.new(connector: …)) to go through a proxy,
    # or to reach a relay of your own network: anything that answers `call(host, port, timeout)`
    # with an IO (read_nonblock, write_nonblock, to_io, close).
    class TlsConnector
      def initialize(ssl_context: nil)
        @ssl_context = ssl_context || default_context
      end

      def call(host, port, timeout)
        deadline = Internal::Clock.now + timeout
        handshake(connect_tcp(host, port, deadline), host, deadline)
      end

      # A TCP connection to `host`: its name resolved, then its addresses tried in turn, by
      # `deadline` (Internal::Clock). Raises the last failure.
      def connect_tcp(host, port, deadline)
        failure = nil
        resolve(host, port, left(deadline, "Name resolution")).each do |address|
          return connect_to(address, left(deadline, "TCP connection"))
        rescue IOError, SystemCallError, SocketError => e
          failure = e
        end
        raise failure || SocketError.new("#{host} has no address")
      end

      # TLS over `tcp`, a connection that leads to `host` (a proxy's tunnel to it too), by
      # `deadline`: the certificate and the host name verified. `tcp` is closed when it fails.
      def handshake(tcp, host, deadline)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, @ssl_context)
        ssl.hostname = host
        ssl.sync_close = true
        loop do
          case ssl.connect_nonblock(exception: false)
          when :wait_readable then wait(tcp, :wait_readable, deadline)
          when :wait_writable then wait(tcp, :wait_writable, deadline)
          else break
          end
        end
        ssl.post_connection_check(host)
        ssl
      rescue StandardError
        begin
          (ssl || tcp).close
        rescue StandardError
          nil
        end
        raise
      end

      private

      # The addresses of `host` (TCP), resolved within `timeout` seconds.
      def resolve(host, port, timeout)
        Addrinfo.getaddrinfo(host, port, nil, :STREAM, timeout: timeout)
      end

      # A TCP connection to `address`, made within `timeout` seconds.
      def connect_to(address, timeout)
        address.connect(timeout: timeout)
      end

      # The seconds left before `deadline`; IO::TimeoutError (`step` timed out) when none are.
      def left(deadline, step)
        seconds = Internal::Clock.left(deadline)
        raise IO::TimeoutError, "#{step} timed out" if seconds.zero?

        seconds
      end

      def wait(io, readiness, deadline)
        left = Internal::Clock.left(deadline)
        raise IO::TimeoutError, "TLS handshake timed out" if left.zero? || !io.public_send(readiness, left)
      end

      def default_context
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true)
        context.min_version = OpenSSL::SSL::TLS1_2_VERSION
        context.alpn_protocols = ["http/1.1"]
        context
      end
    end

    # Opens the TCP connection of a WebSocket in clear (`ws://`), as TlsConnector does without its
    # TLS: only to the merchant's Bitcoin node on a local network (SPEC.md §31), which a node URL
    # allows in `http` (WebSocketClient checks it). Inject another (WebSocketClient.new(
    # plain_connector: …)) as you would a TlsConnector.
    class PlainConnector < TlsConnector
      def call(host, port, timeout)
        connect_tcp(host, port, Internal::Clock.now + timeout)
      end
    end

    # The platform's WebSocket client (RFC 6455), for the relays and the explorer's WebSocket
    # (SPEC.md §13, §31), over TLS (TlsConnector), or in clear (`ws://`, PlainConnector) to the
    # merchant's Bitcoin node on a local network alone: the handshake bounded in time, carrying the
    # headers it is given (the User-Agent of SPEC.md §15) and following no redirect (a 3xx is a
    # failed connection, as in HTTP: it would skip the checks of the URL); no extension offered,
    # so no compression (permessage-deflate: a few compressed bytes would unpack into many large
    # messages, and sealed records do not compress); a message of more than `max_message_bytes`
    # (1 MiB) fails the connection before it is read.
    #
    # Inject another as `websocket_client:` of a Client: anything that answers
    # `connect(url, headers:, timeout:, cancellation:)` (`timeout` in seconds, the whole handshake)
    # with a socket that answers `send_text(text)`, `receive` (the next text message, a String; nil
    # once the connection is closed; raises when it fails) and `close`. It gets a `ws://` URL only
    # for the WebSocket of a merchant's node on a local network: connect in clear, or fail (raise),
    # and the node's fallback applies.
    class WebSocketClient
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
      # The longest handshake answer read: its status line and headers.
      MAX_HANDSHAKE_BYTES = 16_384
      HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
      HEADER_VALUE = /\A[\t\x20-\x7E]*\z/

      # The handshake failed, or the server broke the protocol.
      class ProtocolError < StandardError; end

      # Where a WebSocket connects: its host, its port, the request target of its handshake, and
      # whether over TLS.
      Endpoint = Data.define(:host, :port, :target, :tls)
      private_constant :Endpoint

      def initialize(connector: TlsConnector.new, plain_connector: PlainConnector.new,
                     max_message_bytes: Internal::Protocol::MAX_RELAY_MESSAGE_BYTES)
        @connector = connector
        @plain_connector = plain_connector
        @max_message_bytes = max_message_bytes
      end

      # A WebSocket to `url` (`wss://host[:port][/path]`, or `ws://` to the merchant's Bitcoin node
      # on a local network: its scheme and authority a node URL's in `http`), open: its handshake
      # (the connection included) bounded by `timeout` seconds, given up when `cancellation` is
      # cancelled (Cancelled).
      def connect(url, timeout:, headers: {}, cancellation: Cancellation::NONE)
        holder = []
        endpoint, connector = endpoint_of(url)
        deadline = Internal::Clock.now + timeout
        handle = cancellation.on_cancel { holder.each { |io| close_quietly(io) } }
        io = connector.call(endpoint.host, endpoint.port, timeout)
        holder << io
        # Cancelled while the connector ran (a name's resolution does not stop at once): Cancelled.
        cancellation.raise_if_cancelled
        key = [SecureRandom.random_bytes(16)].pack("m0")
        io_write(io, request(endpoint, key, headers), deadline)
        rest = read_answer(io, key, deadline)
        Session.new(io, rest, @max_message_bytes, timeout)
      rescue StandardError
        holder.each { |opened| close_quietly(opened) }
        raise
      ensure
        cancellation.remove(handle)
      end

      # Writes all of `data` to `io` before `deadline` (Clock), else IO::TimeoutError. A connection
      # the peer closed fails (EOFError, or the error the write raises), never tried again until the
      # deadline: nothing written is no progress.
      def self.write_all(io, data, deadline)
        data = data.b
        until data.empty?
          written = io.write_nonblock(data, exception: false)
          if written.is_a?(Integer) && written.positive?
            data = data.byteslice(written..)
            next
          end
          raise EOFError, "The connection was closed while it was written to" unless WAITS.include?(written)

          left = Internal::Clock.left(deadline)
          ready = left.positive? && io.to_io.public_send(written, left)
          raise IO::TimeoutError, "Writing to the WebSocket timed out" unless ready
        end
      end

      # What a write that cannot go on yet answers: wait until the socket is ready.
      WAITS = %i[wait_readable wait_writable].freeze
      private_constant :WAITS

      private

      # Where `url` connects, and how: a relay's `wss://` address (Relays.endpoint) over TLS; or a
      # `ws://` URL of the merchant's Bitcoin node on a local network, in clear. ArgumentError for
      # any other.
      def endpoint_of(url)
        unless url.to_s.start_with?("ws://")
          relay = Internal::Relays.endpoint(url)
          return [Endpoint.new(host: relay.host, port: relay.port, target: relay.target, tls: true), @connector]
        end

        node = Internal::NodeUrl.origin_of(url)
        unless node&.local? && !node.tls?
          raise ArgumentError, "Not a wss:// address, nor a ws:// one of a merchant's node on a local network"
        end

        target = Internal::Urls.request_target(url.sub(%r{\Aws://[^/?#]*}, ""))
        [Endpoint.new(host: node.host, port: node.port, target: target, tls: false), @plain_connector]
      end

      def request(endpoint, key, headers)
        default_port = endpoint.tls ? 443 : 80
        host = endpoint.port == default_port ? endpoint.host : "#{endpoint.host}:#{endpoint.port}"
        lines = ["GET #{endpoint.target} HTTP/1.1", "Host: #{host}", "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Key: #{key}", "Sec-WebSocket-Version: 13"]
        headers.each do |name, value|
          unless name.to_s.match?(HEADER_NAME) && value.to_s.match?(HEADER_VALUE)
            raise ArgumentError, "Not an HTTP header: #{name}"
          end

          lines << "#{name}: #{value}"
        end
        "#{lines.join("\r\n")}\r\n\r\n"
      end

      # Reads the handshake's answer: 101 with the headers RFC 6455 asks, no extension nor protocol
      # (none was offered). What follows its head is the beginning of the frames.
      def read_answer(io, key, deadline)
        buffer = +"".b
        until (head_end = buffer.index("\r\n\r\n"))
          raise ProtocolError, "Handshake answer too long" if buffer.bytesize > MAX_HANDSHAKE_BYTES

          chunk = io_read(io, deadline)
          raise ProtocolError, "Connection closed during the handshake" if chunk.nil?

          buffer << chunk
        end
        raise ProtocolError, "Handshake answer too long" if head_end > MAX_HANDSHAKE_BYTES

        lines = buffer.byteslice(0, head_end).split("\r\n")
        status = lines.shift.to_s[%r{\AHTTP/1\.1 ([0-9]{3})(?: |\z)}, 1]
        raise ProtocolError, "Not an HTTP answer to the handshake" unless status
        raise ProtocolError, "The handshake answered a redirect (HTTP #{status})" if status.start_with?("3")
        raise ProtocolError, "The handshake was refused (HTTP #{status})" unless status == "101"

        check_headers(headers_of(lines), key)
        buffer.byteslice((head_end + 4)..)
      end

      def headers_of(lines)
        lines.each_with_object(Hash.new { |hash, name| hash[name] = [] }) do |line, headers|
          name, value = line.split(":", 2)
          raise ProtocolError, "Malformed handshake header" if value.nil? || !name.match?(HEADER_NAME)

          headers[name.downcase] << value.strip
        end
      end

      def check_headers(headers, key)
        accept = [OpenSSL::Digest::SHA1.digest(key + GUID)].pack("m0")
        unless headers["upgrade"].size == 1 && headers["upgrade"][0].casecmp?("websocket")
          raise ProtocolError, "The handshake did not upgrade to a WebSocket"
        end

        tokens = headers["connection"].flat_map { |value| value.split(",") }
        upgraded = tokens.any? { |token| token.strip.casecmp?("upgrade") }
        raise ProtocolError, "The handshake did not upgrade the connection" unless upgraded
        raise ProtocolError, "Wrong Sec-WebSocket-Accept" unless headers["sec-websocket-accept"] == [accept]
        raise ProtocolError, "An extension that was not offered" unless headers["sec-websocket-extensions"].empty?
        raise ProtocolError, "A subprotocol that was not offered" unless headers["sec-websocket-protocol"].empty?
      end

      def io_read(io, deadline)
        loop do
          chunk = io.read_nonblock(16_384, exception: false)
          return chunk unless %i[wait_readable wait_writable].include?(chunk)

          left = Internal::Clock.left(deadline)
          ready = left.positive? && io.to_io.public_send(chunk, left)
          raise IO::TimeoutError, "The handshake timed out" unless ready
        end
      end

      def io_write(io, data, deadline)
        WebSocketClient.write_all(io, data, deadline)
      end

      def close_quietly(io)
        io.close
      rescue StandardError
        nil
      end

      # An open WebSocket: text messages in and out. `receive` from one thread; `send_text` and
      # `close` from any.
      class Session
        OPCODES = { continuation: 0x0, text: 0x1, binary: 0x2, close: 0x8, ping: 0x9, pong: 0xA }.freeze

        def initialize(io, buffered, max_message_bytes, write_timeout)
          @io = io
          @buffer = buffered.b
          @max = max_message_bytes
          @write_timeout = write_timeout
          @write_mutex = Mutex.new
          @closed = false
        end

        # Sends a text message.
        def send_text(text)
          frame(OPCODES[:text], text.b)
          nil
        end

        # The next text message (a binary one as its bytes); nil once the connection is closed.
        # Answers pings, and the server's close. Raises WebSocketClient::ProtocolError when the
        # server breaks the protocol (a frame masked or reserved bits set, a message too large,
        # a text that is not UTF-8…), IOError or a SystemCallError when the connection fails.
        def receive
          message = nil
          kind = nil
          loop do
            fin, opcode, payload = read_frame(message ? message.bytesize : 0)
            return nil if payload.nil?

            case opcode
            when OPCODES[:ping]
              # Between the fragments of a message too (RFC 6455 §5.4): the message goes on.
              frame(OPCODES[:pong], payload)
              next
            when OPCODES[:pong] then next
            when OPCODES[:close]
              answer_close(payload)
              return nil
            when OPCODES[:continuation]
              raise ProtocolError, "A continuation without a message" if message.nil?

              message << payload
            when OPCODES[:text], OPCODES[:binary]
              raise ProtocolError, "A message inside another" if message

              message = payload
              kind = opcode
            else raise ProtocolError, "Unknown opcode #{opcode}"
            end
            next unless fin && message

            return kind == OPCODES[:text] ? text_of(message) : message
          end
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          return nil if @closed

          raise
        end

        # Closes the connection (a close frame first, when it can be written at once).
        def close
          return if @closed

          @closed = true
          # A close frame when no other write holds the socket (one blocked would delay the close).
          if @write_mutex.try_lock
            begin
              write_frame(OPCODES[:close], [1000].pack("n"), 0.2)
            rescue StandardError
              nil
            ensure
              @write_mutex.unlock
            end
          end
          begin
            @io.close
          rescue StandardError
            nil
          end
          nil
        end

        def closed?
          @closed
        end

        private

        def text_of(bytes)
          text = bytes.force_encoding(Encoding::UTF_8)
          raise ProtocolError, "A text message that is not UTF-8" unless text.valid_encoding?

          text
        end

        def answer_close(payload)
          code = payload.bytesize >= 2 ? payload.byteslice(0, 2) : "".b
          begin
            frame(OPCODES[:close], code, 1.0)
          rescue StandardError
            nil
          end
          @closed = true
          @io.close
        rescue StandardError
          nil
        end

        # The next frame: [fin, opcode, payload]; nil payload when the connection ended. A data
        # frame that would make its message longer than the limit fails before it is read.
        def read_frame(message_bytes)
          head = take(2)
          return [false, nil, nil] if head.nil?

          first, second = head.unpack("CC")
          raise ProtocolError, "Reserved bits set (no extension was negotiated)" unless first.nobits?(0x70)
          raise ProtocolError, "A masked frame from the server" if second.anybits?(0x80)

          fin = first.anybits?(0x80)
          opcode = first & 0x0F
          length = second & 0x7F
          length = take!(2).unpack1("n") if length == 126
          if length == 127
            length = take!(8).unpack1("Q>")
            raise ProtocolError, "A frame length above 2^63" if length >= 2**63
          end
          if opcode >= 0x8
            raise ProtocolError, "A control frame fragmented or too long" unless fin && length <= 125
          elsif message_bytes + length > @max
            raise ProtocolError, "A message of more than #{@max} bytes"
          end

          [fin, opcode, take!(length)]
        end

        def take!(count)
          take(count) || raise(ProtocolError, "The connection ended within a frame")
        end

        # `count` bytes of the stream; nil when it ends before.
        def take(count)
          while @buffer.bytesize < count
            chunk = read_chunk
            return nil if chunk.nil?

            @buffer << chunk
          end
          taken = @buffer.byteslice(0, count)
          @buffer = @buffer.byteslice(count..)
          taken
        end

        def read_chunk
          loop do
            chunk = @io.read_nonblock(65_536, exception: false)
            return chunk&.b unless %i[wait_readable wait_writable].include?(chunk)

            @io.to_io.public_send(chunk)
          end
        end

        def frame(opcode, payload, timeout = @write_timeout)
          @write_mutex.synchronize { write_frame(opcode, payload, timeout) }
        end

        def write_frame(opcode, payload, timeout)
          length = payload.bytesize
          header = [0x80 | opcode].pack("C")
          header << if length <= 125
                      [0x80 | length].pack("C")
                    elsif length <= 0xFFFF
                      [0x80 | 126, length].pack("Cn")
                    else
                      [0x80 | 127, length].pack("CQ>")
                    end
          mask = SecureRandom.random_bytes(4)
          WebSocketClient.write_all(@io, header << mask << masked(payload, mask), Internal::Clock.now + timeout)
        end

        # `payload` XOR the masking key repeated (RFC 6455 §5.3), four bytes at a time.
        def masked(payload, mask)
          return payload if payload.empty?

          padding = (-payload.bytesize) % 4
          key = mask.unpack1("N")
          words = (payload + ("\0" * padding)).unpack("N*").map { |word| word ^ key }
          words.pack("N*").byteslice(0, payload.bytesize)
        end
      end
    end
  end
end
