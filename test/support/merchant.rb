# frozen_string_literal: true

require "uri"
require_relative "relay"
require_relative "fake_http"
require_relative "lightning"
require_relative "chain"

# A merchant for tests, as the app would set it up: a team, an integration's key, the channel the
# team publishes on local relays, the registry, and a Lightning address (breez.tips) answered by a
# fake HTTP client that makes real-looking invoices.
class TestMerchant
  include Sattleme::Checkout::Internal

  LIGHTNING_ADDRESS = "sattleme02c6047f94@breez.tips"
  METADATA = Json.generate([["text/identifier", LIGHTNING_ADDRESS], ["text/plain", "Pay to Sunrise Bakery"]])
  PAY_URL = "https://breez.tips/.well-known/lnurlp/sattleme02c6047f94"
  CALLBACK = "https://breez.tips/lnurlp/sattleme02c6047f94/invoice"

  # An invoice the fake breez.tips made, with what pays it.
  Made = Data.define(:pr, :verify, :payment_hash, :preimage, :amount_msat, :expiry, :comment)

  # Fixed bytes: tests are reproducible.
  def self.bytes(seed, length = 32)
    [seed].pack("C") * length
  end

  # The text of an integration key, as the merchant's app writes it.
  def self.format_key(team, key, relays)
    hosts = relays.map { |relay| relay.delete_prefix("wss://") }.join(",")
    Protocol::INTEGRATION_KEY_PREFIX +
      [Base64.encode_url(Text.hex_bytes(team)), Base64.encode_url(key), Base64.encode_url(hosts.b)].join(".")
  end

  attr_reader :net, :team_secret, :team, :integration_key, :registry_key, :reader_secret, :reader, :invoices, :paid,
              :chain, :http
  attr_accessor :key_relays, :now, :pay, :tamper, :override

  def initialize
    @net = RelayNet.new
    @team_secret = TestMerchant.bytes(1)
    @team = Events.public_key(@team_secret)
    @integration_key = TestMerchant.bytes(2)
    @registry_key = TestMerchant.bytes(3)
    @reader_secret = TestMerchant.bytes(4)
    @reader = Events.public_key(@reader_secret)
    @key_relays = ["wss://relay-a.test", "wss://relay-b.test", "wss://relay-c.test"]
    # Unix seconds.
    @now = 1_791_378_000
    # The invoices breez.tips made, by payment hash; the payment hashes paid.
    @invoices = {}
    @paid = {}
    # What breez.tips's pay request says.
    @pay = { "tag" => "payRequest", "callback" => CALLBACK, "minSendable" => 1000, "maxSendable" => 100_000_000_000,
             "metadata" => METADATA, "commentAllowed" => 255 }
    # Changes the invoice breez.tips gives (a test of a check): Made → Hash of changes.
    @tamper = nil
    # The explorers and BlockCypher.
    @chain = FakeChain.new
    # Overrides the answer of a URL.
    @override = nil
    @seed = 10
    @mutex = Mutex.new
    @http = FakeHttp.new { |url| route(url) }
  end

  def key
    TestMerchant.format_key(team, integration_key, key_relays)
  end

  # Starts the key's relays (and `others`).
  def start(others = [], behaviours = {})
    (key_relays + others).uniq.each { |url| net.add(url, behaviours[url] || {}) }
    self
  end

  def stop
    net.close
  end

  # The channel's value, active, as the merchant's app writes it.
  def channel_value(created_at, extra = {})
    {
      "version" => 1, "status" => "active", "name" => "Shopify store", "role" => "integration",
      "profile" => { "businessName" => "Sunrise Bakery", "lightningAddress" => LIGHTNING_ADDRESS, "currency" => "CHF",
                     "onchain" => true, "logo" => nil },
      "registryKey" => Text.hex(registry_key), "registryReader" => reader, "linkOwner" => "ab" * 32,
      "updatedAt" => created_at
    }.merge(extra)
  end

  # The channel's event, signed by `signer` (the team by default).
  def channel_event(value, created_at, signer = team_secret)
    address, encryption_key = Derive.channel_keys(integration_key)
    Records.seal(type: "team-channel", value: value, signer: signer, encryption_key: encryption_key, address: address,
                 created_at: created_at, random: SecureRandom.method(:random_bytes))
  end

  # Publishes the channel on `relays` (the key's by default).
  def publish_channel(value, created_at, relays = key_relays, signer = team_secret)
    event = channel_event(value, created_at, signer)
    relays.each { |relay| net.get(relay).store(event) }
    event
  end

  # Publishes the integration's lot of deposit addresses on `relays`, as the merchant's app does.
  def publish_lot(addresses, created_at, relays = key_relays)
    event = Records.seal(type: "integration-onchain-lot",
                         value: { "version" => 1, "addresses" => addresses, "updatedAt" => created_at },
                         signer: team_secret, encryption_key: Derive.channel_keys(integration_key)[1],
                         address: Derive.lot_address(integration_key), created_at: created_at,
                         random: SecureRandom.method(:random_bytes))
    relays.each { |relay| net.get(relay).store(event) }
    event
  end

  # Starts the explorer's WebSocket (wss://mempool.space/api/v1/ws, or the node's at `url`).
  def start_explorer_socket(url = Protocol::MEMPOOL_WEBSOCKET_URL)
    socket = FakeExplorerSocket.new
    net.add_server(url, socket)
    socket
  end

  # Marks an invoice paid on breez.tips.
  def pay_invoice(payment_hash)
    @mutex.synchronize { @paid[payment_hash] = true }
  end

  def made_invoices = @mutex.synchronize { @invoices.values }

  private

  def route(url)
    overridden = override&.call(url)
    return overridden if overridden

    onchain = chain.route(url)
    return onchain if onchain

    href = url.to_s
    return FakeHttp.answer(pay) if href == PAY_URL
    return invoice_answer(url) if "#{url.scheme}://#{url.host}#{url.path}" == CALLBACK
    return verify_answer(url) if href.start_with?("https://breez.tips/lnurlp/verify/")

    raise SocketError, "no route to #{href}"
  end

  def invoice_answer(url)
    query = URI.decode_www_form(url.query || "").to_h
    amount = Integer(query.fetch("amount"), 10)
    expiry = Integer(query.fetch("expiry", "3600"), 10)
    preimage, payment_hash = @mutex.synchronize do
      @seed += 1
      TestLightning.preimage_pair(@seed - 1)
    end
    made = Made.new(pr: TestLightning.make_invoice(amount_msat: amount, payment_hash: payment_hash,
                                                   description_hash: TestLightning.metadata_hash(METADATA),
                                                   timestamp: now, expiry_seconds: expiry),
                    verify: "https://breez.tips/lnurlp/verify/#{payment_hash}", payment_hash: payment_hash,
                    preimage: preimage, amount_msat: amount, expiry: expiry, comment: query["comment"])
    made = made.with(**tamper.call(made)) if tamper
    @mutex.synchronize { @invoices[made.payment_hash] = made }
    FakeHttp.answer({ "pr" => made.pr, "verify" => made.verify, "routes" => [] })
  end

  def verify_answer(url)
    hash = url.path.split("/").last
    made, settled = @mutex.synchronize { [@invoices[hash], @paid.key?(hash)] }
    return FakeHttp.answer({ "status" => "ERROR", "reason" => "Not found" }) unless made

    FakeHttp.answer({ "status" => "OK", "settled" => settled, "preimage" => settled ? made.preimage : nil,
                      "pr" => made.pr })
  end
end

# What the merchant's app opens.
module Owner
  include Sattleme::Checkout::Internal

  module_function

  # A declaration, opened as the merchant's app does: with the registry key and the reading key.
  def open_declaration(event, registry_key, reader_secret)
    fields = Events.fields(event)
    address = fields["tags"].find { |tag| tag[0] == "d" }[1]
    outside = Json.parse(Nip44.decrypt(fields["content"], Derive.outer_key(registry_key, address, fields["pubkey"])))
    raise "Not a declaration" unless outside["t"] == "registry-declaration"

    Json.parse(Nip44.decrypt(outside["v"]["sealed"], Nip44.conversation_key(reader_secret, fields["pubkey"])))
  end
end
