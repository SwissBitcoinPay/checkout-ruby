# frozen_string_literal: true

require_relative "test_helper"

# The merchant's Bitcoin node (SPEC.md §31, "The merchant's Bitcoin node"; §30, "The record")
# against vectors/bitcoin-nodes.json, every group through the gem's own code (PORTING.md step 4):
# `urls` through NodeUrl.parse and where the node is read; `channels` through the reading of the
# channel (Channels.parse), valid either way; `reads` through the explorers a read asks
# (BitcoinNodes.explorers_to_ask), one REST read (CallExplorer#read), the two reads of a check's
# step 1 (Payments.check_onchain) and a WebSocket's connection (Watch); `records` through the
# reading of a record (CheckoutLinks.parse_value); `writes` through the making of a checkout
# link's record (CheckoutLinks.value, from the channel's node as Channels.parse reads it).
class BitcoinNodesVectorsTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTORS = SpecVectors.read("vectors/bitcoin-nodes.json")
  # The node of the `reads` cases: an Umbrel on the merchant's network.
  NODE_URL = "http://192.168.1.10:3006"
  NODE_REST = "#{NODE_URL}/api".freeze
  NODE_WEB_SOCKET = "ws://192.168.1.10:3006/api/v1/ws"
  ADDRESS = TestChain.deposit_address("node vectors")
  # The client's clock in the `reads` cases (Unix seconds).
  NOW = 1_791_381_280

  def self.each_case(group, through = nil, &block)
    VECTORS[group].each_with_index do |item, index|
      label = through ? "#{group} through #{through}" : group
      test("bitcoin-nodes.json #{label} #{index}: #{item["name"]}") { instance_exec(item, &block) }
    end
  end

  # An active channel, valid but for what a case adds (its `bitcoinNode`, when the case has one).
  def channel_value(item)
    value = { "version" => 1, "status" => "active", "role" => "integration",
              "profile" => { "businessName" => "Sunrise Bakery", "lightningAddress" => "a@breez.tips" },
              "registryKey" => "11" * 32,
              "registryReader" => "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
              "updatedAt" => 100 }
    value["bitcoinNode"] = item[key_of(item)] if item.key?(key_of(item))
    value
  end

  def key_of(item) = item.key?("channel") || !item.key?("value") ? "channel" : "value"

  def node_hash(node) = node && { "url" => node.url, "fallback" => node.fallback, "payers" => node.payers }

  # urls

  each_case("urls") do |item|
    node = NodeUrl.parse(item["url"])
    assert_value item["expected"], node && { "rest" => node.rest, "webSocket" => node.web_socket }
    # A record names a node of the Internet alone; the channel any node URL.
    next unless node

    assert_equal(item["url"], BitcoinNodes.of({ "url" => item["url"], "fallback" => "none", "payers" => false }).url)
  end

  # channels

  each_case("channels") do |item|
    channel = Channels.parse(channel_value(item), 100)
    # The channel valid either way.
    refute_nil channel
    assert_value item["expected"], node_hash(channel.bitcoin_node)
    assert_value item["expected"], node_hash(BitcoinNodes.of(item["value"]))
  end

  # reads

  # The CallExplorer of a case: its node, failed 30 s ago when the case says so, at NOW.
  def explorer_of(item)
    failures = NodeFailures.new
    node = item["node"]
    return CallExplorer.new(nil, failures, -> { NOW }) unless node

    failures[NODE_URL] = NOW - 30 if node["failedRecently"]
    CallExplorer.new(BitcoinNodes::Node.new(url: NODE_URL, fallback: node["fallback"], payers: false), failures,
                     -> { NOW })
  end

  def answers?(item, name) = name == "node" ? item["node"]["answers"] : item["mempoolAnswers"]

  def name_of(url) = url.start_with?(NODE_URL) ? "node" : "mempool"

  def http_of(fake) = Http::Context.new(client: fake, timeout_ms: 1000, stop: Stop.new(Cancellation::NONE))

  # The explorers asked, in order (each once), of `urls`.
  def asked_of(urls) = urls.map { |url| name_of(url) }.chunk_while { |a, b| a == b }.map(&:first)

  each_case("reads", "explorers_to_ask") do |item|
    expected = item["expected"]
    node = item["node"]
    failed_recently = node ? node["failedRecently"] : false
    order = BitcoinNodes.explorers_to_ask(node&.fetch("fallback"), failed_recently).map(&:to_s)
    assert_equal(order, explorer_of(item).sources.map { |source| source.name.to_s })
    # Each in turn until one answers: the read gives its answer, or `network` when none does.
    answered = order.index { |name| answers?(item, name) }
    assert_equal expected["asked"], answered ? order.first(answered + 1) : order
    assert_equal expected["result"], answered ? order[answered] : "network"
  end

  each_case("reads", "one REST read") do |item|
    # One REST read (an address's transactions), through the gem's HTTP context.
    fake = FakeHttp.new do |uri|
      raise SocketError, "no answer" unless answers?(item, name_of(uri.to_s))

      { json: [] }
    end
    explorer = explorer_of(item)
    result = begin
      explorer.read(http_of(fake)) do |base, http|
        Explorer.address_transactions(base, ADDRESS, http)
        name_of(base)
      end
    rescue NetworkError
      "network"
    end
    assert_equal item["expected"]["result"], result
    assert_equal(item["expected"]["asked"], fake.calls.map { |call| name_of(call.url) })
    # A node that failed is remembered for the call: with "mempool", its next read asks
    # mempool.space first.
    node = item["node"]
    if node && !node["answers"] && node["fallback"] == "mempool"
      assert_equal %i[mempool node], explorer.sources.map(&:name)
    elsif node
      assert_equal explorer_of(item).sources, explorer.sources
    end
  end

  each_case("reads", "a check's two reads") do |item|
    # The two reads of a check's step 1, one read: the node answering one of them only fails it,
    # both are then asked of mempool.space (never the height of one explorer with the other's
    # transactions).
    # The node shows the payment 3 deep; mempool.space does not show it confirmed yet, but its
    # height is 10 000 blocks later: its height with the node's transactions would read it paid.
    txid = TestChain.txid("node vectors")
    fake = FakeHttp.new do |uri|
      url = uri.to_s
      name = name_of(url)
      height = url.end_with?("/blocks/tip/height")
      # The node, when it does not answer, fails its height alone: its transactions it gives.
      raise SocketError, "no answer" if !answers?(item, name) && (name == "mempool" || height)

      if height
        { text: name == "node" ? "970000" : "980000" }
      else
        { json: [TestChain.payment(txid, ADDRESS, 50_000, height: name == "node" ? 969_998 : nil)] }
      end
    end
    check = Payments::Check.new(
      address: ADDRESS, sats: 50_000, expires_at: NOW + 600, sale: "ab" * 32, clock: -> { NOW }, http: http_of(fake),
      explorer: explorer_of(item), read_witnesses: ->(_every_relay) { Witnesses::NONE },
      witness_address: ->(txid, of) { "#{txid}/#{of}" }, publish: ->(_witness) {}, logger: QUIET,
      paid_by_rests: -> { 0 }, tolerance: -> { 0 }, read_merchant_acceptance: -> { MerchantAcceptances::NONE }
    )
    part = begin
      Payments.check_onchain(check, Stop.new(Cancellation::NONE))
    rescue NetworkError
      nil
    end
    case item["expected"]["result"]
    when "network" then assert_nil part
    # The node's height with the node's transactions: 3 confirmations, paid.
    when "node" then assert_equal %i[paid], [part.kind]
    # mempool.space's height with mempool.space's transactions: not confirmed yet.
    when "mempool" then assert_equal [:unconfirmed, 0], [part.kind, part.confirmations]
    end
    asked = fake.calls.map { |call| name_of(call.url) }.uniq
    assert_equal item["expected"]["asked"], asked
  end

  # A WebSocket that connects to the sockets a test allows, and records each URL asked.
  class SocketsOf
    attr_reader :urls, :connected

    def initialize(answering)
      @answering = answering
      @urls = Queue.new
      @connected = Queue.new
    end

    def connect(url, timeout:, headers:, cancellation:) # rubocop:disable Lint/UnusedMethodArgument
      @urls << url
      raise Errno::ECONNREFUSED, url unless @answering.include?(url)

      socket = Queue.new
      @connected << [url, socket]
      Socket.new(socket)
    end

    # A socket that sends one message, then waits until it is closed.
    class Socket
      def initialize(queue)
        @queue = queue
        @queue << '{"block":{"height":970001}}'
      end

      def send_text(_text) = nil

      def receive = @queue.pop

      def close = @queue.close
    end
  end

  each_case("reads", "the WebSocket") do |item|
    # A WebSocket's connection: the node's (ws://), then mempool.space's when it fails.
    answering = []
    answering << NODE_WEB_SOCKET if item["node"] && item["node"]["answers"]
    answering << Protocol::MEMPOOL_WEBSOCKET_URL if item["mempoolAnswers"]
    sockets = SocketsOf.new(answering)
    waits = Queue.new
    explorer = explorer_of(item)
    watch = Watch.new(sockets, explorer, ADDRESS, 2, wait: lambda { |seconds|
      waits << seconds
      true
    }) { nil }
    begin
      result = case item["expected"]["result"]
               when "network"
                 # Every one failed: the next connection waits, as after a lost one.
                 waits.pop(timeout: 10) || flunk("No wait")
                 "network"
               else
                 url, = sockets.connected.pop(timeout: 10) || flunk("No connection")
                 url == NODE_WEB_SOCKET ? "node" : "mempool"
               end
      assert_equal item["expected"]["result"], result
      asked = Array.new(sockets.urls.size) { sockets.urls.pop }
      assert_equal(item["expected"]["asked"], asked.map { |url| url == NODE_WEB_SOCKET ? "node" : "mempool" })
      # The node's WebSocket failing is a failure of the node for the call: with "mempool", its next
      # read asks mempool.space first (the reads and the WebSocket share it).
      node = item["node"]
      if node && !node["answers"] && node["fallback"] == "mempool"
        assert_equal %i[mempool node], explorer.sources.map(&:name)
      end
    ensure
      watch.close
    end
  end

  # records

  each_case("records") do |item|
    record = CheckoutLinks.parse_value(item["value"])
    # Valid in every case: a `bitcoinNode` set aside leaves the record valid.
    refute_nil record
    assert_value item["expected"], record.bitcoin_node&.to_h
  end

  # writes

  each_case("writes") do |item|
    # The channel's `bitcoinNode` as createInvoice read it.
    node = Channels.parse(channel_value(item), 100).bitcoin_node
    onchain = if item["address"]
                CheckoutLinks::Onchain.new(address: ADDRESS, sats: 150_000, created_at: NOW, expires_at: NOW + 900,
                                           rest: nil, bitcoin_node: BitcoinNodes.record_node_for(node))
              end
    value = CheckoutLinks.value(business_name: "Sunrise Bakery", invoice: nil, verify_url: nil, fiat: nil,
                                note: "Order 1042", redirect_url: nil, onchain: onchain)
    assert_equal item["address"] ? 2 : 1, value["version"]
    if item["expected"].nil?
      # Absent, never null.
      refute value.key?("bitcoinNode")
    else
      assert_equal item["expected"], value["bitcoinNode"]
      # Never `payers`.
      refute value["bitcoinNode"].key?("payers")
    end
    # The page reads what was written.
    assert_value item["expected"], CheckoutLinks.parse_value(value)&.bitcoin_node&.to_h
  end
end
