# frozen_string_literal: true

require_relative "test_helper"

# What may outlive a call (SPEC.md §4, §13): the relays of a publication past its majority may
# finish their own request (NIP-42's one authentication and the one write again included), within
# the relay timeout; nothing else a call started runs on once it returned: a read or a check it no
# longer needed (after an error), an HTTP request it gave up, the explorer's WebSocket. Every
# thread the gem starts is named "sattleme-checkout …"; those of a publication's tail are its
# writes ("relay write"), the thread that closes the connections after them ("relay release") and
# the connections they still use ("relay").
class OutliveTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  RANDOM = SecureRandom.method(:random_bytes)
  LOT = [TestChain.deposit_address(1)].freeze
  TAIL = ["sattleme-checkout relay write", "sattleme-checkout relay release", "sattleme-checkout relay"].freeze

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100, "relays" => @merchant.key_relays), 100)
    @before = gem_threads
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  # The gem's threads alive now (the process's cancellation timer aside).
  def gem_threads
    Thread.list.select do |thread|
      thread.alive? && thread.name.to_s.start_with?("sattleme-checkout") && thread.name != "sattleme-checkout timer"
    end
  end

  # The names of the gem's threads started since the test began, still alive.
  def running = (gem_threads - @before).map(&:name)

  # A WebSocket client whose sockets tell `sent` each message they send, its relay's URL first.
  def recording(websocket, &sent)
    Object.new.tap do |client|
      client.define_singleton_method(:connect) do |url, **options|
        socket = websocket.connect(url, **options)
        Object.new.tap do |recorded|
          recorded.define_singleton_method(:send_text) do |text|
            sent.call(url, text)
            socket.send_text(text)
          end
          recorded.define_singleton_method(:receive) { socket.receive }
          recorded.define_singleton_method(:close) { socket.close }
        end
      end
    end
  end

  test "leaves nothing running once a call failed while a read it no longer needed still ran" do
    @merchant.publish_lot(LOT, 91)
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    @merchant.key_relays.each_with_index do |url, index|
      relay = @merchant.net.get(url)
      # 2 100 records at the address's lease (anybody may write there): its complete read pages 21
      # times, each page 300 ms late. Two of the relays never answer the read of the addresses
      # witnesses name: it fails (fewer than a majority answered) while the other read pages on.
      relay.behaviour = { query_delay_ms: 300 }
      relay.behaviour[:mute_query] = ->(filter) { filter.key?("#o") } if index < 2
      2100.times do |i|
        relay.store({ "id" => format("%064x", i), "pubkey" => "ab" * 32, "created_at" => @merchant.now - i,
                      "kind" => Protocol::RECORD_KIND, "tags" => [["d", d]], "content" => "", "sig" => "00" * 64 })
      end
    end
    returned = Cancellation.new
    mutex = Mutex.new
    late = []
    random = lambda do |length|
      mutex.synchronize { late << :random } if returned.cancelled?
      RANDOM.call(length)
    end
    websocket = recording(@merchant.net.websocket_client) do |url, text|
      mutex.synchronize { late << [url, Json.parse(text)[0]] } if returned.cancelled?
    end
    sattleme = client(websocket_client: websocket, random: random)
    error = assert_raises(NetworkError) { sattleme.create_invoice(ref: "O-1", sats: 49_000) }
    returned.cancel
    assert_match(/Fewer than a majority/, error.message)
    # Its read of the leases was stopped, and waited for: nothing of it runs on, no page more.
    assert_empty running
    sleep 1
    assert_empty late
  end

  test "lets a publication's relays past its majority alone finish after the call returned" do
    # The third relay asks the declaration to authenticate, and never answers the AUTH: its write
    # runs until its timeout, after the call returned (the first two took the declaration).
    third = @merchant.net.get(@merchant.key_relays[2])
    third.behaviour = { require_auth: true, mute_auth: true }
    started = Clock.now
    sattleme = client
    invoice = sattleme.create_invoice(ref: "O-2", sats: 1)
    refute_nil invoice.bolt11
    tail = running
    # Its write, the thread that closes its connection after it, and that connection: the other
    # connections were closed when the call returned.
    assert_equal TAIL.sort, tail.uniq.sort
    assert_equal([1, 1, 1], TAIL.map { |name| tail.count(name) })
    # Within the relay timeout (one second), all over.
    eventually(5) { running.empty? }
    assert_operator Clock.now - started, :<, 5
    # The declaration reached it once: refused until authenticated, and the authentication never
    # answered, it was never written again.
    assert_equal(1, third.received.count { |event| event["kind"] == Protocol::RECORD_KIND })
  end

  # An HTTP client whose request ends a moment after it is told to stop (its cancellation).
  class SlowToStop
    def initialize(inner)
      @inner = inner
    end

    def get(url, headers:, timeout:, cancellation:, &)
      return @inner.get(url, headers: headers, timeout: timeout, cancellation: cancellation, &) unless
        url.include?("/verify/")

      cancellation.wait(5)
      sleep 0.2
      raise IOError, "stopped"
    end
  end

  test "has ended the HTTP request it gave up when it returns: cancelled, it waits for the client to stop" do
    invoice = client.create_invoice(ref: "O-3", sats: 1)
    sattleme = client(http_client: SlowToStop.new(@merchant.http))
    @before = gem_threads
    error = assert_raises(Cancelled) { sattleme.get_status(invoice, cancellation: Cancellation.after(0.2, "enough")) }
    assert_equal "enough", error.reason
    assert_empty running
  end

  # A WebSocket client of the explorer whose socket ends a moment after it is closed.
  class SlowToClose
    def initialize(inner)
      @inner = inner
    end

    def connect(url, **)
      return @inner.connect(url, **) unless url == Protocol::MEMPOOL_WEBSOCKET_URL

      closed = Queue.new
      Object.new.tap do |socket|
        socket.define_singleton_method(:send_text) { |_text| nil }
        socket.define_singleton_method(:receive) do
          closed.pop
          sleep 0.2
          nil
        end
        socket.define_singleton_method(:close) { closed << true }
      end
    end
  end

  test "has closed the explorer's WebSocket, its thread ended, when wait_for_payment returns" do
    @merchant.publish_lot(LOT, 91)
    invoice = client.create_invoice(ref: "O-4", sats: 49_000)
    sattleme = client(websocket_client: SlowToClose.new(@merchant.net.websocket_client))
    eventually { running.empty? }
    @before = gem_threads
    @merchant.pay_invoice(invoice.payment_hash)
    assert_predicate sattleme.wait_for_payment(invoice, interval_ms: 250), :paid?
    assert_empty running
  end
end
