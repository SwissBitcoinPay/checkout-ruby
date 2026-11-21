# frozen_string_literal: true

require_relative "test_helper"

# Attacks on on-chain payments (S1 to S6; SPEC.md §13, §21, §31), end to end against local relays
# and fakes of the explorers. Each test states what must hold.
class OnchainSecurityTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  LOT = [TestChain.deposit_address(1), TestChain.deposit_address(2), TestChain.deposit_address(3)].freeze

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100, "relays" => @merchant.key_relays), 100)
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: QUIET, **)
  end

  def sale_of_ref(ref)
    Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader), ref)
  end

  # Reproducible random bytes.
  def seeded(seed)
    counter = 0
    lambda do |length|
      bytes = +"".b
      while bytes.bytesize < length
        bytes << Crypto.sha256("#{seed}/#{counter}".b)
        counter += 1
      end
      bytes.byteslice(0, length)
    end
  end

  # The lease of `address` by the sale of `ref`, from `created_at` for `seconds`.
  def lease_by(ref, address, created_at: @merchant.now, seconds: 900, random: SecureRandom.method(:random_bytes))
    terms = Leases::Terms.new(address: address, sats: 1000, invoice: nil, verify_url: nil, created_at: created_at,
                              expires_at: created_at + seconds,
                              price: { "minor" => 1000, "digits" => 0, "currency" => "SAT" }, note: ref, tolerance: 0,
                              confirmed: nil)
    Leases.event(sale: sale_of_ref(ref), terms: terms, created_at: created_at, random: random)
  end

  # A record anybody writes at a registry address (it is public): a throwaway key signs it.
  def junk(d, created_at, seed, content = "x")
    Events.sign(Crypto.sha256("throwaway #{seed}".b), ->(_) { "\x00".b * 32 }, created_at: created_at, kind: 30_078,
                                                                               tags: [["d", d]], content: content)
  end

  def relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }

  # Every relay of the key takes `event`.
  def everywhere(event) = relays.each { |relay| relay.take(event) }

  # The address an attempt handed out: an Invoice's, a pending invoice's, none on another error.
  def handed_out(outcome)
    case outcome
    when InvoicePendingError then outcome.invoice.onchain_address
    when StandardError then nil
    else outcome.onchain_address
    end
  end

  def attempt
    yield
  rescue Sattleme::Checkout::Error => e
    e
  end

  # S5: a paged read of the leases misses a lease every relay holds

  def d0 = Addresses.lease_address(@merchant.registry_key, LOT[0])

  # The client of the S5 tests, with the relay timeout by default: a local relay answers the
  # queries of one connection one at a time (strfry does not), so that the other reads of the order
  # (the addresses witnesses name, the read again on every relay) wait behind the pages of these
  # records, sorted and sent by the relays and read by the client in one process, which on a busy
  # machine take more than the second the other tests give a relay.
  def volume_client = client(relay_timeout_ms: 10_000)

  test "S5 control: another order's lease keeps the address" do
    @merchant.publish_lot([LOT[0]], 91)
    everywhere(lease_by("HOLDER", LOT[0]))
    assert_nil client.create_invoice(ref: "S5-0", sats: 49_000).onchain_address
  end

  test "S5 1. ties: a page of records of the lease's very second, with lower ids" do
    @merchant.publish_lot([LOT[0]], 91)
    relays.each { |relay| relay.behaviour = { cap: 500 } }
    # At equal created_at, the lowest id first (NIP-01; strfry: the last stored first).
    seed = 0
    lease = nil
    loop do
      lease = lease_by("HOLDER", LOT[0], random: seeded(seed))
      seed += 1
      break if lease.id >= "c"
    end
    everywhere(lease)
    made = 0
    i = 0
    while made < 500
      record = junk(d0, lease.created_at, i)
      i += 1
      next unless record.id < lease.id

      everywhere(record)
      made += 1
    end
    assert_nil volume_client.create_invoice(ref: "S5-1", sats: 49_000).onchain_address
  end

  test "S5 2. unusable dates: a page of records dated beyond 2^53" do
    @merchant.publish_lot([LOT[0]], 91)
    relays.each { |relay| relay.behaviour = { cap: 500 } }
    everywhere(lease_by("HOLDER", LOT[0]))
    500.times do |i|
      record = junk(d0, (2**53) + (2 * (i + 1)), i)
      # As a relay that keeps any date stores it (strfry refuses one more than 900 s ahead).
      relays.each { |relay| relay.store(record) }
    end
    assert_nil volume_client.create_invoice(ref: "S5-2", sats: 49_000).onchain_address
  end

  test "S5 3. volume: more than 20 pages of records newer than the lease" do
    @merchant.publish_lot([LOT[0]], 91)
    relays.each { |relay| relay.behaviour = { cap: 100 } }
    everywhere(lease_by("HOLDER", LOT[0], created_at: @merchant.now - 600))
    2001.times { |i| everywhere(junk(d0, @merchant.now - 599 + (i % 500), i)) }
    assert_nil volume_client.create_invoice(ref: "S5-3", sats: 49_000).onchain_address
  end

  test "S5 4. order: a relay that answers a filter without a limit oldest first" do
    @merchant.publish_lot([LOT[0]], 91)
    relays.each { |relay| relay.behaviour = { oldest_first_without_limit: true } }
    everywhere(lease_by("HOLDER", LOT[0]))
    1000.times { |i| everywhere(junk(d0, @merchant.now - 7000 + i, i)) }
    assert_nil volume_client.create_invoice(ref: "S5-4", sats: 49_000).onchain_address
  end

  test "S5 5. size: records of text costly to read, each of an author of its own, at the address's lease" do
    @merchant.publish_lot([LOT[0]], 91)
    # 64 KiB of lines of a non-ASCII letter: each line feed an escape in the relays' JSON. A reader
    # whose cost grows with the square of a string's escapes takes seconds for each: the read of
    # the leases then ran out of time on every relay, and every order of 1 000 sats or more failed.
    text = "é\n" * 21_800
    10.times { |i| everywhere(junk(d0, @merchant.now - 60 - i, "costly #{i}", text)) }
    # What anybody may write there takes nothing from the order.
    assert_equal LOT[0], volume_client.create_invoice(ref: "S5-5", sats: 49_000).onchain_address
  end

  # S4: records of a newer format, signed by any key, hold every address

  test "S4 an empty content at each registry address takes nothing away" do
    @merchant.publish_lot(LOT, 91)
    LOT.each_with_index do |address, i|
      everywhere(junk(Addresses.lease_address(@merchant.registry_key, address), @merchant.now, 10_000 + i, ""))
    end
    refute_nil client.create_invoice(ref: "S4-1", sats: 49_000).onchain_address
  end

  test "S4 each such record costs no signature check" do
    @merchant.publish_lot([LOT[0]], 91)
    1000.times { |i| everywhere(junk(d0, @merchant.now - i, 20_000 + i, "#")) }
    before = Secp256k1::Verifications.count
    client.create_invoice(ref: "S4-2", sats: 49_000)
    # The channel, the lot, the order's own records: a handful. Never one per junk record.
    assert_operator Secp256k1::Verifications.count - before, :<, 50
  end

  # S1: an earlier invoice whose lease was never confirmed is handed out again

  test "S1 an order paid on-chain only, whose lease reached one relay" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    r1, r2, r3 = relays
    author = sale_of_ref("S1-R").author
    start = @merchant.now
    # r1 takes the order's lease and nothing after it (its withdrawal is lost); r2 and r3 refuse.
    r1.behaviour = { refuse_event: ->(e) { e["pubkey"] == author && e["created_at"] > start ? "error: down" : nil } }
    refuse = { refuse_event: ->(e) { e["pubkey"] == author ? "error: down" : nil } }
    r2.behaviour = refuse
    r3.behaviour = refuse
    assert_raises(NetworkError) { client.create_invoice(ref: "S1-R", sats: 49_000) }

    # Another order while r1 is slow: r2 and r3, which never got that lease, answer first.
    r1.behaviour = { query_delay_ms: 500 }
    r2.behaviour = {}
    r3.behaviour = {}
    x = attempt { client.create_invoice(ref: "S1-X", sats: 49_000) }
    x_holds = handed_out(x) == LOT[0]

    # The first order again while r2 is slow: r1, which holds its lease, answers.
    r1.behaviour = {}
    r2.behaviour = { query_delay_ms: 500 }
    again = attempt { client.create_invoice(ref: "S1-R", sats: 49_000) }
    # Never both: the address handed out to this order while the other holds it.
    refute(x_holds && handed_out(again) == LOT[0])
  end

  test "S1 an invoice with Lightning whose declaration failed, its withdrawal on one relay" do
    @merchant.publish_lot([LOT[0]], 91)
    r1, r2, r3 = relays
    author = sale_of_ref("S1-L").author
    start = @merchant.now
    lease_record = ->(e) { e["tags"].any? { |name, value| name == "d" && value == d0 } }
    mine = ->(e) { e["pubkey"] == author }
    # r1: the lease and the declaration, not the withdrawal. r2: the lease and the withdrawal, not
    # the declaration. r3: the lease only.
    r1.behaviour = { refuse_event: lambda { |e|
      mine.call(e) && lease_record.call(e) && e["created_at"] > start ? "error: down" : nil
    } }
    r2.behaviour = { refuse_event: ->(e) { mine.call(e) && !lease_record.call(e) ? "error: down" : nil } }
    r3.behaviour = {
      refuse_event: ->(e) { mine.call(e) && (!lease_record.call(e) || e["created_at"] > start) ? "error: down" : nil }
    }
    assert_raises(NetworkError) { client.create_invoice(ref: "S1-L", sats: 49_000) }

    # Another order while r1 is slow: r2's withdrawal frees the address.
    r1.behaviour = { query_delay_ms: 500 }
    r2.behaviour = {}
    r3.behaviour = {}
    x_holds = client.create_invoice(ref: "S1-X", sats: 49_000).onchain_address == LOT[0]

    # The first order again while r2 is slow.
    r1.behaviour = {}
    r2.behaviour = { query_delay_ms: 500 }
    again = attempt { client.create_invoice(ref: "S1-L", sats: 49_000) }
    refute(x_holds && handed_out(again) == LOT[0])
  end

  # S2: a transaction evicted, then broadcast again during a later lease, pays two orders

  test "S2 the first order's witness names it" do
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client
    p = sattleme.create_invoice(ref: "S2-P", sats: 49_000, duration_seconds: 600)
    address = p.onchain_address
    # Paid with a very low fee, seen while P's lease runs: P's witness.
    t = TestChain.payment(TestChain.txid("S2 low fee"), address, 49_000)
    @merchant.chain.add(address, t)
    assert_predicate sattleme.get_status(p), :unconfirmed?
    # Evicted from the mempools: the explorer lists nothing for the address.
    @merchant.chain.drop(address, t["txid"])
    @merchant.now = p.expires_at + 120 + 301
    assert_equal({ "state" => "expired", "received" => "0" }, sattleme.get_status(p).to_h)

    n = sattleme.create_invoice(ref: "S2-N", sats: 49_000, duration_seconds: 600)
    # The payer's wallet broadcasts T again during N's lease; it is mined.
    @merchant.chain.add(address, t)
    sattleme.get_status(n) if n.onchain_address == address
    @merchant.chain.confirm(address, t["txid"], @merchant.chain.height - 5)
    # The payer asks for P again: the shop checks P's earlier invoice.
    p_again = attempt { sattleme.create_invoice(ref: "S2-P", sats: 49_000) }
    n_paid = n.onchain_address == address && sattleme.get_status(n).paid?
    # One transaction, one order.
    refute(n_paid && p_again.is_a?(OrderPaidError))
  end

  test "S2 no check saw it while the first lease ran: BlockCypher's time" do
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client
    p = sattleme.create_invoice(ref: "S2-Q", sats: 49_000, duration_seconds: 600)
    address = p.onchain_address
    t = TestChain.payment(TestChain.txid("S2 unseen"), address, 49_000)
    # BlockCypher received it while P's lease ran; no check of P saw it; it is evicted.
    @merchant.chain.received[t["txid"]] = Time.at(p.created_at + 10).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    @merchant.now = p.expires_at + 120 + 301
    assert_equal({ "state" => "expired", "received" => "0" }, sattleme.get_status(p).to_h)

    n = sattleme.create_invoice(ref: "S2-M", sats: 49_000, duration_seconds: 600)
    assert_equal address, n.onchain_address
    @merchant.chain.add(address, t)
    status = sattleme.get_status(n)
    assert_equal %w[unconfirmed 49000], [status.state, status.received]
    @merchant.chain.confirm(address, t["txid"], @merchant.chain.height - 5)
    p_again = attempt { sattleme.create_invoice(ref: "S2-Q", sats: 49_000) }
    n_paid = sattleme.get_status(n).paid?
    refute(n_paid && p_again.is_a?(OrderPaidError))
  end

  # S3: the witness of an earlier invoice of the order counts for a later one

  test "S3 an underpayment of an expired invoice counts again for the next one" do
    @merchant.publish_lot([LOT[0]], 91)
    # On-chain only: no rest invoice is asked.
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    sattleme = client
    first = sattleme.create_invoice(ref: "S3-R", sats: 49_000, duration_seconds: 600)
    address = first.onchain_address
    t = TestChain.payment(TestChain.txid("S3 part"), address, 30_000)
    @merchant.chain.add(address, t)
    status = sattleme.get_status(first)
    assert_equal %w[open 30000], [status.state, status.received]
    @merchant.now = first.expires_at + 121
    # Underpaid for good: the merchant settles the 30 000 sats with the customer.
    assert_equal({ "state" => "expired", "received" => "30000" }, sattleme.get_status(first).to_h)
    # T leaves the mempool (evicted).
    @merchant.chain.drop(address, t["txid"])
    @merchant.now = first.expires_at + 120 + 301
    second = attempt { sattleme.create_invoice(ref: "S3-R", sats: 49_000, duration_seconds: 600) }
    # No address for it (the fix): nothing can count twice.
    return assert_kind_of(OnchainUnavailableError, second) if second.is_a?(StandardError)

    assert_equal address, second.onchain_address
    # T broadcast again after the second invoice's end: late, whatever its witness.
    @merchant.now = second.expires_at + 3600
    @merchant.chain.add(address, t)
    assert_equal({ "state" => "expired", "received" => "0" }, sattleme.get_status(second).to_h)
  end

  test "S3 a witness of the earlier invoice, made after the later one leased the address" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    sattleme = client
    first = sattleme.create_invoice(ref: "S3-Q", sats: 49_000, duration_seconds: 600)
    address = first.onchain_address
    t = TestChain.payment(TestChain.txid("S3 unseen part"), address, 30_000)
    # Received by BlockCypher while the first lease ran; no check saw it; then evicted.
    @merchant.chain.received[t["txid"]] = Time.at(first.created_at + 10).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    # Beyond the reads of leases (7200 s), where the order's own records keep it off the address.
    @merchant.now = first.created_at + 7300
    assert_equal({ "state" => "expired", "received" => "0" }, sattleme.get_status(first).to_h)
    second = sattleme.create_invoice(ref: "S3-Q", sats: 49_000, duration_seconds: 600)
    assert_equal address, second.onchain_address
    # T comes back after the second invoice's end; the first invoice is checked first.
    @merchant.now = second.expires_at + 3600
    @merchant.chain.add(address, t)
    statuses = [sattleme.get_status(first), sattleme.get_status(second)]
    # T was received once: it counts for one invoice at most.
    assert_operator statuses.count { |status| status.received == "30000" }, :<=, 1
  end

  # S6: a hostile relay hides a lease from the majority that reads

  # The confirmation reads on every relay (SPEC.md §13): r2, late but in time, shows the lease.
  test "S6 the lease reached H and r2 only; H and r1 answer first" do
    @merchant.publish_lot([LOT[0]], 91)
    _, h, r2 = relays
    lease = lease_by("S6-A", LOT[0])
    # r1 refused it.
    h.take(lease)
    r2.take(lease)
    h.behaviour = { hide: ->(event) { event["id"] == lease.id } }
    # r2 answers its reads 1.5 s late, well within the timeout (4 s): H and r1 answer first,
    # whatever the load of the machine running the test.
    r2.behaviour = { query_delay_ms: 1500 }
    assert_nil client(relay_timeout_ms: 4000).create_invoice(ref: "S6-B", sats: 49_000).onchain_address
  end

  # Copies of a record under ids of their own: a read keeps none of them whole

  # `event` with another tag and date, its id recomputed, its signature left as it is.
  def copy_of(event, index, filler)
    created_at = event.created_at - 1 - index
    tags = event.tags + [["x", filler]]
    id = to_hex(Events.hash_of(event.pubkey, created_at, event.kind, tags, event.content))
    event.with(id: id, created_at: created_at, tags: tags)
  end

  test "a lease: of each copy, only its id, author, date and signature are kept" do
    lease = lease_by("OTHER", LOT[0], created_at: @merchant.now - 60)
    everywhere(lease)
    filler = "y" * 50_000
    # Relays that keep them all (anybody can write at a lease's address): read on any majority.
    copies = Array.new(200) { |i| copy_of(lease, i, filler) }
    relays.each { |relay| copies.each { |copy| relay.store(copy) } }
    stop = Stop.new(Cancellation::NONE)
    pool = Relay::Pool.new(websocket: @merchant.net.websocket_client, timeout_ms: 5000, stop: stop, random: seeded(1),
                           now: -> { @merchant.now })
    begin
      read = Leases.read(pool, @merchant.registry_key, [LOT[0]], @merchant.key_relays, now: @merchant.now,
                                                                                       random: seeded(1), stop: stop)
      records = read.records.fetch(LOT[0])
      # Every copy opens as the lease does (its id is its hash, its content decrypts).
      assert_equal 201, records.size
      assert(records.all? { |record| record.event.instance_of?(Leases::LeaseEvent) })
      assert(records.all? { |record| record.event.to_h.keys.sort == %i[created_at id pubkey sig] })
      # Only the lease is signed: the walk still finds the address leased.
      assert_equal([lease.id], records.select(&:signed?).map { |record| record.event.id })
      assert Leases.leased?(records, @merchant.now)
    ensure
      pool.close
    end
  end

  test "a signed record: a copy is not kept, its signature does not check out" do
    _, encryption_key = Derive.channel_keys(@merchant.integration_key)
    keep = Records.that_open { |_, author| author == @merchant.team ? encryption_key : nil }
    channel = @merchant.channel_event(@merchant.channel_value(100), 100)
    assert_equal channel.to_h, keep.call(channel.to_h)
    # What a relay adds to it is not kept.
    assert_equal channel.to_h, keep.call(channel.to_h.merge("relay" => "wss://relay.example"))
    assert_nil keep.call(copy_of(channel, 0, "z" * 1000).to_h)
    assert_nil keep.call(channel.to_h.merge("sig" => "00" * 64))
    # Another key's: not opened, not kept.
    assert_nil keep.call(channel.to_h.merge("pubkey" => "ab" * 32))
  end
end
