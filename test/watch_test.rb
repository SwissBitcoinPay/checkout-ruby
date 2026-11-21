# frozen_string_literal: true

require_relative "test_helper"

# The explorer's WebSocket while wait_for_payment waits (SPEC.md §31, "Waiting for an on-chain
# payment"): a lost socket connects again after 1 s, doubled at each failure up to 30 s, a
# connection lost before it received a message being a failure. Each connection starts a full
# check: a server that accepts and drops every connection must not have one every second. Sockets
# in memory, and the waits between two connections given to the test.
class WatchTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ADDRESS = TestChain.deposit_address(1)

  # A socket in memory: the test has it receive messages, then drops it.
  class MemorySocket
    Json = Sattleme::Checkout::Internal::Json

    def initialize
      @received = Queue.new
      @sent = Queue.new
    end

    def send_text(text) = @sent << text
    def receive = @received.pop
    def close = @received << nil

    # What the watcher sent, as JSON.
    def sent = Array.new(@sent.size) { Json.parse(@sent.pop) }

    def message(value) = @received << Json.generate(value)
    def drop = @received << nil
  end

  # A WebSocket client whose every connection is a MemorySocket, given to the test.
  class MemoryWebSocket
    attr_reader :sockets, :urls

    def initialize
      @sockets = Queue.new
      @urls = Queue.new
    end

    def connect(url, timeout:, headers:, cancellation:) # rubocop:disable Lint/UnusedMethodArgument
      @urls << url
      MemorySocket.new.tap { |socket| @sockets << socket }
    end
  end

  def setup
    @websocket = MemoryWebSocket.new
    # Each wait between two connections: its seconds, then whether the watcher was closed meanwhile,
    # as the test says.
    @delays = Queue.new
    @go_on = Queue.new
    @changes = Queue.new
    explorer = CallExplorer.new(nil, NodeFailures.new, -> { 0 })
    @watch = Watch.new(@websocket, explorer, ADDRESS, 2, wait: lambda { |seconds|
      @delays << seconds
      @go_on.pop
    }) { @changes << :change }
  end

  def teardown
    @watch.close
    @go_on << true
  end

  def next_socket = @websocket.sockets.pop(timeout: 10) || flunk("No connection")
  def next_delay = @delays.pop(timeout: 10) || flunk("No wait")

  test "tracks the address and checks at each connection" do
    socket = next_socket
    assert_equal [Protocol::MEMPOOL_WEBSOCKET_URL], [@websocket.urls.pop]
    eventually { @changes.size == 1 }
    assert_equal [{ "action" => "want", "data" => ["blocks"] }, { "track-address" => ADDRESS }], socket.sent
    socket.message({ "block" => { "height" => 970_001 } })
    eventually { @changes.size == 2 }
    # Anything else changes nothing.
    socket.message({ "conversions" => {} })
    socket.message({ "address-transactions" => [] })
    eventually { @changes.size == 3 }
  end

  test "waits longer at each connection dropped before a message: 1 s, doubled up to 30 s" do
    delays = Array.new(7) do
      next_socket.drop
      next_delay.tap { @go_on << false }
    end
    assert_equal [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0], delays
    # One check per connection: eight in some 91 s, never one a second.
    next_socket
    eventually { @changes.size == 8 }
  end

  test "waits 1 s again once a connection received a message" do
    next_socket.drop
    assert_equal 1.0, next_delay
    @go_on << false
    next_socket.drop
    assert_equal 2.0, next_delay
    @go_on << false
    socket = next_socket
    socket.message({ "address-transactions" => [] })
    socket.drop
    assert_equal 1.0, next_delay
  end

  test "connects no more once closed" do
    next_socket.drop
    next_delay
    @watch.close
    @go_on << true
    assert_nil @websocket.sockets.pop(timeout: 0.5)
  end
end
