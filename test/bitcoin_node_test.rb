# frozen_string_literal: true

require_relative "test_helper"

# The merchant's Bitcoin node (SPEC.md §31, "The merchant's Bitcoin node"), end to end against
# local relays and fakes of breez.tips, of mempool.space and of a node on the merchant's network
# (REST and WebSocket), as PORTING.md step 5 lists: every read of an address and of the chain's
# height, and wait_for_payment's WebSocket, asked of the node and never of mempool.space while it
# answers; its `fallback` when it does not; the 60 s after a failure; a check's two reads of one
# explorer; an invalid `bitcoinNode` read as none; the node in a checkout link's record.
class BitcoinNodeTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"
  NODE = "http://192.168.1.10:3006"
  NODE_WS = "ws://192.168.1.10:3006/api/v1/ws"
  INTERNET_NODE = "https://mempool.shop.example"
  ADDRESS = TestChain.deposit_address(1)
  ABSENT = Object.new.freeze

  # A WebSocket client that records each URL it is asked to connect to.
  class RecordingWebSocket
    def initialize(inner)
      @inner = inner
      @mutex = Mutex.new
      @urls = []
    end

    def urls = @mutex.synchronize { @urls.dup }

    def connect(url, **)
      @mutex.synchronize { @urls << url }
      @inner.connect(url, **)
    end
  end

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_lot([ADDRESS], 90)
    @websocket = RecordingWebSocket.new(@merchant.net.websocket_client)
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @websocket,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  # Publishes the channel naming `bitcoin_node` (ABSENT: without the field), served by the fake.
  def publish_channel(bitcoin_node, created_at = 100)
    extra = { "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN } }
    extra["bitcoinNode"] = bitcoin_node unless bitcoin_node.equal?(ABSENT)
    @merchant.publish_channel(@merchant.channel_value(created_at, extra), created_at)
    url = bitcoin_node.is_a?(Hash) ? bitcoin_node["url"] : nil
    @merchant.chain.node = url.is_a?(String) ? url : nil
  end

  # Above the Lightning address's bounds: an order paid on-chain only.
  def onchain_only
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
  end

  def node(fallback, payers: false) = { "url" => NODE, "fallback" => fallback, "payers" => payers }

  # What a link's record holds, as its page opens it.
  def record_of(url)
    fragment = CheckoutLinks.parse_fragment(url[url.index("#")..])
    keys = CheckoutLinks.keys(fragment.link_key)
    event = eventually do
      @merchant.net.get(@merchant.key_relays[0]).events.find do |value|
        value["tags"].any? { |name, d| name == "d" && d == keys.address }
      end
    end
    Json.parse(Nip44.decrypt(event["content"], keys.encryption_key))["v"]
  end

  # wait_for_payment in a thread: [its thread, the statuses it gave, its cancellation].
  def waiting(sattleme, invoice, interval_ms: 60_000)
    statuses = Queue.new
    cancellation = Cancellation.new
    thread = Thread.new do
      sattleme.wait_for_payment(invoice, interval_ms: interval_ms, cancellation: cancellation) { |s| statuses << s }
    rescue Cancelled
      nil
    end
    thread.report_on_exception = false
    [thread, statuses, cancellation]
  end

  # The explorers asked since `mark` (the length of the chain's `asked` then), each run of one
  # explorer once: "node" or "mempool".
  def explorers_since(mark)
    @merchant.chain.asked.drop(mark).map { |url| url.start_with?(NODE) ? "node" : "mempool" }
             .chunk_while { |a, b| a == b }.map(&:first)
  end

  # a node that answers

  test "a node that answers: is the only explorer asked: the lease, every check, paid at 3 confirmations" do
    publish_channel(node("mempool"))
    sattleme = client
    invoice = sattleme.create_invoice(ref: "N-1", sats: 49_000)
    assert_equal ADDRESS, invoice.onchain_address
    # The lease: whether the address was paid already, of the node.
    assert_equal ["#{NODE}/api/address/#{ADDRESS}/txs"], @merchant.chain.node_asked
    tx = TestChain.payment(TestChain.txid("node"), ADDRESS, 49_000)
    @merchant.chain.add(ADDRESS, tx)
    assert_equal "unconfirmed", sattleme.get_status(invoice).state
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "49000", "txids" => [tx["txid"]] },
                 sattleme.get_status(invoice).to_h)
    assert_empty @merchant.chain.mempool_asked
    heights = @merchant.chain.node_asked.select { |url| url.end_with?("/blocks/tip/height") }
    assert_equal ["#{NODE}/api/blocks/tip/height"] * 2, heights
    # Over http, with the User-Agent of every request (SPEC.md §15).
    calls = @merchant.http.calls.select { |call| call.url.start_with?("#{NODE}/") }
    refute_empty calls
    calls.each { |call| assert_equal "sattleme-Checkout/1", call.headers["User-Agent"] }
  end

  test "a node that answers: follows no redirect of the node: a failure, mempool.space then asked" do
    publish_channel(node("mempool"))
    invoice = client.create_invoice(ref: "N-2", sats: 49_000)
    @merchant.override = lambda do |url|
      { status: 302, text: "" } if url.to_s.start_with?("#{NODE}/")
    end
    assert_equal "open", client.get_status(invoice).state
    assert_equal 2, @merchant.chain.mempool_asked.size
  end

  test "a node that answers: is watched by wait_for_payment on the node's WebSocket, never mempool.space's" do
    publish_channel(node("mempool"))
    node_socket = @merchant.start_explorer_socket(NODE_WS)
    mempool = @merchant.start_explorer_socket
    sattleme = client
    invoice = sattleme.create_invoice(ref: "N-3", sats: 49_000)
    thread, statuses, = waiting(sattleme, invoice)
    eventually { node_socket.messages.size == 2 && !statuses.empty? }
    assert_equal [{ "action" => "want", "data" => ["blocks"] }, { "track-address" => ADDRESS }], node_socket.messages
    tx = TestChain.payment(TestChain.txid("watched"), ADDRESS, 49_000, height: @merchant.chain.height - 2)
    @merchant.chain.add(ADDRESS, tx)
    node_socket.push({ "address-transactions" => [tx] })
    status = thread.value
    assert_equal %w[paid onchain], [status.state, status.payment_method]
    assert_equal 0, mempool.connections
    assert_equal [NODE_WS], @websocket.urls.reject { |url| @merchant.key_relays.include?(url) }.uniq
    assert_empty @merchant.chain.mempool_asked
  end

  # a node that does not answer, fallback mempool

  test "fallback mempool: reads mempool.space instead, and network when both fail" do
    publish_channel(node("mempool"))
    # A server outside the merchant's network: no answer.
    @merchant.chain.down << :node
    sattleme = client
    invoice = sattleme.create_invoice(ref: "F-1", sats: 49_000)
    assert_equal ADDRESS, invoice.onchain_address
    tx = TestChain.payment(TestChain.txid("fallback"), ADDRESS, 49_000, height: @merchant.chain.height - 2)
    @merchant.chain.add(ADDRESS, tx)
    status = sattleme.get_status(invoice)
    assert_equal %w[paid onchain], [status.state, status.payment_method]
    @merchant.chain.down << :explorer
    error = assert_raises(NetworkError) { sattleme.get_status(invoice) }
    assert_match(/Neither the merchant's Bitcoin node nor mempool.space answered/, error.message)
  end

  test "fallback mempool: asks the node after mempool.space for 60 s once it failed, in the same call" do
    publish_channel(node("mempool"))
    @merchant.chain.down << :node
    # Two addresses: the first paid already (skipped), the second leased. The node fails the
    # first's read: the second's is asked of mempool.space first.
    second = TestChain.deposit_address(2)
    @merchant.publish_lot([ADDRESS, second], 91)
    @merchant.chain.add(ADDRESS, TestChain.payment(TestChain.txid("earlier"), ADDRESS, 1000, height: 1))
    # The shuffle's draws (4 bytes) keep the lot's order: the paid one first.
    random = ->(length) { length == 4 ? "\xFF\xFF\xFF\xFF".b : SecureRandom.random_bytes(length) }
    invoice = client(random: random).create_invoice(ref: "F-2", sats: 49_000)
    assert_equal second, invoice.onchain_address
    assert_equal(["node #{ADDRESS}/txs", "mempool #{ADDRESS}/txs", "mempool #{second}/txs"],
                 @merchant.chain.asked.map do |url|
                   "#{url.start_with?(NODE) ? "node" : "mempool"} #{url.split("/address/")[1]}"
                 end)
  end

  test "fallback mempool: asks the node after mempool.space within 60 s, in every check of one wait_for_payment" do
    publish_channel(node("mempool"))
    sattleme = client
    invoice = sattleme.create_invoice(ref: "F-3", sats: 49_000)
    @merchant.chain.down << :node
    mempool = @merchant.start_explorer_socket
    mark = @merchant.chain.asked.size
    thread, statuses, cancellation = waiting(sattleme, invoice)
    # The first check: the node, then mempool.space; its WebSocket: the node's refused,
    # mempool.space's connected, which starts a check, of mempool.space first.
    eventually { statuses.size == 2 }
    assert_equal %w[node mempool], explorers_since(mark)
    eventually { mempool.messages.size == 2 }
    assert_equal 1, @websocket.urls.count(NODE_WS)
    2.times { statuses.pop }
    # mempool.space failing within the 60 s: the node after it, which answers.
    mark = @merchant.chain.asked.size
    @merchant.chain.down << :explorer
    @merchant.chain.down.delete(:node)
    mempool.push({ "block" => { "height" => @merchant.chain.height } })
    eventually { statuses.size == 1 }
    assert_equal %w[mempool node], explorers_since(mark)
    assert_equal "open", statuses.pop.state
    # 60 s after its failure: the node first again.
    mark = @merchant.chain.asked.size
    @merchant.now += 60
    @merchant.chain.down.delete(:explorer)
    mempool.push({ "block" => { "height" => @merchant.chain.height } })
    eventually { statuses.size == 1 }
    assert_equal %w[node], explorers_since(mark)
    cancellation.cancel
    thread.join
  end

  # a node that does not answer, fallback none

  test "fallback none: leases no address: network for an order paid on-chain only, Lightning only otherwise" do
    publish_channel(node("none"))
    @merchant.chain.down << :node
    onchain_only
    assert_raises(NetworkError) { client.create_invoice(ref: "X-1", sats: 2_000_000) }
    @merchant.pay = @merchant.pay.merge("maxSendable" => 100_000_000_000)
    invoice = client.create_invoice(ref: "X-2", sats: 49_000)
    assert_nil invoice.onchain_address
    assert_match(/\Alnbc/, invoice.bolt11)
    assert_empty @merchant.chain.mempool_asked
  end

  test "fallback none: is network, never expired however long the node is down, then paid once it answers" do
    publish_channel(node("none"))
    onchain_only
    sattleme = client
    invoice = sattleme.create_invoice(ref: "X-3", sats: 2_000_000)
    assert_equal ADDRESS, invoice.onchain_address
    @merchant.chain.down << :node
    # Paid while the lease ran, which no check saw: BlockCypher tells it in time.
    tx = TestChain.payment(TestChain.txid("unseen"), ADDRESS, 2_000_000, height: @merchant.chain.height - 5)
    @merchant.chain.add(ADDRESS, tx)
    @merchant.chain.received[tx["txid"]] = Time.at(invoice.created_at + 60).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    [3600, 86_400 * 30].each do |late|
      @merchant.now = invoice.expires_at + late
      assert_raises(NetworkError) { sattleme.get_status(invoice) }
      # A new invoice of the order: refused while its earlier one cannot be told.
      assert_raises(NetworkError) { sattleme.create_invoice(ref: "X-3", sats: 2_000_000) }
    end
    assert_empty @merchant.chain.mempool_asked
    @merchant.chain.down.delete(:node)
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "2000000", "txids" => [tx["txid"]] },
                 sattleme.get_status(invoice).to_h)
  end

  test "fallback none: wait_for_payment goes on with network, never expired, while the node is down" do
    publish_channel(node("none"))
    onchain_only
    sattleme = client
    invoice = sattleme.create_invoice(ref: "X-5", sats: 2_000_000)
    @merchant.chain.down << :node
    @merchant.now = invoice.expires_at + 3600
    logger = TestLogger.new
    cancellation = Cancellation.new
    statuses = Queue.new
    thread = Thread.new do
      client(logger: logger).wait_for_payment(invoice, interval_ms: 250, cancellation: cancellation) do |status|
        statuses << status
      end
    rescue Cancelled
      :cancelled
    end
    thread.report_on_exception = false
    # Each check fails (logged once); none gives a status, the wait goes on.
    eventually { logger.messages.any? { |message| message.include?("the payment check failed") } }
    eventually { @websocket.urls.count(NODE_WS) >= 2 }
    assert_empty statuses
    cancellation.cancel
    assert_equal :cancelled, thread.value
    assert_empty @merchant.chain.mempool_asked
  end

  test "fallback none: is watched on the node's WebSocket alone, connected again while it is down" do
    publish_channel(node("none"))
    mempool = @merchant.start_explorer_socket
    sattleme = client
    invoice = sattleme.create_invoice(ref: "X-4", sats: 49_000)
    @merchant.chain.down << :node
    thread, _statuses, cancellation = waiting(sattleme, invoice, interval_ms: 250)
    # No node's WebSocket listens: refused, tried again after 1 s.
    eventually { @websocket.urls.count(NODE_WS) >= 2 }
    cancellation.cancel
    thread.join
    assert_equal 0, mempool.connections
    refute_includes @websocket.urls, Protocol::MEMPOOL_WEBSOCKET_URL
    assert_empty @merchant.chain.mempool_asked
  end

  # wait_for_payment's WebSocket, fallback mempool

  test "wait_for_payment's WebSocket, fallback mempool: goes to mempool.space's when the node's fails, and is woken by it" do
    publish_channel(node("mempool"))
    mempool = @merchant.start_explorer_socket
    sattleme = client
    invoice = sattleme.create_invoice(ref: "W-1", sats: 49_000)
    thread, statuses, = waiting(sattleme, invoice)
    # The node's WebSocket refuses the connection: mempool.space's at once.
    eventually { mempool.messages.size == 2 && !statuses.empty? }
    assert_equal 1, @websocket.urls.count(NODE_WS)
    tx = TestChain.payment(TestChain.txid("socket"), ADDRESS, 49_000, height: @merchant.chain.height - 2)
    @merchant.chain.add(ADDRESS, tx)
    mempool.push({ "address-transactions" => [tx] })
    status = thread.value
    assert_equal %w[paid onchain], [status.state, status.payment_method]
  end

  # one explorer for a check's two reads

  test "one explorer for a check's two reads: asks both of mempool.space when the node fails either" do
    publish_channel(node("mempool"))
    sattleme = client
    invoice = sattleme.create_invoice(ref: "O-1", sats: 49_000)
    # The node gives the address's transactions, and fails the chain's height.
    tx = TestChain.payment(TestChain.txid("one"), ADDRESS, 49_000, height: @merchant.chain.height - 2)
    @merchant.chain.add(ADDRESS, tx)
    @merchant.override = lambda do |url|
      { status: 500, text: "down" } if url.to_s == "#{NODE}/api/blocks/tip/height"
    end
    assert_equal "paid", sattleme.get_status(invoice).state
    assert_equal ["#{Protocol::MEMPOOL_URL}/address/#{ADDRESS}/txs", "#{Protocol::MEMPOOL_URL}/blocks/tip/height"],
                 @merchant.chain.mempool_asked.sort
  end

  # an invalid bitcoinNode

  [["http to a public host", { "url" => "http://node.example", "fallback" => "mempool", "payers" => false }],
   ["a fallback of another spelling", { "url" => NODE, "fallback" => "Mempool", "payers" => false }],
   ["payers absent", { "url" => NODE, "fallback" => "none" }],
   ["payers not a boolean", { "url" => INTERNET_NODE, "fallback" => "none", "payers" => "true" }],
   ["payers true for a local node", { "url" => NODE, "fallback" => "none", "payers" => true }]].each do |name, value|
    test "an invalid bitcoinNode: reads mempool.space, the channel still valid: #{name}" do
      publish_channel(value)
      invoice = client.create_invoice(ref: "I-1", sats: 49_000, checkout: true)
      assert_equal ADDRESS, invoice.onchain_address
      assert_empty @merchant.chain.node_asked
      assert_equal ["#{Protocol::MEMPOOL_URL}/address/#{ADDRESS}/txs"], @merchant.chain.mempool_asked
      refute record_of(invoice.checkout_url).key?("bitcoinNode")
      # Nothing asked of the node's host, http or not.
      assert(@merchant.http.calls.none? { |call| call.url.start_with?("http://") })
    end
  end

  # the record of a checkout link

  test "the record of a checkout link: holds the node's url and fallback, never payers, with payers true" do
    publish_channel({ "url" => INTERNET_NODE, "fallback" => "none", "payers" => true, "name" => "Shop node" })
    invoice = client.create_invoice(ref: "L-1", sats: 49_000, checkout: true)
    record = record_of(invoice.checkout_url)
    assert_equal [2, ADDRESS], record.values_at("version", "onchainAddress")
    assert_equal({ "url" => INTERNET_NODE, "fallback" => "none" }, record["bitcoinNode"])
    assert_equal({ "url" => INTERNET_NODE, "fallback" => "none" }, CheckoutLinks.parse_value(record).bitcoin_node.to_h)
    # The link made again for InvoicePendingError holds it too.
    pending = assert_raises(InvoicePendingError) { client.create_invoice(ref: "L-1", sats: 49_000, checkout: true) }
    refute_equal invoice.checkout_url, pending.checkout_url
    assert_equal({ "url" => INTERNET_NODE, "fallback" => "none" }, record_of(pending.checkout_url)["bitcoinNode"])
  end

  [["payers false", { "url" => INTERNET_NODE, "fallback" => "mempool", "payers" => false }],
   ["no node", ABSENT]].each do |name, value|
    test "the record of a checkout link: holds no node with #{name}" do
      publish_channel(value)
      invoice = client.create_invoice(ref: "L-2", sats: 49_000, checkout: true)
      record = record_of(invoice.checkout_url)
      assert_equal 2, record["version"]
      refute record.key?("bitcoinNode")
    end
  end

  test "the record of a checkout link: holds no node in version 1, an order without an address" do
    publish_channel({ "url" => INTERNET_NODE, "fallback" => "mempool", "payers" => true })
    # Below the on-chain floor: Lightning only.
    invoice = client.create_invoice(ref: "L-3", sats: 999, checkout: true)
    assert_nil invoice.onchain_address
    record = record_of(invoice.checkout_url)
    assert_equal 1, record["version"]
    refute record.key?("bitcoinNode")
  end
end
