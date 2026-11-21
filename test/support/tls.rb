# frozen_string_literal: true

require "openssl"
require "socket"

# TLS for tests: a certificate authority of the test run, the certificates it signs, an https
# server and an HTTP proxy that tunnels (CONNECT), all on 127.0.0.1. Never the network.
module TestTls
  module_function

  def generate_key = OpenSSL::PKey::EC.generate("prime256v1")

  # The test run's authority: [key, certificate].
  def authority
    @authority ||= begin
      key = generate_key
      name = OpenSSL::X509::Name.parse("/CN=sattleme-checkout tests")
      cert = certificate(name, name, key, 1)
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign, cRLSign", true))
      cert.add_extension(extensions.create_extension("subjectKeyIdentifier", "hash", false))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      [key, cert]
    end
  end

  def certificate(subject, issuer, key, serial)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = subject
    cert.issuer = issuer
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert
  end

  # A server's key and certificate for `names` (DNS) and `ips`, signed by the authority (or by a
  # key of its own: `trusted` false).
  def leaf(names: [], ips: [], trusted: true)
    ca_key, ca_cert = authority
    key = generate_key
    subject = OpenSSL::X509::Name.parse("/CN=#{names.first || ips.first}")
    issuer = trusted ? ca_cert.subject : subject
    cert = certificate(subject, issuer, key, rand(2**32))
    extensions = OpenSSL::X509::ExtensionFactory.new(trusted ? ca_cert : cert, cert)
    alt = names.map { |name| "DNS:#{name}" } + ips.map { |ip| "IP:#{ip}" }
    cert.add_extension(extensions.create_extension("subjectAltName", alt.join(","), false))
    cert.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth", false))
    cert.sign(trusted ? ca_key : key, OpenSSL::Digest.new("SHA256"))
    [key, cert]
  end

  # The head of an HTTP request (up to its blank line), nil when the connection ends before.
  def read_head(io)
    head = +"".b
    until head.end_with?("\r\n\r\n")
      byte = io.read(1)
      return nil if byte.nil?

      head << byte
    end
    head
  end

  # The store that trusts the authority alone.
  def store
    OpenSSL::X509::Store.new.tap { |store| store.add_cert(authority[1]) }
  end

  # A server's TLS context for `names` and `ips`.
  def server_context(names: [], ips: [], trusted: true)
    key, cert = leaf(names: names, ips: ips, trusted: trusted)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    context.min_version = OpenSSL::SSL::TLS1_2_VERSION
    context
  end

  # A client's TLS context trusting the authority alone, as TlsConnector makes its own.
  def client_context
    context = OpenSSL::SSL::SSLContext.new
    context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true, cert_store: store)
    context.min_version = OpenSSL::SSL::TLS1_2_VERSION
    context
  end
end

# An https server on 127.0.0.1 (an http one with `tls: false`): each request goes to the route,
# which answers [status, headers, body] (a body of chunks: an Array of Strings, written one after
# the other), or a callable that writes the whole answer itself, as it is, to the socket it is
# given.
class TestHttpsServer
  Request = Data.define(:line, :headers)

  attr_reader :port

  def initialize(names: [], ips: [], tls: true, &route)
    @context = tls ? TestTls.server_context(names: names, ips: ips) : nil
    @route = route
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @requests = []
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def requests = @mutex.synchronize { @requests.dup }

  def close
    @server.close
  rescue IOError, SystemCallError
    nil
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      thread = Thread.new(client) { |socket| serve(socket) }
      thread.report_on_exception = false
    end
  rescue IOError, SystemCallError
    nil
  end

  def serve(tcp)
    if @context
      socket = OpenSSL::SSL::SSLSocket.new(tcp, @context)
      socket.sync_close = true
      socket.accept
    else
      socket = tcp
    end
    head = TestTls.read_head(socket)
    return if head.nil?

    line, *fields = head.split("\r\n")
    headers = fields.to_h do |field|
      name, value = field.split(":", 2)
      [name.strip.downcase, value.to_s.strip]
    end
    request = Request.new(line: line, headers: headers)
    @mutex.synchronize { @requests << request }
    answer = @route.call(request)
    return answer.call(socket) if answer.respond_to?(:call)

    status, answer_headers, chunks = answer
    socket.write("HTTP/1.1 #{status} Answer\r\n#{answer_headers.map { |name, value| "#{name}: #{value}\r\n" }.join}" \
                 "Connection: close\r\n\r\n")
    chunks.each { |chunk| socket.write(chunk) }
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    begin
      (socket || tcp).close
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end
  end
end

# An HTTP proxy on 127.0.0.1 that tunnels every CONNECT to 127.0.0.1:`target_port`, whatever host
# it names: the host stays the client's (its TLS name).
class TestConnectProxy
  attr_reader :port

  def initialize(target_port)
    @target_port = target_port
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @requests = []
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  # The request lines it got ("CONNECT breez.test:443 HTTP/1.1").
  def requests = @mutex.synchronize { @requests.dup }

  def close
    @server.close
  rescue IOError, SystemCallError
    nil
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      thread = Thread.new(client) { |socket| tunnel(socket) }
      thread.report_on_exception = false
    end
  rescue IOError, SystemCallError
    nil
  end

  def tunnel(client)
    head = TestTls.read_head(client)
    return if head.nil?

    @mutex.synchronize { @requests << head.split("\r\n").first }
    upstream = TCPSocket.new("127.0.0.1", @target_port)
    client.write("HTTP/1.1 200 Connection established\r\n\r\n")
    [Thread.new { copy(client, upstream) }, Thread.new { copy(upstream, client) }].each(&:join)
  rescue IOError, SystemCallError
    nil
  ensure
    client.close
    upstream&.close
  end

  def copy(from, to)
    IO.copy_stream(from, to)
  rescue IOError, SystemCallError
    nil
  ensure
    begin
      to.close_write
    rescue IOError, SystemCallError
      nil
    end
  end
end
