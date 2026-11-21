# frozen_string_literal: true

require_relative "test_helper"

# More attacks on on-chain payments (F1, F2, G3, G4, H1, H2, I1, L1 to L3, R6, R7, and S6 for
# witnesses), end to end against local relays and fakes of the explorers. Each test states what
# must hold (test/onchain_security_test.rb holds S1 to S6).
class OnchainSecurityReviewTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  LOT = [TestChain.deposit_address(1), TestChain.deposit_address(2), TestChain.deposit_address(3)].freeze
  RANDOM = SecureRandom.method(:random_bytes)

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

  def terms_of(ref, address, created_at, seconds, sats: 1000, confirmed: nil)
    Leases::Terms.new(address: address, sats: sats, invoice: nil, verify_url: nil, created_at: created_at,
                      expires_at: created_at + seconds, price: { "minor" => sats, "digits" => 0, "currency" => "SAT" },
                      note: ref, tolerance: 0, confirmed: confirmed)
  end

  # The lease of `address` by the sale of `ref`, from `created_at` for `seconds`.
  def lease_by(ref, address, created_at: @merchant.now, seconds: 900)
    Leases.event(sale: sale_of_ref(ref), terms: terms_of(ref, address, created_at, seconds), created_at: created_at,
                 random: RANDOM)
  end

  # A record anybody writes at a registry address (it is public): a throwaway key signs it.
  def junk(d, created_at, seed, content = "x")
    Events.sign(Crypto.sha256("throwaway #{seed}".b), ->(_) { "\x00".b * 32 }, created_at: created_at, kind: 30_078,
                                                                               tags: [["d", d]], content: content)
  end

  def relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }

  # Every relay of the key takes `event`.
  def everywhere(event) = relays.each { |relay| relay.take(event) }

  def d_of(address) = Addresses.lease_address(@merchant.registry_key, address)

  def at_d?(event, d) = event["tags"].any? { |name, value| name == "d" && value == d }

  # The kinds of the records of `author` at `d` a relay holds: "lease", "withdrawn" or "unopened".
  def lease_kinds(relay, d, author)
    relay.events.select { |event| event["pubkey"] == author && at_d?(event, d) }.map do |event|
      record = Leases.open_record(event, @merchant.registry_key, d)
      next "unopened" unless record

      record.hold.is_a?(Integer) ? "lease" : record.hold.to_s
    end
  end

  def attempt
    yield
  rescue Sattleme::Checkout::Error => e
    e
  end

  # F1, F2: leases withdrawn or confirmed

  test "F1: a withdrawal on one relay only frees the address there, for another order" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    r1, r2, r3 = relays
    start = @merchant.now
    d = d_of(LOT[0])
    author = sale_of_ref("F1-R").author
    # Another server's short lease of the address reaches every relay right after R's: R's lease
    # is not confirmed. R's withdrawal of it reaches r1 only.
    raced = false
    mutex = Mutex.new
    relays.each do |relay|
      taken = 0
      relay.behaviour = {
        on_event: lambda do |event, _|
          next if event["pubkey"] != author || mutex.synchronize { raced.tap { raced = true } }

          everywhere(lease_by("F1-C", LOT[0], created_at: start, seconds: 60))
        end,
        refuse_event: lambda do |event|
          next nil if relay.equal?(r1) || !(event["pubkey"] == author && at_d?(event, d))

          mutex.synchronize { (taken += 1) > 1 } ? "blocked: rate-limited" : nil
        end
      }
    end
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "F1-R", sats: 49_000) }
    relays.each { |relay| relay.behaviour = {} }
    eventually { lease_kinds(r1, d, author) == ["withdrawn"] }
    assert_equal ["lease"], lease_kinds(r2, d, author)
    assert_equal ["lease"], lease_kinds(r3, d, author)
    # The other lease over; R's still running on r2 and r3.
    @merchant.now = start + 600
    r1.behaviour = { query_delay_ms: 500 }
    again = attempt { client.create_invoice(ref: "F1-R", sats: 49_000) }
    # R's lease was never confirmed: it gives R no address, and still holds it where it is.
    assert_kind_of OnchainUnavailableError, again
    r1.behaviour = {}
    r2.behaviour = { query_delay_ms: 500 }
    other = attempt { client.create_invoice(ref: "F1-D", sats: 49_000) }
    # Read on r1 and r3, R's withdrawal is its newest record: the address is free for D.
    assert_equal LOT[0], other.is_a?(StandardError) ? other : other.onchain_address
  end

  test "F2: an invoice shown and paid keeps its address when the order asks again" do
    @merchant.publish_lot([LOT[0], LOT[1]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    r1 = relays[0]
    sattleme = client
    a = sattleme.create_invoice(ref: "F2-A", sats: 49_000, duration_seconds: 900)
    x = a.onchain_address
    @merchant.chain.add(x, TestChain.payment(TestChain.txid("F2 pays"), x, 49_000))
    status = sattleme.get_status(a)
    assert_equal %w[unconfirmed 49000], [status.state, status.received]
    # Another server's lease of x, its withdrawal on r1 only (a blip).
    b = sale_of_ref("F2-B")
    everywhere(lease_by("F2-B", x, created_at: @merchant.now + 1))
    r1.take(Leases.withdrawal_event(sale: b, address: x, created_at: @merchant.now + 2, random: RANDOM))
    @merchant.now += 30
    r1.behaviour = { query_delay_ms: 500 }
    again = attempt { sattleme.create_invoice(ref: "F2-A", sats: 49_000, duration_seconds: 900) }
    assert_kind_of InvoicePendingError, again
    assert_equal x, again.invoice.onchain_address
  end

  # G3: a flood at a lease's d tag keeps the address only while it lasts

  test "G3: the lease the flood kept from being confirmed is withdrawn" do
    @merchant.publish_lot([LOT[0]], 91)
    # On-chain only: no address, no invoice.
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    d = d_of(LOT[0])
    author = sale_of_ref("G3-1").author
    # Whoever watches the relays sees the new lease, and fills its d tag at once: 101 records of one
    # second, so that no read of it is complete.
    flooded = false
    mutex = Mutex.new
    flood = lambda do |event, _|
      next if event["pubkey"] != author || mutex.synchronize { flooded.tap { flooded = true } }

      101.times { |i| everywhere(junk(d, @merchant.now, i)) }
    end
    relays.each { |relay| relay.behaviour = { on_event: flood } }
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "G3-1", sats: 49_000) }
    assert flooded
    relays.each { |relay| eventually { lease_kinds(relay, d, author) == ["withdrawn"] } }
    # The flood over (its records gone): the address is free at once, not at the lease's end.
    junk_authors = relays[0].events.select { |e| at_d?(e, d) }.map { |e| e["pubkey"] }
    junk_authors.delete(author)
    relays.each { |relay| relay.behaviour = { hide: ->(e) { junk_authors.include?(e["pubkey"]) } } }
    assert_equal LOT[0], client.create_invoice(ref: "G3-2", sats: 49_000).onchain_address
  end

  # G4: a mark a minority took brings back an invoice never shown

  test "G4: of two invoices that may still be paid, the one shown and paid wins" do
    @merchant.publish_lot([LOT[0], LOT[1]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    r1, r2, r3 = relays
    author = sale_of_ref("G4-R").author
    # The lease's mark (its second record) reaches r1 only: NetworkError, nothing shown.
    first = nil
    mutex = Mutex.new
    [r2, r3].each do |relay|
      taken = 0
      relay.behaviour = {
        refuse_event: lambda do |event|
          next nil unless event["pubkey"] == author

          d = event["tags"].find { |tag| tag[0] == "d" }&.[](1) || ""
          mutex.synchronize do
            first ||= d
            d == first && (taken += 1) > 1 ? "blocked: rate-limited" : nil
          end
        end
      }
    end
    sattleme = client
    assert_raises(NetworkError) { sattleme.create_invoice(ref: "G4-R", sats: 49_000) }
    # Asked again while r1 is slow: its lease reads as not confirmed, so another invoice is made,
    # shown and paid.
    r2.behaviour = {}
    r3.behaviour = {}
    r1.behaviour = { query_delay_ms: 500 }
    shown = sattleme.create_invoice(ref: "G4-R", sats: 49_000)
    refute_nil shown.onchain_address
    r1.behaviour = {}
    t = TestChain.payment(TestChain.txid("G4 shown"), shown.onchain_address, 49_000)
    @merchant.chain.add(shown.onchain_address, t)
    assert_predicate sattleme.get_status(shown), :unconfirmed?
    @merchant.chain.confirm(shown.onchain_address, t["txid"], @merchant.chain.height - 5)
    # Asked again, every relay answering: the first invoice is confirmed on r1, older, and may
    # still be paid; the order was paid with the one shown.
    again = attempt { sattleme.create_invoice(ref: "G4-R", sats: 49_000) }
    assert_kind_of OrderPaidError, again
    assert_equal shown.onchain_address, again.invoice.onchain_address
  end

  # H1: two calls of one order at once (its lock failed)

  # A WebSocket client whose writes of events reach the relays 300 ms late.
  class SlowWrites
    def initialize(inner)
      @inner = inner
    end

    def connect(url, **)
      Session.new(@inner.connect(url, **))
    end

    # A session of the inner client, its EVENT messages sent late.
    class Session
      def initialize(inner)
        @inner = inner
      end

      def send_text(text)
        return @inner.send_text(text) unless text.start_with?('["EVENT"')

        thread = Thread.new do
          sleep 0.3
          @inner.send_text(text)
        rescue StandardError
          # Closed meanwhile.
          nil
        end
        thread.report_on_exception = false
        nil
      end

      def receive = @inner.receive

      def close = @inner.close
    end
  end

  test "H1: the call that loses never ends the lease of the one that won" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    d = d_of(LOT[0])
    author = sale_of_ref("H1-R").author
    c = @merchant.now
    # Once the winner's mark (created_at c + 1) is kept, two seconds pass.
    relays.each do |relay|
      relay.behaviour = {
        on_event: lambda do |event, _|
          @merchant.now = c + 2 if event["pubkey"] == author && event["created_at"] == c + 1 && at_d?(event, d)
        end
      }
    end
    calls = [client(websocket_client: SlowWrites.new(@merchant.net.websocket_client)), client].map do |caller|
      Thread.new { attempt { caller.create_invoice(ref: "H1-R", sats: 49_000) } }
    end
    loser, winner = calls.map(&:value)
    relays.each { |relay| relay.behaviour = {} }
    assert_kind_of OnchainUnavailableError, loser
    assert_equal LOT[0], winner.onchain_address
    # The winner's mark stays the order's newest record there, on every relay.
    relays.each { |relay| eventually { lease_kinds(relay, d, author) == ["lease"] } }
    @merchant.now = c + 30
    # Another order gets no address; the order's invoice is still the one handed out.
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "H1-D", sats: 49_000) }
    again = attempt { client.create_invoice(ref: "H1-R", sats: 49_000) }
    assert_kind_of InvoicePendingError, again
    assert_equal LOT[0], again.invoice.onchain_address
  end

  # H2: of two invoices that may still be paid, the one shown is handed out

  # Call 1 (its server's clock `skew` s ahead): its mark reaches r1 only, NetworkError. Call 2 (r1
  # slow) makes and shows another invoice. Call 3 (r2 slow) reads both.
  def two_pending(skew)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    x, y = LOT
    @merchant.publish_lot([x], 91)
    r1, r2, r3 = relays
    author = sale_of_ref("H2-R").author
    c1 = @merchant.now + skew
    refuse = { refuse_event: ->(event) { event["pubkey"] == author && event["created_at"] > c1 ? "error: down" : nil } }
    r2.behaviour = refuse
    r3.behaviour = refuse
    assert_raises(NetworkError) { client(now: -> { @merchant.now + skew }).create_invoice(ref: "H2-R", sats: 49_000) }
    @merchant.publish_lot([x, y], 92)
    r2.behaviour = {}
    r3.behaviour = {}
    r1.behaviour = { query_delay_ms: 500 }
    shown = client.create_invoice(ref: "H2-R", sats: 49_000)
    assert_equal y, shown.onchain_address
    r1.behaviour = {}
    r2.behaviour = { query_delay_ms: 500 }
    again = attempt { client.create_invoice(ref: "H2-R", sats: 49_000) }
    assert_kind_of InvoicePendingError, again
    assert_equal shown.onchain_address, again.invoice.onchain_address
  end

  test "H2: the failed call's server's clock 3 s ahead" do
    two_pending(3)
  end

  test "H2: both of one second, the one never shown sorting last" do
    two_pending(0)
  end

  # I1: a relay counts for a record only with a copy of it

  test "I1: an object that only carries the id of the mark never shown counts for nothing" do
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    x, y = LOT
    @merchant.publish_lot([x], 91)
    r1, r2, r3 = relays
    author = sale_of_ref("I1-R").author
    # Once every relay received the `count` records of the order a call sent it (taken or refused):
    # a relay past a publication's majority may still be on its way after the call returned, and
    # would meet the behaviour of the next call.
    sent_to_all = lambda do |count|
      eventually { relays.all? { |relay| relay.received.count { |event| event["pubkey"] == author } == count } }
    end
    c = @merchant.now
    # Call 1 (on-chain only: 49 000 sats are beyond the Lightning address's bounds): its lease of x
    # everywhere, its mark on r1 only, NetworkError.
    later = { refuse_event: ->(event) { event["pubkey"] == author && event["created_at"] > c ? "error: down" : nil } }
    r2.behaviour = later
    r3.behaviour = later
    assert_raises(NetworkError) { client.create_invoice(ref: "I1-R", sats: 49_000) }
    sent_to_all.call(2)
    # Call 2: r1 slow and refusing the order's records; its invoice, on y, is shown.
    @merchant.publish_lot([x, y], 92)
    @merchant.now = c + 30
    r2.behaviour = {}
    r3.behaviour = {}
    r1.behaviour = { query_delay_ms: 500, refuse_event: ->(event) { event["pubkey"] == author ? "error: down" : nil } }
    shown = client.create_invoice(ref: "I1-R", sats: 49_000)
    assert_equal y, shown.onchain_address
    # Its lease and its mark of y.
    sent_to_all.call(4)
    at = ->(relay, address) { relay.events.find { |e| e["pubkey"] == author && at_d?(e, d_of(address)) } }
    mark_x = at.call(r1, x)
    mark_y = at.call(r2, y)
    confirmed = ->(event) { event && Leases.open_sale_lease(event, sale_of_ref("I1-R"))[:lease].terms.confirmed? }
    # r1 holds x's mark and nothing of y; r2 x's lease and y's mark (r3 too, and hides y's mark now).
    assert_equal [true, nil, false, true],
                 [confirmed.call(mark_x), at.call(r1, y), confirmed.call(at.call(r2, x)), confirmed.call(mark_y)]
    # Call 3: r3 hides y's mark, and sends an object that only carries x's mark's id. It answers
    # late, so that the read of the order's invoices goes on with r1 and r2, which find both (x of
    # call 1, never shown, and y), and its read on every relay (which waits for r3 a relay timeout at
    # most) holds what r3 sends: neither mark held by a majority, the newer one, y, is handed out.
    # Were the object a copy of x's mark, x would be held by r1 and r3, and handed out.
    r1.behaviour = {}
    r3.behaviour = { query_delay_ms: 200, hide: ->(event) { event["id"] == mark_y["id"] } }
    r3.store(mark_x.merge("content" => "not the event", "sig" => "00" * 64))
    @merchant.now = c + 60
    again = attempt { client.create_invoice(ref: "I1-R", sats: 49_000) }
    assert_kind_of InvoicePendingError, again
    assert_equal y, again.invoice.onchain_address
  end

  # S6 (witnesses): a relay hides another order's witness

  test "S6: the witnesses read again on every relay still show it: the transaction counts for nothing" do
    @merchant.publish_lot([LOT[0]], 91)
    sattleme = client(relay_timeout_ms: 4000)
    p = sattleme.create_invoice(ref: "W6-P", sats: 49_000)
    x = p.onchain_address
    t = TestChain.payment(TestChain.txid("W6 paid once"), x, 49_000)
    # Another order's witness of t, in time for it: on r1 (which hides it) and r2 (late), not r3.
    seen = Derive.seen_keys(@merchant.integration_key)
    other = sale_of_ref("W6-N").author
    witness = Records.seal(
      type: "integration-onchain-seen",
      value: { "version" => 1, "address" => x, "txid" => t["txid"], "sale" => other, "sats" => 49_000,
               "inputs" => t["vin"].map { |input| "#{input["txid"]}:#{input["vout"]}" }, "replacement" => false,
               "expiresAt" => p.expires_at },
      signer: seen.secret_key, encryption_key: seen.encryption_key,
      address: Witnesses.witness_address(seen.address_key, x, t["txid"], other), created_at: @merchant.now,
      random: RANDOM,
      tags: [["o", Witnesses.order_tag(seen.address_key, x, other)], ["o", Witnesses.address_tag(seen.address_key, x)]]
    )
    r1, r2 = relays
    r1.take(witness)
    r2.take(witness)
    r1.behaviour = { hide: ->(event) { event["id"] == witness.id } }
    r2.behaviour = { query_delay_ms: 1500 }
    @merchant.chain.add(x, t)
    # The first read (r1 and r3) misses it, so this check publishes its own witness; read again on
    # every relay, r2 shows the other's: t is another invoice's, and counts for nothing here.
    status = sattleme.get_status(p)
    assert_equal %w[open 0], [status.state, status.received]
  end

  # R6: a relay that failed is waited for once per call

  test "R6: two confirmations on every relay, one relay mute: one timeout in all" do
    @merchant.publish_lot([LOT[0], LOT[1]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    r1, r2, r3 = relays
    author = sale_of_ref("R6-R").author
    # Each lease of the order meets another server's lease of its address at once: not confirmed.
    competing = {}
    mutex = Mutex.new
    [r1, r2].each do |relay|
      relay.behaviour = {
        on_event: lambda do |event, _|
          d = event["tags"].find { |tag| tag[0] == "d" }&.[](1)
          next if event["pubkey"] != author || d.nil?
          next if mutex.synchronize { competing.key?(d).tap { competing[d] = true } }

          address = LOT.find { |candidate| d_of(candidate) == d }
          lease = lease_by("R6-OTHER-#{address}", address)
          r1.take(lease)
          r2.take(lease)
        end
      }
    end
    r3.behaviour = { mute: true }
    started = Clock.now
    assert_raises(OnchainUnavailableError) { client(relay_timeout_ms: 2000).create_invoice(ref: "R6-R", sats: 49_000) }
    elapsed = Clock.now - started
    assert_equal 2, competing.size
    # The first confirmation waits for r3 until its timeout; the second counts it failed at once: one
    # timeout, never two (4 s).
    assert_operator elapsed, :<, 3.5
  end

  # R7: a read on every relay keeps the pages a relay sent before the cut

  test "R7: a relay that holds the lease, still paging at the cut, still shows it" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    d = d_of(LOT[0])
    _, h, r2 = relays
    # Anybody's records at the address's d tag, older than the lease: 20 pages to read.
    1950.times { |i| everywhere(junk(d, @merchant.now - 10 - i, i)) }
    lease = lease_by("R7-A", LOT[0])
    # r1 missed the lease; h hides it; r2 answers each page in 150 ms, its 20 pages outlasting the
    # one timeout the read waits after a majority.
    h.take(lease)
    r2.take(lease)
    h.behaviour = { hide: ->(event) { event["id"] == lease.id } }
    r2.behaviour = { query_delay_ms: 150 }
    assert_raises(OnchainUnavailableError) { client(relay_timeout_ms: 1000).create_invoice(ref: "R7-D", sats: 49_000) }
  end

  # L1, L2: a lease not confirmed beside another call's mark (the order's lock failed)

  # The mark of another call of the order `ref`: its lease of `address` at `c`, confirmed at c + 1.
  def mark_of(ref, address, created_at)
    Leases.event(sale: sale_of_ref(ref), terms: terms_of(ref, address, created_at, 900, sats: 49_000, confirmed: true),
                 created_at: created_at + 1, random: RANDOM)
  end

  # The withdrawals of `author` at `d` the relays received.
  def withdrawals(d, author)
    relays.flat_map do |relay|
      relay.received.select do |event|
        event["pubkey"] == author && Leases.open_record(event, @merchant.registry_key, d)&.hold == :withdrawn
      end
    end
  end

  test "L1: fewer than a majority answer the confirmation, the minority showing the mark: not withdrawn" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    d = d_of(LOT[0])
    author = sale_of_ref("L1-R").author
    mark = mark_of("L1-R", LOT[0], @merchant.now)
    r1, r2, r3 = relays
    # Once this call's lease is taken, the other call's mark is everywhere, and r2 and r3 answer
    # reads too late (their writes at once).
    marked = false
    mutex = Mutex.new
    on_event = lambda do |event, _|
      next if event["pubkey"] != author || mutex.synchronize { marked.tap { marked = true } }

      everywhere(mark)
      r2.behaviour = { query_delay_ms: 5000 }
      r3.behaviour = { query_delay_ms: 5000 }
    end
    relays.each { |relay| relay.behaviour = { on_event: on_event } }
    assert_raises(NetworkError) { client.create_invoice(ref: "L1-R", sats: 49_000) }
    relays.each { |relay| relay.behaviour = {} }
    # r1 showed the mark: no withdrawal, which could have replaced it (same second, a lower id).
    assert_empty withdrawals(d, author)
    [r1, r2, r3].each { |relay| assert_equal ["lease"], lease_kinds(relay, d, author) }
    @merchant.now += 30
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "L1-D", sats: 49_000) }
  end

  test "L2: a copy of the mark with a damaged signature, sent first, hides no valid copy" do
    @merchant.publish_lot([LOT[0]], 91)
    @merchant.pay = @merchant.pay.merge("maxSendable" => 1_000_000)
    d = d_of(LOT[0])
    author = sale_of_ref("L2-R").author
    mark = mark_of("L2-R", LOT[0], @merchant.now)
    damaged = mark.to_h.merge("sig" => (mark.sig[0] == "0" ? "1" : "0") + mark.sig[1..])
    r1, r2, r3 = relays
    # r1 sends the damaged copy alone, first; r2 and r3 the valid one, 100 ms later.
    marked = false
    mutex = Mutex.new
    on_event = lambda do |event, _|
      next if event["pubkey"] != author || mutex.synchronize { marked.tap { marked = true } }

      everywhere(mark)
      r1.store(damaged)
      r1.behaviour = { hide: ->(e) { e["id"] == mark.id && e["sig"] == mark.sig } }
      r2.behaviour = { query_delay_ms: 100 }
      r3.behaviour = { query_delay_ms: 100 }
    end
    relays.each { |relay| relay.behaviour = { on_event: on_event } }
    assert_raises(OnchainUnavailableError) { client.create_invoice(ref: "L2-R", sats: 49_000) }
    relays.each { |relay| relay.behaviour = {} }
    assert_empty withdrawals(d, author)
    [r2, r3].each { |relay| assert_equal ["lease"], lease_kinds(relay, d, author) }
  end

  # L3: a complete read, a full page whose only new event has no usable date

  test "L3: asks the page again once (an event not seen before, dated or not), then stops incomplete" do
    seen = {}
    kept = []
    page = ->(events) { events.map { |event| Relay.entry_of(event, ->(value) { value }) } }
    first = Array.new(100) { |i| { "id" => "a#{i}", "created_at" => 1000 } }
    assert_equal [:until, 1000], Relay.after_complete_page(page.call(first), seen, kept, 1)
    second = first.first(99) + [{ "id" => "new", "created_at" => 2**60 }]
    # SPEC.md §13: a new event, undated, lets the read go on from the dated ones.
    assert_equal [:until, 1000], Relay.after_complete_page(page.call(second), seen, kept, 2)
    # The same page again brings nothing new: incomplete, never a loop.
    assert_equal [:complete, false], Relay.after_complete_page(page.call(second), seen, kept, 3)
    # Kept all the same, once.
    assert_equal 101, kept.size
  end
end
