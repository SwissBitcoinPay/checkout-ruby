# frozen_string_literal: true

require_relative "test_helper"

# On-chain payments (SPEC.md §31), end to end against local relays and fakes of breez.tips, of the
# explorers (REST and WebSocket) and of BlockCypher: the methods of an order by its amount, a lot
# read and an address leased, two servers leasing one address, a paid address skipped, the
# witnesses written and read, the statuses of both parts, an order paid on-chain found again,
# wait_for_payment woken by the explorer's WebSocket.
class OnchainTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"
  LOT = [TestChain.deposit_address(1), TestChain.deposit_address(2), TestChain.deposit_address(3)].freeze

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(
      @merchant.channel_value(100, "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN }), 100
    )
    @merchant.publish_lot(LOT, 90)
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  def first_relay = @merchant.net.get(@merchant.key_relays[0])

  # The records the first relay holds now.
  def held = first_relay.events

  # The leases and withdrawals of `address` the first relay received: [kind, event], opened by the
  # merchant.
  def leases_of(address)
    d = Addresses.lease_address(@merchant.registry_key, address)
    first_relay.received.filter_map do |event|
      record = Leases.open_record(event, @merchant.registry_key, d)
      record && [record.hold.is_a?(Integer) ? "lease" : record.hold.to_s, event]
    end
  end

  # The inside of a lease, as the merchant's app opens it (registry key and reading key).
  def open_as_merchant(event)
    d = event["tags"].find { |tag| tag[0] == "d" }[1]
    outside = Json.parse(Nip44.decrypt(event["content"], Derive.outer_key(@merchant.registry_key, d, event["pubkey"])))
    assert_equal "registry-onchain", outside["t"]
    { "end" => outside["v"]["end"] }.merge(
      Json.parse(Nip44.decrypt(outside["v"]["sealed"],
                               Nip44.conversation_key(@merchant.reader_secret, event["pubkey"])))
    )
  end

  # The witnesses the first relay holds, as the merchant's app reads them (by the seen author).
  def witnesses
    seen = Derive.seen_keys(@merchant.integration_key)
    held.filter_map do |event|
      opened = Witnesses.open(event, seen)
      opened.witness.to_h.merge(seen_at: event["created_at"]) if opened&.status == :ok
    end
  end

  # The sale of `ref`, in the merchant's registry.
  def sale_of_ref(ref)
    Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader), ref)
  end

  # The methods of an order by its amount

  test "leases an address from 1 000 sats, before the invoice is declared" do
    invoice = client.create_invoice(ref: "ORD-1", sats: 49_000, note: "Order 1")
    assert_includes LOT, invoice.onchain_address
    address = invoice.onchain_address
    assert_match(/\Alnbc/, invoice.bolt11)
    assert_equal "bitcoin:#{address}?amount=0.00049&lightning=#{invoice.bolt11}", invoice.payment_uri
    # The explorer was asked whether the address was paid already.
    assert_includes @merchant.chain.asked, "#{Protocol::MEMPOOL_URL}/address/#{address}/txs"
    # The lease first, then its mark once confirmed, then the declaration: an address is never
    # shown before its lease is confirmed.
    sale_key, _, sale_author = Derive.sale_keys(@merchant.integration_key, "ORD-1")
    received = eventually { first_relay.received.then { |events| events.size == 3 && events } }
    d = Addresses.lease_address(@merchant.registry_key, address)
    assert_equal(0, received.index { |event| event["tags"].any? { |tag| tag[1] == d } })
    assert(received.all? { |event| event["pubkey"] == sale_author })
    assert_operator received[1]["created_at"], :>, received[0]["created_at"]
    refute open_as_merchant(received[0])["confirmed"]
    assert_equal({ "end" => invoice.expires_at + 120, "version" => 1, "address" => address, "sats" => 49_000,
                   "invoice" => invoice.bolt11, "verifyUrl" => invoice.verify_url, "createdAt" => invoice.created_at,
                   "expiresAt" => invoice.expires_at,
                   "sale" => { "key" => to_hex(sale_key),
                               "fiat" => { "minor" => 49_000, "digits" => 0, "currency" => "SAT" },
                               "note" => "Order 1" },
                   "taker" => sale_of_ref("ORD-1").taker, "confirmed" => true }, open_as_merchant(received[1]))
  end

  test "is Lightning only below 1 000 sats: the lot is not even read" do
    invoice = client.create_invoice(ref: "ORD-2", sats: 999)
    assert_equal [nil, "lightning:#{invoice.bolt11}"], [invoice.onchain_address, invoice.payment_uri]
    assert_empty @merchant.chain.asked
  end

  test "is on-chain only above the Lightning address's maximum" do
    @merchant.pay = @merchant.pay.merge("maxSendable" => 4_000_000_000)
    invoice = client.create_invoice(ref: "ORD-3", sats: "150000000", duration_seconds: 600)
    assert_equal [nil, nil, nil, "150000000", @merchant.now, @merchant.now + 600],
                 [invoice.bolt11, invoice.payment_hash, invoice.verify_url, invoice.sats, invoice.created_at,
                  invoice.expires_at]
    assert_equal "bitcoin:#{invoice.onchain_address}?amount=1.5", invoice.payment_uri
    # No invoice asked, nothing declared: the lease alone, then its mark.
    assert_empty @merchant.invoices
    received = eventually { first_relay.received.then { |events| events.size == 2 && events } }
    assert_equal [true, nil, nil, @merchant.now, @merchant.now + 600, @merchant.now + 720],
                 open_as_merchant(received[1]).values_at("confirmed", "invoice", "verifyUrl", "createdAt", "expiresAt",
                                                         "end")
    assert_equal({ "state" => "open", "expiresAt" => invoice.expires_at, "received" => "0", "rest" => nil },
                 client.get_status(invoice).to_h)
  end

  test "is Lightning only without a lot, and fails on-chain only" do
    @merchant.key_relays.each { |relay| @merchant.net.get(relay).clear }
    @merchant.publish_channel(@merchant.channel_value(100, "relays" => @merchant.key_relays), 100)
    sattleme = client
    assert_equal 0, sattleme.merchant.onchain_addresses
    assert_nil sattleme.create_invoice(ref: "ORD-4", sats: 49_000).onchain_address
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    assert_raises(OnchainUnavailableError) { sattleme.create_invoice(ref: "ORD-5", sats: 49_000) }
    # Nothing published for that order.
    assert_equal 1, @merchant.invoices.size
  end

  test "is Lightning only when the explorer does not answer, and NetworkError on-chain only" do
    @merchant.chain.down << :explorer
    sattleme = client
    assert_nil sattleme.create_invoice(ref: "ORD-6", sats: 49_000).onchain_address
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "ORD-7", sats: 49_000) }
  end

  test "logs the explorer's failure that leaves an order Lightning only" do
    @merchant.chain.down << :explorer
    logger = TestLogger.new
    client(logger: logger).create_invoice(ref: "ORD-9", sats: 49_000)
    assert_equal 1, logger.messages.size
    assert_match(/no deposit address leased, the explorer did not answer/, logger.messages[0])
  end

  test "refuses more than 21 million bitcoins" do
    assert_raises(InvalidOrderError) { client.create_invoice(ref: "ORD-8", sats: "2100000000000001") }
  end

  test "counts the lot's addresses in merchant()" do
    assert_equal 3, client.merchant.onchain_addresses
  end

  # Leasing an address

  test "never leases an address another order holds, until its lease ended" do
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client
    first = sattleme.create_invoice(ref: "L-1", sats: 49_000, duration_seconds: 60)
    assert_equal LOT[0], first.onchain_address
    assert_nil sattleme.create_invoice(ref: "L-2", sats: 49_000).onchain_address
    # Its lease ends 120 s after the invoice's end; another server's clock may be 300 s behind.
    @merchant.now = first.expires_at + 120 + 300
    assert_nil sattleme.create_invoice(ref: "L-3", sats: 49_000).onchain_address
    @merchant.now += 1
    assert_equal LOT[0], sattleme.create_invoice(ref: "L-4", sats: 49_000).onchain_address
  end

  test "skips an address paid already, and publishes its witness none" do
    paid = TestChain.payment(TestChain.txid("old"), LOT[0], 20_000, height: 960_000)
    @merchant.chain.add(LOT[0], paid)
    @merchant.publish_lot([LOT[0], LOT[1]], 91)
    assert_equal LOT[1], client.create_invoice(ref: "L-5", sats: 49_000).onchain_address
    # Whichever was tried first: the paid one is never leased.
    assert_empty leases_of(LOT[0])
    @merchant.publish_lot([LOT[0]], 92)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "L-6", sats: 49_000) }
    expected = { address: LOT[0], txid: paid["txid"], sale: nil, sats: 20_000,
                 inputs: ["#{TestChain.txid("coin of #{paid["txid"]}")}:0"], replacement: false, expires_at: nil,
                 seen_at: @merchant.now }
    eventually { witnesses == [expected] }
  end

  test "takes no address from a lot of a newer format, and warns of it" do
    logger = TestLogger.new
    key = Derive.channel_keys(@merchant.integration_key)[1]
    event = Records.seal(type: "integration-onchain-lot",
                         value: { "version" => 2, "addresses" => LOT, "updatedAt" => 95 },
                         signer: @merchant.team_secret, encryption_key: key,
                         address: Derive.lot_address(@merchant.integration_key), created_at: 95,
                         random: SecureRandom.method(:random_bytes))
    @merchant.key_relays.each { |url| @merchant.net.get(url).store(event) }
    assert_nil client(logger: logger).create_invoice(ref: "N-0", sats: 49_000).onchain_address
    assert_equal ["sattleme-checkout: the integration's lot of addresses has a newer format than this version " \
                  "reads; update the gem (no on-chain payment until then)"], logger.messages
  end

  test "never leases an address a lease of a newer format holds, and warns of it" do
    @merchant.publish_lot([LOT[0]], 91)
    other = sale_of_ref("A NEWER SERVER")
    newer = Leases.seal(other, LOT[0], { "version" => 2, "end" => @merchant.now + 1020 }, @merchant.now,
                        SecureRandom.method(:random_bytes))
    @merchant.key_relays.each { |url| @merchant.net.get(url).take(newer) }
    logger = TestLogger.new
    assert_nil client(logger: logger).create_invoice(ref: "N-3", sats: 49_000).onchain_address
    assert_equal ["sattleme-checkout: a lease of the integration's addresses has a newer format than this version " \
                  "reads; update the gem"], logger.messages
    # Forged (its signature not the author's): no record of a newer format, nothing to warn of.
    @merchant.key_relays.each { |url| @merchant.net.get(url).clear }
    @merchant.publish_channel(
      @merchant.channel_value(100, "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN }), 100
    )
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.key_relays.each { |url| @merchant.net.get(url).store(newer.to_h.merge("sig" => "00" * 64)) }
    quiet = TestLogger.new
    client(logger: quiet).create_invoice(ref: "N-4", sats: 49_000)
    assert_empty quiet.messages
  end

  test "never leases an address that an event of the seen author names, a witness or not" do
    seen = Derive.seen_keys(@merchant.integration_key)
    naming = lambda do |address|
      tags = [["d", "00" * 32], ["o", Witnesses.address_tag(seen.address_key, address)]]
      Events.sign(seen.secret_key, SecureRandom.method(:random_bytes),
                  created_at: @merchant.now - 60, kind: 30_078, tags: tags, content: "no witness").to_h
    end
    relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }
    @merchant.publish_lot([LOT[0]], 91)
    relays.each { |relay| relay.store(naming.call(LOT[0])) }
    assert_nil client.create_invoice(ref: "N-1", sats: 49_000).onchain_address
    # One whose signature does not check out names nothing.
    @merchant.publish_lot([LOT[1]], 92)
    relays.each { |relay| relay.store(naming.call(LOT[1]).merge("sig" => "00" * 64)) }
    assert_equal LOT[1], client.create_invoice(ref: "N-2", sats: 49_000).onchain_address
  end

  test "withdraws its lease, unconfirmed, when another server leased the address at once" do
    @merchant.publish_lot([LOT[0]], 91)
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    other = sale_of_ref("ANOTHER-SERVER")
    raced = false
    mutex = Mutex.new
    # Another server's lease of the same address reaches every relay right after this one's.
    on_event = lambda do |event, _relay|
      next unless event["tags"].any? { |tag| tag[1] == d }
      next if mutex.synchronize { raced.tap { raced = true } }

      terms = Leases::Terms.new(address: LOT[0], sats: 1000, invoice: nil, verify_url: nil, created_at: @merchant.now,
                                expires_at: @merchant.now + 900,
                                price: { "minor" => 1000, "digits" => 0, "currency" => "SAT" }, note: "Another order",
                                tolerance: 0, confirmed: nil)
      competing = Leases.event(sale: other, terms: terms, created_at: @merchant.now,
                               random: SecureRandom.method(:random_bytes))
      @merchant.key_relays.each { |relay| @merchant.net.get(relay).take(competing) }
    end
    @merchant.key_relays.each { |url| @merchant.net.get(url).behaviour = { on_event: on_event } }
    invoice = client.create_invoice(ref: "L-7", sats: 49_000)
    # It saw the other lease after its own was on a majority: not confirmed, Lightning only. Its
    # lease, unmarked, is withdrawn: it gives the invoice no address.
    assert_nil invoice.onchain_address
    records = eventually do
      own = leases_of(LOT[0]).reject { |_, event| event["pubkey"] == other.author }
      own.size == 2 && own
    end
    assert_equal %w[lease withdrawn], records.map(&:first)
    refute open_as_merchant(records[0][1])["confirmed"]
    assert_operator records[1][1]["created_at"], :>, records[0][1]["created_at"]
    found = client.find_invoices("L-7")[0]
    assert_equal [invoice.bolt11, nil], [found.bolt11, found.onchain_address]
  end

  test "leaves its lease, confirmed, when the declaration fails: it holds the address" do
    @merchant.publish_lot([LOT[0]], 91)
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    @merchant.key_relays.first(2).each do |url|
      # Leases and withdrawals are taken, declarations refused.
      @merchant.net.get(url).behaviour = { refuse_event: lambda { |event|
        if event["tags"].any? do |tag|
          tag[1] == d
        end
          nil
        else
          "blocked: no"
        end
      } }
    end
    assert_raises(NetworkError) { client.create_invoice(ref: "L-8", sats: 49_000) }
    # The lease and its mark (on the first relay too, which may be past the majority that took the
    # mark): never withdrawn.
    eventually { leases_of(LOT[0]).size >= 2 }
    assert_equal %w[lease lease], leases_of(LOT[0]).map(&:first)
    # Nor on the relays a withdrawal would have reached before the call ended.
    assert(@merchant.key_relays.none? do |url|
      @merchant.net.get(url).received.any? do |event|
        Leases.open_record(event, @merchant.registry_key, d)&.hold == :withdrawn
      end
    end)
    @merchant.key_relays.each { |url| @merchant.net.get(url).behaviour = {} }
    # It holds the address until its end: another order gets none.
    assert_nil client.create_invoice(ref: "L-9", sats: 49_000).onchain_address
  end

  test "leaves its lease, confirmed, when its checkout link fails: it holds the address, and nothing is declared" do
    @merchant.publish_lot([LOT[0]], 91)
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    author = sale_of_ref("L-12").author
    # A majority refuses the checkout link (its record alone has an expiration tag), and takes
    # the lease and its mark.
    link = ->(event) { event["tags"].any? { |tag| tag[0] == "expiration" } }
    refuse_links = { refuse_event: ->(event) { link.call(event) ? "blocked: no" : nil } }
    @merchant.key_relays.first(2).each { |url| @merchant.net.get(url).behaviour = refuse_links }
    assert_raises(NetworkError) { client.create_invoice(ref: "L-12", sats: 49_000, checkout: true) }
    # The lease and its mark: never withdrawn, on no relay.
    eventually { leases_of(LOT[0]).size >= 2 }
    assert_equal %w[lease lease], leases_of(LOT[0]).map(&:first)
    assert open_as_merchant(leases_of(LOT[0])[1][1])["confirmed"]
    relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }
    assert(relays.none? do |relay|
      relay.received.any? { |event| Leases.open_record(event, @merchant.registry_key, d)&.hold == :withdrawn }
    end)
    # Nothing declared: the sale's only records are at the address's lease.
    assert(relays.all? do |relay|
      relay.received.select { |event| event["pubkey"] == author }.all? { |event| event["tags"].include?(["d", d]) }
    end)
    relays.each { |relay| relay.behaviour = {} }
    # It holds the address until its end: another order gets none.
    assert_nil client.create_invoice(ref: "L-13", sats: 49_000).onchain_address
    # The same order gets a new invoice at once (its first one never shown), without that address.
    again = client.create_invoice(ref: "L-12", sats: 49_000, checkout: true)
    assert_nil again.onchain_address
    refute_nil again.checkout_url
  end

  test "refuses an invoice its lease cannot hold, before anything is published" do
    @merchant.publish_lot([LOT[0]], 91)
    # The lease seals the invoice twice, as the declaration does, with some 150 bytes more: an
    # invoice of 40 550 characters fits a declaration (its inside within NIP-44's padded 40 960
    # bytes) and not a lease (padded to 49 152 bytes, too large once sealed again).
    @merchant.tamper = lambda do |made|
      sized = lambda do |words|
        extra = Array.new(39) { [31, [0] * 1023] } + [[31, [0] * words]]
        TestLightning.make_invoice(amount_msat: made.amount_msat, payment_hash: made.payment_hash,
                                   description_hash: TestLightning.metadata_hash(TestMerchant::METADATA),
                                   timestamp: @merchant.now, expiry_seconds: 900, extra: extra)
      end
      { pr: sized.call(40_550 - sized.call(0).length) }
    end
    sent = @merchant.key_relays.map { |url| @merchant.net.get(url).received.size }
    error = assert_raises(InvalidInvoiceError) { client.create_invoice(ref: "L-14", sats: 49_000) }
    assert_match(/lease of an address/, error.message)
    # Nothing published: no lease, no declaration.
    assert_equal(sent, @merchant.key_relays.map { |url| @merchant.net.get(url).received.size })
    assert_equal 40_550, @merchant.made_invoices.last.pr.length
    # Its declaration alone fits: an order paid in Lightning only takes such an invoice.
    assert_equal 40_550, client.create_invoice(ref: "L-15", sats: 900).bolt11.length
  end

  # Has breez.tips answer the next invoices with one of `length` characters, of the same amount,
  # payment hash, description hash and dates (BOLT11 fields of zeros added).
  def invoices_of_length(length)
    @merchant.tamper = lambda do |made|
      sized = lambda do |words|
        extra = Array.new(39) { [31, [0] * 1023] } + [[31, [0] * words]]
        TestLightning.make_invoice(amount_msat: made.amount_msat, payment_hash: made.payment_hash,
                                   description_hash: TestLightning.metadata_hash(TestMerchant::METADATA),
                                   timestamp: @merchant.now, expiry_seconds: made.expiry, extra: extra)
      end
      { pr: sized.call(length - sized.call(0).length) }
    end
  end

  # The inside of a lease, as the merchant's app opens it: its JSON, as it was sealed.
  def lease_inside(event)
    d = event["tags"].find { |tag| tag[0] == "d" }[1]
    outside = Json.parse(Nip44.decrypt(event["content"], Derive.outer_key(@merchant.registry_key, d, event["pubkey"])))
    Nip44.decrypt(outside["v"]["sealed"], Nip44.conversation_key(@merchant.reader_secret, event["pubkey"]))
  end

  test "measures a lease as first published, \"confirmed\": false: one that fits only marked confirmed is refused" do
    # SPEC.md §17 step 6. A lease's inside of 40 960 bytes at most is padded to 40 960 (NIP-44),
    # and sealed again fits a NIP-44 plaintext; of one byte more, it is padded to 49 152, and does
    # not. The inside of an order's lease, the invoice aside, is of one length for every order of
    # these terms (a reference of 4 characters, 49 000 sats, its dates): measured on a lease made.
    @merchant.publish_lot([LOT[0]], 91)
    made = client.create_invoice(ref: "L-16", sats: 49_000)
    # The first relay may take it after the call returned, past the majority.
    first = eventually { leases_of(LOT[0]).first }[1]
    inside = lease_inside(first)
    assert_equal({ "confirmed" => false }, Json.parse(inside).slice("confirmed"))
    around = inside.bytesize - made.bolt11.length
    # An invoice whose lease's inside is 40 960 bytes marked confirmed ("true"), 40 961 as first
    # published ("false").
    @merchant.publish_lot([LOT[1]], 92)
    invoices_of_length(40_960 - around + 1)
    # Every publication goes to every relay: once each received as many events, none of the first
    # order's is on its way (a relay past a publication's majority may still be after its call).
    sent = eventually do
      counts = @merchant.key_relays.map { |url| @merchant.net.get(url).received.size }
      counts.uniq.one? && counts
    end
    queried = @merchant.key_relays.map { |url| @merchant.net.get(url).queries.size }
    called = @merchant.http.calls.size
    draws = []
    random = lambda do |length|
      draws << caller_locations.map(&:label)
      SecureRandom.random_bytes(length)
    end
    error = assert_raises(InvalidInvoiceError) { client(random: random).create_invoice(ref: "L-17", sats: 49_000) }
    assert_match(/lease of an address/, error.message)
    assert_equal 40_960 - around + 1, @merchant.made_invoices.last.pr.length
    # Before anything was asked or published for the lease: neither the lot read nor the explorer
    # asked, nothing published (the channel and the order's earlier invoices were read before).
    assert_equal(sent, @merchant.key_relays.map { |url| @merchant.net.get(url).received.size })
    asked = @merchant.key_relays.each_with_index.flat_map do |url, i|
      @merchant.net.get(url).queries.drop(queried[i])
    end
    assert_empty(asked.select { |filter| filter["#d"]&.include?(Derive.lot_address(@merchant.integration_key)) })
    assert_empty(@merchant.http.calls.drop(called).select { |call| call.url.include?("mempool.space") })
    # The size was measured with random bytes of its own, never the client's.
    assert_empty(draws.select { |labels| labels.any? { |label| label.include?("check_lease_size") } })
    # One character less: its lease's inside is 40 960 bytes as first published, and it is taken.
    invoices_of_length(40_960 - around)
    taken = client.create_invoice(ref: "L-18", sats: 49_000)
    assert_equal [LOT[1], 40_960 - around], [taken.onchain_address, taken.bolt11.length]
    assert_equal 40_960, lease_inside(eventually { leases_of(LOT[1]).first }[1]).bytesize
  end

  test "publishes nothing but its withdrawal when the lease does not reach a majority" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.key_relays.first(2).each { |url| @merchant.net.get(url).behaviour = { refuse: "blocked: no" } }
    assert_raises(NetworkError) { client.create_invoice(ref: "L-10", sats: 49_000) }
    third = @merchant.net.get(@merchant.key_relays[2])
    # The lease, then its withdrawal: no mark, no declaration, no link.
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    kinds = lambda do
      third.received.map do |event|
        record = Leases.open_record(event, @merchant.registry_key, d)
        record && (record.hold.is_a?(Integer) ? "lease" : record.hold.to_s)
      end
    end
    eventually { kinds.call.size == 2 }
    assert_equal %w[lease withdrawn], kinds.call
  end

  test "fails with NetworkError when fewer than a majority answered its lease's confirmation, a relay still reading" do
    @merchant.publish_lot([LOT[0]], 91)
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    first, second = @merchant.key_relays.first(2).map { |url| @merchant.net.get(url) }
    # The third relay down from the start: failed at once in the confirmation's read.
    @merchant.net.remove(@merchant.key_relays[2])
    junk = lambda do |id, created_at|
      { "id" => id, "pubkey" => "ab" * 32, "created_at" => created_at, "kind" => 30_078, "tags" => [["d", d]],
        "content" => "", "sig" => "00" * 64 }
    end
    lease = ->(event) { event["tags"].include?(["d", d]) }
    # Once they hold the lease: on the first relay a full page of later events without a string id
    # (its read ends there, incomplete), late; on the second a full page, the lease in it, then no
    # answer (still reading).
    first.behaviour = { on_event: lambda do |event, relay|
      next unless lease.call(event) && relay.behaviour[:query_delay_ms].nil?

      100.times { |i| relay.store(junk.call(i, @merchant.now + 1000)) }
      relay.behaviour = relay.behaviour.merge(query_delay_ms: 300)
    end }
    second.behaviour = { on_event: lambda do |event, relay|
      next unless lease.call(event) && relay.behaviour[:mute_query].nil?

      100.times { |i| relay.store(junk.call(format("%064x", i), @merchant.now - 1 - i)) }
      relay.behaviour = relay.behaviour.merge(mute_query: ->(filter) { filter.key?("until") })
    end }
    assert_raises(NetworkError) { client.create_invoice(ref: "L-11", sats: 49_000) }
    # Not confirmed: withdrawn (on the first relay too, which may be past the majority that took it).
    eventually { leases_of(LOT[0]).size >= 2 }
    assert_equal %w[lease withdrawn], leases_of(LOT[0]).map(&:first)
  end

  # The payment of an invoice with an address

  def with_invoice
    @merchant.publish_lot([LOT[0]], 91)
    @client = client
    @invoice = @client.create_invoice(ref: "P-1", sats: 49_000, duration_seconds: 600)
    @address = @invoice.onchain_address
  end

  def sale_author = Derive.sale_keys(@merchant.integration_key, "P-1")[2]

  # BlockCypher's writing of Unix seconds.
  def iso(seconds) = Time.at(seconds).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")

  test "is unconfirmed once enough is sent, its witness published, then paid at 3 confirmations" do
    with_invoice
    assert_equal({ "state" => "open", "expiresAt" => @invoice.expires_at, "received" => "0", "rest" => nil },
                 @client.get_status(@invoice).to_h)
    tx = TestChain.payment(TestChain.txid("pay"), @address, 49_000)
    @merchant.chain.add(@address, tx)
    assert_equal({ "state" => "unconfirmed", "received" => "49000", "confirmations" => 0, "txids" => [tx["txid"]] },
                 @client.get_status(@invoice).to_h)
    # Seen while the lease runs: the witness of the order's sale, which the merchant's app reads.
    eventually { witnesses.size == 1 }
    assert_equal [@address, tx["txid"], sale_author, 49_000, false],
                 witnesses[0].values_at(:address, :txid, :sale, :sats, :replacement)
    @merchant.chain.confirm(@address, tx["txid"], @merchant.chain.height - 1)
    status = @client.get_status(@invoice)
    assert_equal ["unconfirmed", 2], [status.state, status.confirmations]
    @merchant.chain.confirm(@address, tx["txid"], @merchant.chain.height - 2)
    # 3 confirmations on the explorer read (mempool.space): paid, no other explorer asked.
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "49000", "txids" => [tx["txid"]] },
                 @client.get_status(@invoice).to_h)
    assert_empty(@merchant.chain.asked.reject { |href| href.start_with?("#{Protocol::MEMPOOL_URL}/") })
    # Long after the invoice's end: the witness says it came in time.
    @merchant.now = @invoice.expires_at + 3600
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "49000", "txids" => [tx["txid"]] },
                 @client.get_status(@invoice).to_h)
    # One witness: a check that finds it adds nothing.
    assert_equal 1, witnesses.size
    assert_empty @merchant.chain.blockcypher_asked
  end

  test "is open while underpaid, then expired with what was received" do
    with_invoice
    @merchant.chain.add(@address, TestChain.payment(TestChain.txid("part"), @address, 20_000, height: 969_990))
    # Its rest, asked in Lightning too (test/rest_test.rb).
    status = @client.get_status(@invoice)
    assert_equal ["open", @invoice.expires_at, "20000", "29000"],
                 [status.state, status.expires_at, status.received, status.rest.sats]
    @merchant.now = @invoice.expires_at + 121
    assert_equal({ "state" => "expired", "received" => "20000" }, @client.get_status(@invoice).to_h)
  end

  test "is expired for a payment no check saw, received late by BlockCypher's time" do
    with_invoice
    @merchant.now = @invoice.expires_at + 3600
    tx = TestChain.payment(TestChain.txid("late"), @address, 49_000)
    @merchant.chain.add(@address, tx)
    @merchant.chain.received[tx["txid"]] = iso(@invoice.expires_at + 121)
    assert_equal({ "state" => "expired", "received" => "0" }, @client.get_status(@invoice).to_h)
    assert_equal ["#{Protocol::BLOCKCYPHER_URL}/txs/#{tx["txid"]}?limit=1&includeHex=false"],
                 @merchant.chain.blockcypher_asked
    # Of no order: a witness none, so that the merchant's app takes the address out of the lot.
    eventually { witnesses.map { |witness| witness.values_at(:txid, :sale) } == [[tx["txid"], nil]] }
  end

  test "publishes no witness none of a late payment over a witness of a newer format, which it warns of" do
    with_invoice
    @merchant.now = @invoice.expires_at + 3600
    tx = TestChain.payment(TestChain.txid("late"), @address, 49_000)
    @merchant.chain.add(@address, tx)
    @merchant.chain.received[tx["txid"]] = iso(@invoice.expires_at + 121)
    # The witness none of this transaction, by a newer version, in a format this one cannot read.
    seen = Derive.seen_keys(@merchant.integration_key)
    d = Witnesses.witness_address(seen.address_key, @address, tx["txid"], nil)
    tags = [["d", d], ["o", Witnesses.order_tag(seen.address_key, @address, nil)],
            ["o", Witnesses.address_tag(seen.address_key, @address)]]
    newer = Events.sign(seen.secret_key, SecureRandom.method(:random_bytes),
                        created_at: @merchant.now - 60, kind: 30_078, tags: tags, content: "#")
    relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }
    relays.each { |relay| relay.take(newer) }
    logger = TestLogger.new
    assert_equal({ "state" => "expired", "received" => "0" }, client(logger: logger).get_status(@invoice).to_h)
    # It names the transaction: nothing written over it.
    assert(relays.all? { |relay| relay.received.none? { |event| event["tags"].include?(["d", d]) } })
    assert_equal ["sattleme-checkout: a witness of this address has a newer format than this version reads; " \
                  "update the gem"], logger.messages
  end

  test "reads the clock once the explorer answered: a payment it lists after the lease's end is late" do
    with_invoice
    ending = @invoice.expires_at + 120
    @merchant.now = ending
    tx = TestChain.payment(TestChain.txid("at the end"), @address, 49_000)
    # Broadcast, and listed, a second after the lease's end, while the explorer was asked.
    @merchant.override = lambda do |url|
      if url.to_s.include?("/address/#{@address}/txs") && @merchant.now == ending
        @merchant.now = ending + 1
        @merchant.chain.add(@address, tx)
      end
      nil
    end
    @merchant.chain.received[tx["txid"]] = iso(ending + 1)
    assert_equal({ "state" => "expired", "received" => "0" }, @client.get_status(@invoice).to_h)
    # Asked of BlockCypher, never taken in time.
    assert_equal 1, @merchant.chain.blockcypher_asked.size
    eventually { witnesses.map { |witness| witness.values_at(:txid, :sale) } == [[tx["txid"], nil]] }
  end

  test "counts a payment no check saw that BlockCypher received in time" do
    with_invoice
    @merchant.now = @invoice.expires_at + 3600
    tx = TestChain.payment(TestChain.txid("in time"), @address, 49_000)
    @merchant.chain.add(@address, tx)
    @merchant.chain.received[tx["txid"]] = iso(@invoice.expires_at + 100)
    status = @client.get_status(@invoice)
    assert_equal %w[unconfirmed 49000], [status.state, status.received]
    eventually do
      witnesses.map do |witness|
        witness.values_at(:txid, :sale, :replacement)
      end == [[tx["txid"], sale_author, false]]
    end
    # Its witness spares the next check the question.
    @client.get_status(@invoice)
    assert_equal 1, @merchant.chain.blockcypher_asked.size
  end

  test "counts a fee bump after the lease's end of a payment seen in time" do
    with_invoice
    first = TestChain.payment(TestChain.txid("first"), @address, 49_000)
    @merchant.chain.add(@address, first)
    @client.get_status(@invoice)
    @merchant.now = @invoice.expires_at + 3600
    @merchant.chain.drop(@address, first["txid"])
    coins = first["vin"].map { |input| "#{input["txid"]}:#{input["vout"]}" } + ["#{TestChain.txid("fee")}:1"]
    bump = TestChain.payment(TestChain.txid("bump"), @address, 49_000, coins: coins)
    @merchant.chain.add(@address, bump)
    status = @client.get_status(@invoice)
    assert_equal ["unconfirmed", "49000", [bump["txid"]]], [status.state, status.received, status.txids]
    eventually do
      witnesses.any? { |witness| witness.values_at(:txid, :sale, :replacement) == [bump["txid"], sale_author, true] }
    end
    # Nothing to ask BlockCypher: all of it stands for the payment it replaces.
    assert_empty @merchant.chain.blockcypher_asked
  end

  test "fails with NetworkError when the explorer does not answer, unless Lightning was paid" do
    with_invoice
    @merchant.chain.down << :explorer
    assert_raises(NetworkError) { @client.get_status(@invoice) }
    @merchant.pay_invoice(@invoice.payment_hash)
    status = @client.get_status(@invoice)
    assert_equal %w[paid lightning], [status.state, status.payment_method]
  end

  # SPEC.md §14: a paid Lightning invoice wins over every failure of the on-chain part, not only
  # `revoked` (the integration removed: "stops the calls that read the channel…" below) and an
  # explorer that does not answer (above): the channel not found, and relays that do not answer.
  test "is paid by its Lightning invoice whatever the channel's read gives: not found, or no answer" do
    with_invoice
    @merchant.pay_invoice(@invoice.payment_hash)
    # The key's relays answer, without the channel: channel_not_found for the on-chain part.
    held = @merchant.key_relays.to_h { |url| [url, @merchant.net.get(url).events] }
    @merchant.key_relays.each { |url| @merchant.net.get(url).clear }
    assert_raises(ChannelNotFoundError) { @client.find_invoices("P-1") }
    status = @client.get_status(@invoice)
    assert_equal %w[paid lightning], [status.state, status.payment_method]
    # None of them answers: network for the on-chain part.
    held.each { |url, events| events.each { |event| @merchant.net.get(url).store(event) } }
    @merchant.key_relays.each { |url| @merchant.net.get(url).behaviour = { mute: true } }
    assert_raises(NetworkError) { @client.find_invoices("P-1") }
    status = @client.get_status(@invoice)
    assert_equal %w[paid lightning], [status.state, status.payment_method]
    # Unpaid, each of them is the check's error.
    @merchant.paid.clear
    assert_raises(NetworkError) { @client.get_status(@invoice) }
    @merchant.key_relays.each do |url|
      @merchant.net.get(url).behaviour = {}
      @merchant.net.get(url).clear
    end
    assert_raises(ChannelNotFoundError) { @client.get_status(@invoice) }
  end

  test "is found by the order's next invoice: pending while confirmed, then paid" do
    with_invoice
    tx = TestChain.payment(TestChain.txid("order"), @address, 49_000)
    @merchant.chain.add(@address, tx)
    @client.get_status(@invoice)
    @merchant.now = @invoice.expires_at + 600
    pending = assert_raises(InvoicePendingError) { @client.create_invoice(ref: "P-1", sats: 49_000) }
    assert_equal [@invoice.bolt11, @address], [pending.invoice.bolt11, pending.invoice.onchain_address]
    @merchant.chain.confirm(@address, tx["txid"], @merchant.chain.height - 5)
    paid = assert_raises(OrderPaidError) { @client.create_invoice(ref: "P-1", sats: 49_000) }
    assert_nil paid.preimage
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "49000", "txids" => [tx["txid"]] },
                 paid.status.to_h)
  end

  test "is found by find_invoices with its address, an order paid on-chain only too" do
    with_invoice
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    @merchant.publish_lot([LOT[1]], 92)
    onchain_only = @client.create_invoice(ref: "P-2", sats: 2_000_000, note: "Big")
    assert_equal({ "ref" => "P-1", "bolt11" => @invoice.bolt11, "paymentHash" => @invoice.payment_hash,
                   "verifyUrl" => @invoice.verify_url, "onchainAddress" => @address,
                   "paymentUri" => @invoice.payment_uri, "sats" => "49000", "fiat" => nil, "note" => "P-1",
                   "createdAt" => @invoice.created_at, "expiresAt" => @invoice.expires_at,
                   "declaredAt" => @merchant.now }, @client.find_invoices("P-1")[0].to_h)
    assert_equal([{ "ref" => "P-2", "bolt11" => nil, "paymentHash" => nil, "verifyUrl" => nil,
                    "onchainAddress" => onchain_only.onchain_address, "paymentUri" => onchain_only.payment_uri,
                    "sats" => "2000000", "fiat" => nil, "note" => "Big", "createdAt" => onchain_only.created_at,
                    "expiresAt" => onchain_only.expires_at,
                    # Its confirmed lease: marked a second after the lease.
                    "declaredAt" => onchain_only.created_at + 1 }], @client.find_invoices("P-2").map(&:to_h))
    # Pending: its declaration and its lease published again, nothing else made.
    before = @merchant.invoices.size
    assert_raises(InvoicePendingError) { @client.create_invoice(ref: "P-2", sats: 2_000_000) }
    assert_equal before, @merchant.invoices.size
  end

  test "refuses a stored invoice with an address but no reference" do
    with_invoice
    assert_raises(InvalidOrderError) { @client.get_status(@invoice.to_h.except("ref")) }
    assert_raises(InvalidOrderError) { @client.get_status(@invoice.with(ref: nil)) }
    assert_raises(InvalidOrderError) { @client.get_status(@invoice.with(onchain_address: "bc1qnotanaddress")) }
  end

  test "reads an invoice without an address field as Lightning only" do
    with_invoice
    stored = @invoice.to_h.except("onchainAddress", "paymentUri")
    @merchant.chain.down << :explorer
    status = @client.get_status(stored)
    assert_equal %w[open 0], [status.state, status.received]
  end

  test "refuses a stored invoice lacking bolt11, paymentHash or verifyUrl: only onchainAddress may be absent" do
    with_invoice
    calls = @merchant.http.calls.size
    stored = @invoice.to_h
    # An order paid on-chain only has them, as null.
    onchain_only = stored.merge("bolt11" => nil, "paymentHash" => nil, "verifyUrl" => nil)
    [stored, onchain_only].each do |json|
      %w[bolt11 paymentHash verifyUrl].each do |name|
        [json.except(name), Json.generate(json.except(name)), json.except(name).transform_keys(&:to_sym)].each do |form|
          error = assert_raises(InvalidOrderError, name) { @client.get_status(form) }
          assert_equal "invoice", error.param
        end
      end
    end
    # Refused before anything is asked.
    assert_equal calls, @merchant.http.calls.size
    @merchant.chain.down << :explorer
    assert_raises(NetworkError) { @client.get_status(onchain_only) }
  end

  # A removed integration (SPEC.md §14)

  test "stops the calls that read the channel once the integration was removed, never a check that reads none" do
    sattleme = client
    paid = sattleme.create_invoice(ref: "X-1", sats: 49_000)
    unpaid = sattleme.create_invoice(ref: "X-2", sats: 49_000)
    lightning = sattleme.create_invoice(ref: "X-3", sats: 500)
    @merchant.pay_invoice(paid.payment_hash)
    @merchant.publish_channel({ "version" => 1, "status" => "removed", "updatedAt" => 200 }, 200)
    # Making an invoice, finding an order's, reading the merchant, the on-chain part of a check.
    assert_raises(RevokedError) { sattleme.create_invoice(ref: "X-4", sats: 500) }
    assert_raises(RevokedError) { sattleme.find_invoices("X-1") }
    assert_raises(RevokedError) { sattleme.merchant }
    assert_raises(RevokedError) { sattleme.get_status(unpaid) }
    # The check of an invoice without an address reads no relay and goes on.
    asked = -> { @merchant.key_relays.sum { |url| @merchant.net.get(url).queries.size } }
    before = asked.call
    assert_equal "open", sattleme.get_status(lightning).state
    assert_equal before, asked.call
    # An invoice with an address paid by its Lightning invoice is still found paid.
    status = sattleme.get_status(paid)
    assert_equal %w[paid lightning], [status.state, status.payment_method]
  end

  # wait_for_payment of an invoice with an address

  test "checks the on-chain part when the explorer's WebSocket says something changed" do
    socket = @merchant.start_explorer_socket
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client
    invoice = sattleme.create_invoice(ref: "W-1", sats: 49_000)
    address = invoice.onchain_address
    statuses = Queue.new
    seen = []
    # Lightning checked once a minute: what moves here is the socket.
    waiting = Thread.new { sattleme.wait_for_payment(invoice, interval_ms: 60_000) { |status| statuses << status } }
    last = lambda do
      seen << statuses.pop until statuses.empty?
      seen.last
    end
    eventually { socket.messages.size == 2 && last.call }
    assert_equal [{ "action" => "want", "data" => ["blocks"] }, { "track-address" => address }], socket.messages
    assert_predicate last.call, :open?

    tx = TestChain.payment(TestChain.txid("watched"), address, 49_000)
    @merchant.chain.add(address, tx)
    socket.push({ "address-transactions" => [tx] })
    eventually { last.call&.unconfirmed? }

    @merchant.chain.confirm(address, tx["txid"], @merchant.chain.height - 2)
    socket.push({ "block" => { "height" => @merchant.chain.height } })
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => "49000", "txids" => [tx["txid"]] },
                 waiting.value.to_h)
    # Closed once done.
    eventually { socket.server.open_connections.empty? }
  end

  # The world's HTTP, but for the explorer's answers to an address's transactions, held while
  # `gate` is set: until it is opened, or until the request's cancellation (the gem gave it up).
  class HeldTransactions
    attr_accessor :gate

    def initialize(http)
      @http = http
      @gate = nil
      @held = Queue.new
    end

    # How many answers it held.
    def held = @held.size

    def get(url, headers:, timeout:, cancellation:, &)
      gate = @gate
      if gate && url.end_with?("/txs")
        @held << url
        handle = cancellation.on_cancel { gate.cancel }
        gate.wait
        cancellation.remove(handle)
      end
      @http.get(url, headers: headers, timeout: timeout, cancellation: cancellation, &)
    end
  end

  test "leaves nothing running once it returned: a check it started stops, and has ended" do
    socket = @merchant.start_explorer_socket
    @merchant.publish_lot([LOT[0]], 91)
    http = HeldTransactions.new(@merchant.http)
    sattleme = client(http_client: http)
    invoice = sattleme.create_invoice(ref: "W-3", sats: 49_000)
    address = invoice.onchain_address
    statuses = Queue.new
    waiting = Thread.new { sattleme.wait_for_payment(invoice, interval_ms: 250) { |status| statuses << status } }
    eventually { socket.messages.size == 2 && !statuses.empty? }
    # A block: a full check starts, and waits for the explorer's answer.
    gate = Cancellation.new
    http.gate = gate
    socket.push({ "block" => { "height" => @merchant.chain.height } })
    eventually { http.held.positive? }
    # Meanwhile the Lightning invoice is paid: the wait returns.
    @merchant.pay_invoice(invoice.payment_hash)
    final = waiting.value
    assert_equal %w[paid lightning], [final.state, final.payment_method]
    # Every check it started has ended.
    assert(Thread.list.none? { |thread| thread.name == "sattleme-checkout wait" && thread.alive? })
    # Then the explorer answers, a part of the amount listed: the check it held would publish its
    # witness, ask an invoice of the rest and declare it. It stopped with the wait.
    # Every publication goes to every relay: once each has received as many, none is on its way.
    sent = -> { @merchant.key_relays.map { |url| @merchant.net.get(url).received.size } }
    before = eventually { sent.call.then { |counts| counts.uniq.size == 1 && counts } }
    made = @merchant.made_invoices.size
    @merchant.chain.add(address, TestChain.payment(TestChain.txid("late part"), address, 10_000))
    gate.cancel
    sleep 0.5
    assert_equal before, sent.call
    assert_equal made, @merchant.made_invoices.size
  end

  test "stops when its cancellation is cancelled" do
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client
    invoice = sattleme.create_invoice(ref: "W-2", sats: 49_000)
    cancellation = Cancellation.new
    Thread.new do
      sleep 0.05
      cancellation.cancel("stop")
    end
    error = assert_raises(Cancelled) { sattleme.wait_for_payment(invoice, cancellation: cancellation) }
    assert_equal "stop", error.message
  end

  # A checkout link to an invoice with an address

  test "is a record of version 2, which the page reads without the invoice" do
    @merchant.publish_lot([LOT[0]], 91)
    invoice = client.create_invoice(ref: "C-1", sats: 49_000, checkout: true, redirect_url: "https://shop.example/thanks")
    fragment = CheckoutLinks.parse_fragment(invoice.checkout_url[invoice.checkout_url.index("#")..])
    assert_equal :link, fragment.status
    keys = CheckoutLinks.keys(fragment.link_key)
    event = eventually { held.find { |e| e["tags"].any? { |name, d| name == "d" && d == keys.address } } }
    value = Json.parse(Nip44.decrypt(event["content"], keys.encryption_key))["v"]
    rest = Derive.rest_keys(@merchant.integration_key, "C-1", invoice.onchain_address, invoice.expires_at)
    assert_equal({ "version" => 2, "businessName" => "Sunrise Bakery", "invoice" => invoice.bolt11,
                   "verifyUrl" => invoice.verify_url, "onchainAddress" => invoice.onchain_address, "sats" => 49_000,
                   "createdAt" => invoice.created_at, "expiresAt" => invoice.expires_at, "fiat" => nil, "note" => "C-1",
                   "redirectUrl" => "https://shop.example/thanks",
                   # The rest records of this invoice of the order: written by the integration key alone.
                   "restAuthor" => rest.author, "restKey" => to_hex(rest.key) }, value)
    record = CheckoutLinks.parse_value(value)
    assert_equal [invoice.onchain_address, 49_000, invoice.expires_at, [rest.author, rest.key]],
                 [record.onchain_address, record.sats, record.expires_at, record.rest]
  end

  # A lease's inside

  test "opens a lease as the sale's only with its invoice and verifyUrl: both null for an order paid on-chain only" do
    sale = sale_of_ref("OPEN-1")
    d = Addresses.lease_address(@merchant.registry_key, LOT[0])
    inside = { "version" => 1, "address" => LOT[0], "sats" => 2_000_000, "invoice" => nil, "verifyUrl" => nil,
               "createdAt" => @merchant.now, "expiresAt" => @merchant.now + 900,
               "sale" => { "key" => to_hex(sale.key),
                           "fiat" => { "minor" => 2_000_000, "digits" => 0, "currency" => "SAT" }, "note" => "Big" },
               "taker" => sale.taker }
    open = lambda do |value|
      sealed = Nip44.encrypt(Json.generate(value), sale.inner_key, SecureRandom.method(:random_bytes))
      Leases.open_inside(@merchant.now + 1020, sealed, d, sale)
    end
    terms, = open.call(inside)
    assert_equal [LOT[0], 2_000_000, nil, nil], [terms.address, terms.sats, terms.invoice, terms.verify_url]
    # Absent is not null: no lease of the sale.
    [inside.except("invoice"), inside.except("verifyUrl"), inside.except("invoice", "verifyUrl")].each do |lacking|
      assert_nil open.call(lacking), lacking.keys.inspect
    end
  end

  # The explorers' answers

  test "reads an output's scriptpubkey_address as a string when present: null is no transaction" do
    tx = TestChain.payment(TestChain.txid("strict"), LOT[0], 1000)
    assert_equal [[1000, LOT[0]], [5000, TestChain.deposit_address("change")]], Explorer.parse_transaction(tx).outputs
    # Absent: an output to no address (OP_RETURN, a bare script), paying none.
    without = tx.merge("vout" => tx["vout"] + [{ "value" => 0, "scriptpubkey" => "6a" }])
    assert_equal [0, nil], Explorer.parse_transaction(without).outputs[2]
    [nil, 5, ["bc1q"], {}, true].each do |address|
      broken = tx.merge("vout" => [tx["vout"][0], { "value" => 0, "scriptpubkey_address" => address }])
      assert_nil Explorer.parse_transaction(broken), address.inspect
    end
  end

  test "fails with NetworkError when the explorer lists an output whose scriptpubkey_address is null" do
    with_invoice
    tx = TestChain.payment(TestChain.txid("null address"), @address, 49_000)
    tx["vout"] << { "value" => 0, "scriptpubkey_address" => nil }
    @merchant.chain.add(@address, tx)
    error = assert_raises(NetworkError) { @client.get_status(@invoice) }
    assert_match(/not one/, error.message)
    tx["vout"].pop
    assert_equal "unconfirmed", @client.get_status(@invoice).state
  end

  # BlockCypher's times

  test "reads them as BlockCypher writes them, the fraction past milliseconds dropped, and refuses anything else" do
    at = ->(*parts) { Time.utc(*parts).to_i * 1000 }
    assert_equal at.call(2026, 10, 10, 13, 5, 12) + 345, Explorer.blockcypher_milliseconds("2026-10-10T13:05:12.345Z")
    assert_equal at.call(2026, 10, 10, 13, 5, 12) + 910, Explorer.blockcypher_milliseconds("2026-10-10T13:05:12.91Z")
    assert_equal at.call(2026, 10, 10, 13, 5, 12), Explorer.blockcypher_milliseconds("2026-10-10T13:05:12Z")
    # Dropped, never rounded (SPEC.md §31, Explorers).
    assert_equal at.call(2026, 10, 10, 13, 5, 12) + 345,
                 Explorer.blockcypher_milliseconds("2026-10-10T13:05:12.345999999Z")
    # A leap day, and the year 75, not 1975: before 1970, never a time in a lease.
    assert_equal at.call(2028, 2, 29), Explorer.blockcypher_milliseconds("2028-02-29T00:00:00Z")
    assert_operator Explorer.blockcypher_milliseconds("0075-01-01T00:00:00Z"), :<, 0
    ["2026-02-30T00:00:00Z", "2026-02-29T00:00:00Z", "2100-02-29T00:00:00Z", "2026-13-01T00:00:00Z",
     "2026-10-10T24:00:00Z", "2026-12-31T23:59:60Z", "2026-10-10 13:05:12Z", "2026-10-10T13:05:12",
     "2026-10-10t13:05:12z", "2026-10-10T15:05:12+02:00", "2026-10-10T13:05:12.Z", "2026-10-10T13:05:12.0000000000Z",
     nil, 5].each do |text|
      assert_nil Explorer.blockcypher_milliseconds(text), text.inspect
    end
  end
end
