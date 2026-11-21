# frozen_string_literal: true

require "digest"
require_relative "lightning"

# The blockchain for tests: deposit addresses (taproot, bech32m) made from a seed, and fakes of the
# explorer (mempool.space, Esplora REST), of BlockCypher and of the explorer's WebSocket
# (mempool.space's `track-address`). Never the network.
module TestChain
  BECH32M = 0x2bc830a3

  module_function

  # The deposit address (`bc1p…`) of a 32-byte program derived from `seed`.
  def deposit_address(seed)
    program = Digest::SHA256.digest("deposit address #{seed}")
    TestLightning.encode_bech32("bc", [1] + TestLightning.bytes_to_words(program), BECH32M)
  end

  # A txid made from `seed`.
  def txid(seed)
    Digest::SHA256.hexdigest("transaction #{seed}")
  end

  # A transaction paying `address` `sats`, spending `coins` (`<txid>:<vout>`), and some change.
  def payment(id, address, sats, coins: nil, height: nil)
    coins ||= ["#{txid("coin of #{id}")}:0"]
    {
      "txid" => id,
      "vin" => coins.map do |coin|
        spent, vout = coin.split(":")
        { "txid" => spent, "vout" => Integer(vout, 10), "is_coinbase" => false }
      end,
      "vout" => [{ "value" => sats, "scriptpubkey_address" => address },
                 { "value" => 5000, "scriptpubkey_address" => deposit_address("change") }],
      "status" => height.nil? ? { "confirmed" => false } : { "confirmed" => true, "block_height" => height }
    }
  end
end

# The explorers (mempool.space, and the merchant's Bitcoin node when a test names one: the same
# chain at its URL) and BlockCypher, as a test sets them.
class FakeChain
  Protocol = Sattleme::Checkout::Internal::Protocol

  # The chain's height; the URL of the merchant's Bitcoin node (nil: none).
  attr_accessor :height, :node
  # The transactions of each address, in the explorer's order (newest first); when BlockCypher
  # received each transaction it knows; the services that fail (:explorer, mempool.space, and
  # :blockcypher answer HTTP 5xx; :node does not answer, a server outside the merchant's network).
  attr_reader :txs, :received, :down

  def initialize
    @height = 970_000
    @txs = {}
    @received = {}
    @down = []
    @mutex = Mutex.new
    @asked = []
  end

  # What was asked, by URL.
  def asked = @mutex.synchronize { @asked.dup }

  # Adds `tx` to the transactions of `address`, first (the explorer lists the newest first).
  def add(address, tx)
    @txs[address] = [tx] + (@txs[address] || [])
  end

  # Drops `id` from the mempool (replaced, or dropped).
  def drop(address, id)
    @txs[address] = (@txs[address] || []).reject { |tx| tx["txid"] == id }
  end

  # Confirms `id` at `height`.
  def confirm(address, id, height)
    (@txs[address] || []).each do |tx|
      tx["status"] = { "confirmed" => true, "block_height" => height } if tx["txid"] == id
    end
  end

  # The answer to `url`, or nil when it is not an explorer's.
  def route(url)
    href = url.to_s
    if node && href.start_with?("#{node}/api/")
      @mutex.synchronize { @asked << href }
      raise SocketError, "#{node}: no answer" if @down.include?(:node)

      return esplora(href.delete_prefix("#{node}/api"))
    end
    if href.start_with?(Protocol::MEMPOOL_URL)
      @mutex.synchronize { @asked << href }
      return { status: 503, text: "down" } if @down.include?(:explorer)

      return esplora(href.delete_prefix(Protocol::MEMPOOL_URL))
    end
    return nil unless href.start_with?(Protocol::BLOCKCYPHER_URL)

    @mutex.synchronize { @asked << href }
    return { status: 500, json: { "error" => "down" } } if @down.include?(:blockcypher)

    id = url.path.split("/").last
    received = @received[id]
    if received.nil?
      { status: 404, json: { "error" => "Transaction #{id} not found." } }
    else
      { json: { "hash" => id, "received" => received, "confirmations" => 0 } }
    end
  end

  # An Esplora answer to `path` (under the explorer's `/api`).
  def esplora(path)
    return { text: @height.to_s } if path == "/blocks/tip/height"

    address = %r{\A/address/([a-z0-9]+)/txs\z}.match(path)
    return { json: @txs[address[1]] || [] } if address

    { status: 404, text: "Not found" }
  end

  # The URLs of the node asked, and of mempool.space.
  def node_asked = asked.select { |href| node && href.start_with?("#{node}/") }
  def mempool_asked = asked.select { |href| href.start_with?("#{Protocol::MEMPOOL_URL}/") }

  # The URLs of BlockCypher asked.
  def blockcypher_asked
    asked.select { |href| href.start_with?(Protocol::BLOCKCYPHER_URL) }
  end
end

# mempool.space's WebSocket for tests: records what each client sends, and pushes what a test says
# changed.
class FakeExplorerSocket
  Json = Sattleme::Checkout::Internal::Json

  attr_reader :server

  def initialize
    @mutex = Mutex.new
    @messages = []
    @connections = 0
    @server = TestWebSocketServer.new(on_connection: ->(connection) { serve(connection) })
  end

  def messages = @mutex.synchronize { @messages.dup }

  def connections = @mutex.synchronize { @connections }

  def port = @server.port

  def handshakes = @server.handshakes

  # Pushes `message` to every client.
  def push(message)
    @server.connections.reject(&:closed?).each { |connection| connection.send_text(Json.generate(message)) }
  end

  # Drops every client's connection.
  def drop
    @server.drop_all
  end

  def close
    @server.close
  end

  private

  def serve(connection)
    @mutex.synchronize { @connections += 1 }
    thread = Thread.new do
      while (message = connection.read_message)
        @mutex.synchronize { @messages << Json.parse(message[1]) }
      end
    end
    thread.report_on_exception = false
  end
end
