# frozen_string_literal: true

require "securerandom"
require "socket"
require_relative "websocket_server"

# Local Nostr relays for tests (NIP-01, NIP-42), each a WebSocket server on a free port of
# 127.0.0.1. A relay keeps the newest event of each address, as strfry does, and can refuse writes,
# ask for authentication, cap its answers or never answer at all. The gem reaches them under
# `wss://` names (the only relays a key or a channel may name) through its own WebSocket client,
# whose connector the test injects (RelayNet#websocket_client): the handshake, the frames and the
# limits are the gem's, only TLS is left out.
class LocalRelay
  Json = Sattleme::Checkout::Internal::Json
  Events = Sattleme::Checkout::Internal::Events

  # What a relay does, beyond keeping events (each optional):
  # - refuse: refuses every event with this reason;
  # - refuse_event: refuses the events it gives a reason for;
  # - mute: accepts connections and never sends anything;
  # - require_auth: asks every connection to authenticate (NIP-42) before reading or writing: with
  #   NIP-42's ["AUTH", <event>] alone (an event of kind 22242 sent as an EVENT is refused, and
  #   authenticates nothing: test/hardening_test.rb);
  # - mute_auth: never answers an authentication (no OK);
  # - auth_delay_ms: answers each authentication this many milliseconds late;
  # - cap: sends at most this many events per query, the newest first (strfry: 500);
  # - mute_query: never answers the queries it gives true for (no event, no EOSE);
  # - query_delay_ms: answers each query this many milliseconds late (writes at once);
  # - oldest_first_without_limit: answers a filter without `limit` oldest first (nostr-rs-relay);
  # - hide: leaves out of its answers the events it gives true for: a hostile relay;
  # - on_event: hears each event the relay took, once it keeps it;
  # - pages: answers its queries in turn with these pages, whatever they ask and whatever it holds:
  #   each an array of events sent as they are, "fails" (CLOSED) or "mute" (no answer at all);
  #   past the last, an empty page.
  attr_accessor :behaviour
  attr_reader :server

  def initialize(behaviour = {})
    @behaviour = behaviour
    @mutex = Mutex.new
    @events = []
    @received = []
    @queries = []
    @authenticated = []
    @closed_subscriptions = []
    @pages_asked = 0
    @server = TestWebSocketServer.new(on_connection: ->(connection) { serve(connection) })
  end

  def port = @server.port

  def events = @mutex.synchronize { @events.dup }

  # Every event a client sent, accepted or not.
  def received = @mutex.synchronize { @received.dup }

  # Every filter a client asked.
  def queries = @mutex.synchronize { @queries.dup }

  # The public keys that authenticated.
  def authenticated = @mutex.synchronize { @authenticated.dup }

  # Subscriptions a client closed (NIP-01 CLOSE).
  def closed_subscriptions = @mutex.synchronize { @closed_subscriptions.dup }

  # The handshakes' request headers.
  def handshakes = @server.handshakes

  # Stores `value` as it is (an invalid event too: a relay is never trusted).
  def store(value)
    @mutex.synchronize { @events << json_of(value) }
  end

  # Takes `event` as a client's write: the newest of its address is kept.
  def take(event)
    @mutex.synchronize { keep(json_of(event)) }
  end

  # Forgets every event it holds.
  def clear
    @mutex.synchronize { @events.clear }
  end

  def close
    @server.close
  end

  private

  def json_of(value)
    value.respond_to?(:to_h) && !value.is_a?(Hash) ? value.to_h : value
  end

  def serve(connection)
    thread = Thread.new do
      challenge = SecureRandom.uuid
      authed = nil
      send = ->(message) { connection.send_text(Json.generate(message)) }
      send.call(["AUTH", challenge]) if behaviour[:require_auth] && !behaviour[:mute]
      while (message = connection.read_message)
        next if behaviour[:mute]

        text = message[1]
        parsed = Json.parse_or(text)
        next unless parsed.is_a?(Array)

        authed = handle(parsed, send, challenge, authed)
      end
    end
    thread.report_on_exception = false
  end

  def handle(message, send, challenge, authed)
    type, *rest = message
    case type
    when "AUTH"
      return authed if behaviour[:mute_auth]

      # ["AUTH", <event>]: its event of kind 22242, with the relay's URL and the last challenge.
      auth = rest[0]
      ok = rest.size == 1 && Events.valid?(auth) && auth["kind"] == 22_242 &&
           auth["tags"].any? { |tag| tag[0] == "relay" && tag[1].is_a?(String) } &&
           auth["tags"].any? { |tag| tag[0] == "challenge" && tag[1] == challenge }
      if ok
        authed = auth["pubkey"]
        @mutex.synchronize { @authenticated << auth["pubkey"] }
      end
      answer = ["OK", auth.is_a?(Hash) ? auth["id"] : nil, ok, ok ? "" : "invalid: bad auth"]
      later(behaviour[:auth_delay_ms]) { send.call(answer) }
    when "EVENT" then write(rest[0], send, authed)
    when "REQ" then read(rest, send, authed)
    when "CLOSE" then @mutex.synchronize { @closed_subscriptions << rest[0].to_s }
    end
    authed
  end

  def write(event, send, authed)
    fields = event.is_a?(Hash) ? event : {}
    valid = Events.valid?(event)
    @mutex.synchronize { @received << event } if valid
    reason = behaviour[:refuse_event]&.call(event) if valid
    if fields["kind"] == 22_242
      # An authentication is NIP-42's AUTH message, never an EVENT: refused, kept nowhere, and it
      # authenticates nothing.
      send.call(["OK", fields["id"], false, "invalid: an authentication is sent as AUTH, not as an EVENT"])
    elsif behaviour[:require_auth] && authed != fields["pubkey"]
      send.call(["OK", fields["id"], false, "auth-required: sign in first"])
    elsif behaviour[:refuse]
      send.call(["OK", fields["id"], false, behaviour[:refuse]])
    elsif reason
      send.call(["OK", fields["id"], false, reason])
    elsif !valid
      send.call(["OK", fields["id"], false, "invalid: bad event"])
    else
      @mutex.synchronize { keep(event) }
      behaviour[:on_event]&.call(event, self)
      send.call(["OK", event["id"], true, ""])
    end
  end

  def read(rest, send, authed)
    id, *filters = rest
    @mutex.synchronize { @queries.concat(filters) }
    if behaviour[:require_auth] && authed.nil?
      send.call(["CLOSED", id, "auth-required: sign in first"])
      return
    end
    return if filters.any? { |filter| behaviour[:mute_query]&.call(filter) }

    page = next_page if behaviour[:pages]
    answer = lambda do
      next send_page(id, page, send) if behaviour[:pages]

      match(filters).each { |event| send.call(["EVENT", id, event]) }
      send.call(["EOSE", id])
    end
    later(behaviour[:query_delay_ms], &answer)
  end

  # Runs the block `delay_ms` milliseconds from now, in a thread of its own (at once without one).
  def later(delay_ms, &block)
    return block.call unless delay_ms

    thread = Thread.new do
      sleep(delay_ms / 1000.0)
      block.call
    end
    thread.report_on_exception = false
  end

  # The page of behaviour[:pages] that answers the next query.
  def next_page
    @mutex.synchronize do
      @pages_asked += 1
      behaviour[:pages][@pages_asked - 1] || []
    end
  end

  # `page` of behaviour[:pages], as the answer to the query `id`.
  def send_page(id, page, send)
    case page
    when "fails" then send.call(["CLOSED", id, "error: this page fails"])
    when "mute" then nil
    else
      page.each { |event| send.call(["EVENT", id, event]) }
      send.call(["EOSE", id])
    end
  end

  def d_of(event)
    tags = event.is_a?(Hash) && event["tags"].is_a?(Array) ? event["tags"] : []
    tags.find { |tag| tag.is_a?(Array) && tag[0] == "d" }&.[](1) || ""
  end

  # Keeps the newest event of an address (kind 30000–39999), as relays do (NIP-01).
  def keep(event)
    if event["kind"] >= 30_000 && event["kind"] < 40_000
      index = @events.index do |other|
        other.is_a?(Hash) && other["kind"] == event["kind"] && other["pubkey"] == event["pubkey"] &&
          d_of(other) == d_of(event)
      end
      if index
        old = @events[index]
        # The newest kept; of one second, the lowest id (NIP-01).
        return if old["created_at"] > event["created_at"] ||
                  (old["created_at"] == event["created_at"] && old["id"] <= event["id"])

        @events.delete_at(index)
      end
    end
    @events << event
  end

  def matches?(event, filter)
    return false unless event.is_a?(Hash)
    return false if filter["ids"] && !filter["ids"].include?(event["id"])
    return false if filter["kinds"] && !filter["kinds"].include?(event["kind"])
    return false if filter["authors"] && !filter["authors"].include?(event["pubkey"])

    tags = event["tags"].is_a?(Array) ? event["tags"] : []
    %w[d o].each do |name|
      values = filter["##{name}"]
      next unless values
      return false unless tags.any? { |tag| tag.is_a?(Array) && tag[0] == name && values.include?(tag[1]) }
    end
    created_at = event["created_at"].is_a?(Numeric) ? event["created_at"] : 0
    return false if filter["since"] && created_at < filter["since"]
    return false if filter["until"] && created_at > filter["until"]

    true
  end

  def match(filters)
    found = events.select do |event|
      next false if behaviour[:hide]&.call(event)

      filters.any? { |filter| matches?(event, filter) }
    end
    created = ->(event) { event.is_a?(Hash) && event["created_at"].is_a?(Numeric) ? event["created_at"] : 0 }
    found.sort! do |a, b|
      order = created.call(b) <=> created.call(a)
      order.zero? ? a["id"].to_s <=> b["id"].to_s : order
    end
    found.reverse! if behaviour[:oldest_first_without_limit] && filters.all? { |filter| filter["limit"].nil? }
    limits = filters.map { |filter| filter["limit"] || Float::INFINITY } + [behaviour[:cap] || Float::INFINITY]
    limit = limits.min
    limit.infinite? ? found : found.first(limit.to_i)
  end
end

# Relays of a test, by their `wss://` name.
class RelayNet
  def initialize
    @mutex = Mutex.new
    @relays = {}
    @servers = {}
    @blackholes = {}
    @connections = Hash.new(0)
  end

  # How many connections each name got.
  def connections = @mutex.synchronize { @connections.dup }

  def add(url, behaviour = {})
    relay = LocalRelay.new(behaviour)
    @mutex.synchronize { @relays[url] = relay }
    relay
  end

  # A plain WebSocket server reached at `url`: the test answers its clients itself.
  def add_server(url, server)
    @mutex.synchronize { @servers[url] = server }
    server
  end

  # A name whose server takes the TCP connection and never answers the WebSocket handshake.
  def add_blackhole(url)
    server = TCPServer.new("127.0.0.1", 0)
    sockets = []
    thread = Thread.new do
      loop { sockets << server.accept }
    rescue IOError, SystemCallError
      nil
    end
    thread.report_on_exception = false
    @mutex.synchronize { @blackholes[url] = [server, sockets] }
  end

  # Stops the relay of `url`: its name refuses connections from now on.
  def remove(url)
    relay = @mutex.synchronize { @relays.delete(url) }
    relay&.close
  end

  def get(url)
    @mutex.synchronize { @relays[url] } || raise(ArgumentError, "No relay #{url}")
  end

  def relays = @mutex.synchronize { @relays.dup }

  # The port that serves `url`, nil when nothing does.
  def port_of(url)
    @mutex.synchronize do
      blackhole = @blackholes[url]&.first
      @relays[url]&.port || @servers[url]&.port || blackhole&.addr&.[](1)
    end
  end

  # The gem's WebSocket client, connected to the local server of each name (plain TCP), `wss://`
  # and `ws://` (a merchant's Bitcoin node on a local network) alike.
  def websocket_client
    Sattleme::Checkout::WebSocketClient.new(connector: method(:connect), plain_connector: method(:connect))
  end

  # The host and port a name (`wss://host[:port][/path]`, or `ws://`) connects to.
  def self.host_and_port(name)
    scheme, host, port = %r{\A(wss?)://([^/:]+)(?::([0-9]+))?}.match(name).captures
    [host, port ? port.to_i : { "wss" => 443, "ws" => 80 }.fetch(scheme)]
  end

  # The connector of the WebSocket client: `wss://host[:port][/path]` (or `ws://`) names one of the
  # test's servers by its host and port.
  def connect(host, port, _timeout)
    url = @mutex.synchronize do
      (@relays.keys + @servers.keys + @blackholes.keys).find do |name|
        RelayNet.host_and_port(name) == [host, port]
      end
    end
    @mutex.synchronize { @connections[url || "wss://#{host}"] += 1 }
    local = url && port_of(url)
    raise Errno::ECONNREFUSED, "#{host}:#{port}" unless local

    TCPSocket.new("127.0.0.1", local)
  end

  def close
    servers, blackholes, relays = @mutex.synchronize { [@servers.values, @blackholes.values, @relays.values] }
    servers.each(&:close)
    blackholes.each do |server, sockets|
      sockets.each(&:close)
      server.close
    rescue IOError, SystemCallError
      nil
    end
    relays.each(&:close)
  end
end
