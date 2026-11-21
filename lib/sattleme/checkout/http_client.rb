# frozen_string_literal: true

require "openssl"

module Sattleme
  module Checkout
    # The platform's HTTP client, the gem's own, for the Lightning address, the rate sources and the
    # explorer (SPEC.md §15): a GET over TLS (TlsConnector: the certificate and the host name
    # verified, TLS 1.2 at least) in HTTP/1.1, no redirect followed (a 3xx is an answer as any
    # other), no compression asked, the whole request bounded by `timeout`. Every part of an answer
    # is bounded as it comes: its head (status line and headers) at MAX_HEAD_BYTES, what it holds
    # besides its body (its heads, a chunked body's size lines and trailers) at MAX_FRAMING_BYTES in
    # all, and its body is given chunk by chunk (the gem stops reading at 1 MiB): a server cannot
    # make the process hold more than that. No proxy, not even one of the environment: give one
    # (`proxy: URI("http://proxy:3128")`, an HTTP proxy that tunnels with CONNECT), or inject a
    # client of your own. The certificates it trusts are the system's, or those of `cert_store:`
    # (an OpenSSL::X509::Store: a company's CA). It asks https URLs, and those of the merchant's
    # Bitcoin node (SPEC.md §31), whose URL follows a rule of its own: `https` to an IPv4 address
    # too, and `http`, in clear (no TLS), to a host of a local network alone (10.0.0.0/8,
    # 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, names under `.local`); every other rule holds.
    #
    # Inject another as `http_client:` of a Client: anything that answers
    # `get(url, headers:, timeout:, cancellation:) { |chunk| … }`, yields the body's chunks
    # (Strings) as they come and returns the HTTP status (an Integer). `timeout` is in seconds;
    # `cancellation` is cancelled when the gem gives up the request (its time ran out, its call was
    # cancelled): stop then. Keep it bounded as this one is. It gets an `http://` URL only to read a
    # merchant's node on a local network: ask it in clear HTTP, or fail (raise), and the node's
    # fallback applies.
    class HttpClient
      # The longest head of an answer read: its status line, its headers and the blank line after
      # them (as undici's, and the WebSocket client's handshake answer).
      MAX_HEAD_BYTES = 16_384
      # What an answer may hold besides its body, in all: its heads (an interim answer's too) and a
      # chunked body's size lines, line ends and trailers (SPEC.md §15: 10 MiB at most).
      MAX_FRAMING_BYTES = 10 * 1024 * 1024
      # What is read at a time.
      READ_BYTES = 16_384
      STATUS_LINE = %r{\AHTTP/1\.[01] ([0-9]{3})(?: .*)?\z}n
      CHUNK_SIZE = /\A([0-9a-fA-F]{1,15})[ \t]*(?:;.*)?\z/n

      # The answer is not HTTP/1.1, or goes beyond a bound.
      class ProtocolError < StandardError; end

      # Where a URL is asked: its host, its port, and whether over TLS.
      Target = Data.define(:host, :port, :tls) do
        def default_port = tls ? 443 : 80
      end
      private_constant :Target

      def initialize(proxy: nil, cert_store: nil)
        raise ArgumentError, "proxy: a URI with a host and a port" unless proxy.nil? || proxy.respond_to?(:host)
        unless cert_store.nil? || cert_store.is_a?(OpenSSL::X509::Store)
          raise ArgumentError, "cert_store: an OpenSSL::X509::Store"
        end

        @proxy = proxy
        context = OpenSSL::SSL::SSLContext.new
        params = { verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true }
        params[:cert_store] = cert_store if cert_store
        context.set_params(params)
        context.min_version = OpenSSL::SSL::TLS1_2_VERSION
        context.alpn_protocols = ["http/1.1"]
        @tls = TlsConnector.new(ssl_context: context)
      end

      def get(url, headers:, timeout:, cancellation: Cancellation::NONE, &)
        target = target_of(url)
        unless target
          raise ArgumentError, "Not an https URL, nor one of a merchant's Bitcoin node (http: on a local network)"
        end

        request = request(url, target, headers)
        deadline = Internal::Clock.now + timeout
        opened = []
        handle = cancellation.on_cancel { opened.each { |io| close_quietly(io) } }
        begin
          cancellation.raise_if_cancelled
          io = connect(target, deadline, opened)
          cancellation.raise_if_cancelled
          WebSocketClient.write_all(io, request, deadline)
          Answer.new(io, deadline).read(&)
        ensure
          cancellation.remove(handle)
          opened.each { |io| close_quietly(io) }
        end
      end

      private

      # Where `url` is asked: its host, its port and whether over TLS. An https URL (Urls.https_url);
      # or a URL under a merchant's Bitcoin node (SPEC.md §31), its scheme and authority a node
      # URL's (NodeUrl): `https`, an IPv4 address too, or `http` to a host of a local network alone.
      # Nil for any other URL.
      def target_of(url)
        https = Internal::Urls.https_url(url)
        return Target.new(host: https.host, port: https.port, tls: true) if https
        return nil unless url.is_a?(String) && url.match?(%r{\Ahttps?://})

        node = Internal::NodeUrl.origin_of(url)
        node && Target.new(host: node.host, port: node.port, tls: node.tls?)
      end

      def request(url, target, headers)
        host = target.port == target.default_port ? target.host : "#{target.host}:#{target.port}"
        path = Internal::Urls.request_target(url.sub(%r{\Ahttps?://[^/?#]*}, ""))
        lines = ["GET #{path} HTTP/1.1", "Host: #{host}"]
        headers.merge("Accept-Encoding" => "identity", "Connection" => "close").each do |name, value|
          unless name.to_s.match?(WebSocketClient::HEADER_NAME) && value.to_s.match?(WebSocketClient::HEADER_VALUE)
            raise ArgumentError, "Not an HTTP header: #{name}"
          end

          lines << "#{name}: #{value}"
        end
        "#{lines.join("\r\n")}\r\n\r\n"
      end

      # TLS to the host of `target` (a TCP connection alone to a local node asked over `http`),
      # through the proxy's tunnel when there is one: each socket opened is added to `opened`, which
      # the call's cancellation closes.
      def connect(target, deadline, opened)
        tcp = @tls.connect_tcp(@proxy ? @proxy.host : target.host, @proxy ? @proxy.port : target.port, deadline)
        opened << tcp
        tunnel(tcp, target, deadline) if @proxy
        return tcp unless target.tls

        ssl = @tls.handshake(tcp, target.host, deadline)
        opened << ssl
        ssl
      end

      # Asks the proxy for a tunnel to the host and port of `target` (CONNECT): it answers a head
      # alone, 2xx when it opened it.
      def tunnel(io, target, deadline)
        authority = "#{target.host}:#{target.port}"
        lines = ["CONNECT #{authority} HTTP/1.1", "Host: #{authority}"]
        lines << "Proxy-Authorization: Basic #{["#{@proxy.user}:#{@proxy.password}"].pack("m0")}" if @proxy.user
        WebSocketClient.write_all(io, "#{lines.join("\r\n")}\r\n\r\n", deadline)
        answer = Answer.new(io, deadline)
        status, = answer.head
        raise ProtocolError, "The proxy refused the tunnel (HTTP #{status})" unless status.between?(200, 299)
        raise ProtocolError, "The proxy sent more than its answer" unless answer.drained?
      end

      def close_quietly(io)
        io.close
      rescue StandardError
        nil
      end

      # One answer, read from `io` by `deadline`, each part bounded as it comes.
      class Answer
        def initialize(io, deadline)
          @io = io
          @deadline = deadline
          @buffer = +"".b
          # The bytes read besides the body.
          @framing = 0
        end

        # The final answer's status, its body given to the block chunk by chunk.
        def read(&)
          status, fields = head
          # Interim answers (100 Continue, 103 Early Hints), a head each: the final one follows.
          status, fields = head while status.between?(100, 199) && status != 101
          raise ProtocolError, "The answer switched protocols, which was not asked" if status == 101

          body(status, fields, &) unless [204, 304].include?(status)
          status
        end

        # The next head: [status, its fields by lower-case name].
        def head
          started = @framing
          left = -> { MAX_HEAD_BYTES - (@framing - started) }
          status = STATUS_LINE.match(line(left.call))&.[](1)
          raise ProtocolError, "Not an HTTP/1.1 answer" unless status

          fields = Hash.new { |hash, name| hash[name] = [] }
          until (text = line(left.call)).empty?
            name, value = text.split(":", 2)
            raise ProtocolError, "A malformed header" if value.nil? || !name.match?(WebSocketClient::HEADER_NAME)

            fields[name.downcase] << value.sub(/\A[ \t]+/, "").sub(/[ \t]+\z/, "")
          end
          [Integer(status, 10), fields]
        end

        # Whether nothing was read past what was read so far.
        def drained?
          @buffer.empty?
        end

        private

        # RFC 9112 §6.3: chunked, else as long as its length, else until the connection ends.
        def body(_status, fields, &)
          codings = fields.fetch("transfer-encoding", []).flat_map { |value| value.split(",") }
                          .map { |coding| coding.strip.downcase }
          return (codings.last == "chunked" ? chunked(&) : to_end(&)) unless codings.empty?

          length = content_length(fields.fetch("content-length", []))
          length ? exactly(length, &) : to_end(&)
        end

        # The length its Content-Length headers say (one value, written once or repeated); nil
        # without one.
        def content_length(values)
          lengths = values.flat_map { |value| value.split(",") }.map(&:strip).uniq
          return nil if lengths.empty?
          unless lengths.size == 1 && lengths[0].match?(/\A[0-9]{1,15}\z/)
            raise ProtocolError, "An invalid Content-Length"
          end

          Integer(lengths[0], 10)
        end

        def chunked(&)
          loop do
            size = CHUNK_SIZE.match(line(MAX_HEAD_BYTES))&.[](1)
            raise ProtocolError, "Not a chunk's size" unless size
            break if size.to_i(16).zero?

            exactly(size.to_i(16), &)
            raise ProtocolError, "A chunk without its line end" unless line(2).empty?
          end
          # Its trailers, up to a blank line.
          nil until line(MAX_HEAD_BYTES).empty?
        end

        # `count` bytes of the body, given as they come.
        def exactly(count)
          until count.zero?
            raise EOFError, "The connection ended within the answer's body" if @buffer.empty? && !fill

            taken = [count, @buffer.bytesize].min
            yield @buffer.byteslice(0, taken)
            @buffer = @buffer.byteslice(taken..)
            count -= taken
          end
        end

        # The body, until the connection ends.
        def to_end
          loop do
            yield @buffer unless @buffer.empty?
            @buffer = +"".b
            break unless fill
          end
        end

        # The next line, without its line end (CR LF, or LF), of `limit` bytes at most with it: a
        # longer one fails before more of it is read.
        def line(limit)
          scanned = 0
          until (index = @buffer.index("\n", scanned))
            scanned = @buffer.bytesize
            raise ProtocolError, "A line of the answer longer than #{limit} bytes" if scanned >= limit
            raise EOFError, "The connection ended within a line of the answer" unless fill
          end
          length = index + 1
          raise ProtocolError, "A line of the answer longer than #{limit} bytes" if length > limit

          @framing += length
          raise ProtocolError, "More than #{MAX_FRAMING_BYTES} bytes besides the body" if @framing > MAX_FRAMING_BYTES

          text = @buffer.byteslice(0, index)
          @buffer = @buffer.byteslice(length..)
          text.delete_suffix("\r")
        end

        # Reads what came into the buffer, waiting for it until the deadline: false once the
        # connection ended.
        def fill
          loop do
            left = Internal::Clock.left(@deadline)
            raise IO::TimeoutError, "The answer took longer than its timeout" if left.zero?

            chunk = @io.read_nonblock(READ_BYTES, exception: false)
            case chunk
            when nil then return false
            when :wait_readable, :wait_writable
              ready = @io.to_io.public_send(chunk, left)
              raise IO::TimeoutError, "The answer took longer than its timeout" unless ready
            else
              @buffer << chunk
              return true
            end
          end
        end
      end
      private_constant :Answer
    end
  end
end
