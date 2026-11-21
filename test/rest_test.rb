# frozen_string_literal: true

require_relative "test_helper"

# The rest of an on-chain underpayment (SPEC.md §31, "The rest of an underpayment"), end to end
# against local relays and fakes of breez.tips and of the explorers: the invoice of the rest asked
# by a payment check, declared with `rest` and published in a rest record that a checkout link's
# page reads; asked once, never without time left nor outside the Lightning address's bounds; a
# failure only logged; what the rest invoices paid counted with the on-chain payment (`mixed`).
class RestTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"
  ADDRESS = TestChain.deposit_address(1)

  def setup
    @logger = TestLogger.new
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(
      @merchant.channel_value(100, "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN }), 100
    )
    @merchant.publish_lot([ADDRESS], 90)
    @client = client
    @invoice = @client.create_invoice(ref: "R-1", sats: 49_000, duration_seconds: 600, note: "Order 1", checkout: true)
    raise "The order got no deposit address" unless @invoice.onchain_address == ADDRESS
  end

  def teardown
    @merchant.stop
  end

  def client
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: @logger)
  end

  def warnings = @logger.messages

  def relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }

  # The events the first relay holds now.
  def held = relays[0].events

  def sale_of_ref(ref)
    Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader), ref)
  end

  # The declarations of the sale of `ref` the first relay holds, opened as the sale.
  def declarations(ref)
    sale = sale_of_ref(ref)
    held.filter_map { |event| Declarations.open(event, sale) }
  end

  # The rest records of `invoice` the first relay holds, as a checkout link's page opens them.
  def rest_records(invoice)
    keys = Derive.rest_keys(@merchant.integration_key, invoice.ref, invoice.onchain_address, invoice.expires_at)
    terms = Rests::LinkTerms.new(sats: Integer(invoice.sats, 10), created_at: invoice.created_at,
                                 expires_at: invoice.expires_at)
    held.filter_map do |event|
      opened = Rests.open_record(event, keys, terms)
      opened.invoice if opened.is_a?(Rests::OpenedRest)
    end
  end

  # The invoices breez.tips made of `sats`.
  def made_of(sats) = @merchant.made_invoices.select { |made| made.amount_msat == sats * 1000 }

  def pay_part(id, sats) = @merchant.chain.add(ADDRESS, TestChain.payment(TestChain.txid(id), ADDRESS, sats))

  # An on-chain underpayment

  test "asks an invoice of the rest, declares it with `rest` and publishes its record" do
    @merchant.now += 60
    pay_part("part", 20_000)
    status = @client.get_status(@invoice)
    made = made_of(29_000)[0]
    refute_nil made
    rest = { "sats" => "29000", "bolt11" => made.pr,
             "paymentUri" => "bitcoin:#{ADDRESS}?amount=0.00029&lightning=#{made.pr}" }
    assert_equal({ "state" => "open", "expiresAt" => @invoice.expires_at, "received" => "20000", "rest" => rest },
                 status.to_h)
    # Until the invoice's end, with the order's note.
    assert_equal @invoice.expires_at - @merchant.now, made.expiry
    assert_equal "Order 1", made.comment
    # Declared for the order's sale, with the order's price and note, marked as a rest.
    eventually do
      declarations("R-1").any? do |declaration|
        declaration.invoice == made.pr && declaration.note == "Order 1" &&
          declaration.rest == Declarations::RestOf.new(address: ADDRESS, expires_at: @invoice.expires_at)
      end
    end
    # Its record, which the checkout link's page reads with the keys its link's record carries.
    records = eventually { rest_records(@invoice).then { |found| !found.empty? && found } }
    assert_equal([[made.pr, 29_000, made.verify]], records.map do |record|
      [record.bolt11, record.sats, record.verify_url]
    end)
    link = CheckoutLinks.parse_fragment(@invoice.checkout_url[@invoice.checkout_url.index("#")..])
    keys = CheckoutLinks.keys(link.link_key)
    event = eventually { held.find { |e| e["tags"].any? { |name, d| name == "d" && d == keys.address } } }
    value = Json.parse(Nip44.decrypt(event["content"], keys.encryption_key))["v"]
    rest = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    assert_equal [rest.author, rest.key], CheckoutLinks.parse_value(value).rest
    # The rest invoice is no invoice of the order.
    assert_equal([[@invoice.bolt11, ADDRESS]],
                 @client.find_invoices("R-1").map { |found| [found.bolt11, found.onchain_address] })
    assert_empty warnings
  end

  test "decides on an invoice of the rest by the clock read then: its expiry, its checks and its records too" do
    pay_part("part", 20_000)
    deciding = nil
    # The Lightning address answers its pay request 30 s later.
    @merchant.override = lambda do |url|
      if url.to_s == TestMerchant::PAY_URL && deciding.nil?
        deciding = @merchant.now
        @merchant.now += 30
      end
      nil
    end
    status = @client.get_status(@invoice)
    made = made_of(29_000)[0]
    assert_equal made.pr, status.rest.bolt11
    assert_equal @invoice.expires_at - deciding, made.expiry
    keys = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    declaration = eventually { declarations("R-1").find { |opened| opened.invoice == made.pr } }
    d = Derive.rest_record_address(keys.key, made.payment_hash)
    record = eventually { held.find { |event| event["tags"][0] == ["d", d] } }
    assert_equal [deciding, deciding], [declaration.event.created_at, record["created_at"]]
  end

  test "is asked by create_invoice's check of the order's pending invoice, before invoice_pending" do
    @merchant.now += 60
    pay_part("part", 20_000)
    # Its payment checked, alone (SPEC.md §21 step 1): as any payment check, it asks for the rest.
    pending = assert_raises(InvoicePendingError) { @client.create_invoice(ref: "R-1", sats: 49_000, checkout: true) }
    assert_equal ADDRESS, pending.invoice.onchain_address
    made = made_of(29_000)[0]
    refute_nil made
    eventually do
      declarations("R-1").any? do |declaration|
        declaration.invoice == made.pr &&
          declaration.rest == Declarations::RestOf.new(address: ADDRESS, expires_at: @invoice.expires_at)
      end
    end
    # Its record, for the pages of the order's checkout links (the new one included).
    eventually { rest_records(@invoice).map(&:bolt11) == [made.pr] }
    # Shown by the next check, never asked again.
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    assert_equal [made], made_of(29_000)
    assert_empty warnings
  end

  test "asks it once, and again for a new rest" do
    pay_part("part", 20_000)
    first = @client.get_status(@invoice)
    assert_equal first, client.get_status(@invoice)
    assert_equal 1, made_of(29_000).size
    # More sent on-chain: a new rest, a new invoice of it.
    pay_part("more", 10_000)
    second = @client.get_status(@invoice)
    assert_equal %w[30000 19000], [second.received, second.rest.sats]
    assert_equal 1, made_of(19_000).size
    eventually { rest_records(@invoice).map(&:sats).sort == [19_000, 29_000] }
  end

  test "is Lightning only below 1 000 sats" do
    pay_part("part", 48_500)
    status = @client.get_status(@invoice)
    made = made_of(500)[0]
    assert_equal ["open", "48500", { "sats" => "500", "bolt11" => made.pr, "paymentUri" => "lightning:#{made.pr}" }],
                 [status.state, status.received, status.rest.to_h]
  end

  test "asks none with less than a minute left, nor outside the Lightning address's bounds" do
    pay_part("part", 20_000)
    @merchant.now = @invoice.expires_at - 59
    assert_equal({ "sats" => "29000", "bolt11" => nil, "paymentUri" => "bitcoin:#{ADDRESS}?amount=0.00029" },
                 @client.get_status(@invoice).rest.to_h)
    @merchant.now = @invoice.expires_at - 600
    pay = @merchant.pay
    @merchant.pay = pay.merge("maxSendable" => 28_000_000)
    assert_nil @client.get_status(@invoice).rest.bolt11
    @merchant.pay = pay.merge("minSendable" => 29_001_000)
    assert_nil @client.get_status(@invoice).rest.bolt11
    assert_empty made_of(29_000)
    assert_empty warnings
    # Past the end, no rest at all.
    @merchant.now = @invoice.expires_at
    status = @client.get_status(@invoice)
    assert_equal ["open", nil], [status.state, status.rest]
  end

  test "logs a Lightning address that fails, and asks again at the next check" do
    pay_part("part", 20_000)
    @merchant.override = lambda do |url|
      FakeHttp.answer({ "oops" => true }, 500) if "#{url.scheme}://#{url.host}#{url.path}" == TestMerchant::CALLBACK
    end
    status = @client.get_status(@invoice)
    assert_equal ["open", nil], [status.state, status.rest.bolt11]
    assert_equal 1, warnings.size
    assert_match(/no Lightning invoice of the rest/, warnings[0])
    @merchant.override = nil
    again = @client.get_status(@invoice)
    assert_equal made_of(29_000).last.pr, again.rest.bolt11
  end

  test "asks no invoice of the rest of a pay request whose metadata holds a lone surrogate, logged, the status given" do
    pay_part("part", 20_000)
    # From now on, the Lightning address's metadata has no UTF-8 to hash (SPEC.md §6, §16).
    @merchant.pay = @merchant.pay.merge("metadata" => Json.parse('"[[\\"text/plain\\",\\"Pay \\ud800\\"]]"'))
    status = @client.get_status(@invoice)
    assert_equal ["open", "20000", "29000", nil], [status.state, status.received, status.rest.sats, status.rest.bolt11]
    assert_empty made_of(29_000)
    assert_equal 1, warnings.size
    assert_match(/no Lightning invoice of the rest .*no valid LNURL-pay request/, warnings[0])
  end

  test "refuses an invoice that does not pay the merchant, logged" do
    pay_part("part", 20_000)
    @merchant.tamper = ->(made) { { pr: made.pr.sub(/.{8}\z/, "qqqqqqqq") } }
    assert_nil @client.get_status(@invoice).rest.bolt11
    assert_equal 1, warnings.size
    assert_empty(declarations("R-1").reject { |declaration| declaration.rest.nil? })
  end

  test "checks an invoice of the rest another check asked meanwhile" do
    pay_part("part", 20_000)
    # Paid as soon as it is made: the check that waited for the other finds it paid.
    @merchant.tamper = lambda do |made|
      @merchant.pay_invoice(made.payment_hash)
      {}
    end
    first, second = Array.new(2) { Thread.new { @client.get_status(@invoice) } }.map(&:value).sort_by(&:state)
    assert_equal 1, made_of(29_000).size
    assert_equal ["open", made_of(29_000)[0].pr], [first.state, first.rest.bolt11]
    assert_equal %w[unconfirmed 49000], [second.state, second.received]
  end

  test "declares again on a majority an invoice of the rest a minority holds, before it is used" do
    pay_part("part", 20_000)
    sale = sale_of_ref("R-1")
    a, b, c = relays
    refuse = ->(event) { event["pubkey"] == sale.author ? "blocked" : nil }
    # Its declaration reaches one relay of three: not to be shown.
    b.behaviour = b.behaviour.merge(refuse_event: refuse)
    c.behaviour = c.behaviour.merge(refuse_event: refuse)
    assert_nil @client.get_status(@invoice).rest.bolt11
    assert_equal 1, warnings.size
    made = made_of(29_000)[0]
    # Still refused: read on the relay that holds it (the second one silent, so that the read goes
    # on with the first and the third, whatever the machine's load), it cannot be declared on a
    # majority, so nothing is told of the rest (and no other invoice of it is asked).
    b.behaviour = b.behaviour.merge(mute_query: ->(_filter) { true })
    assert_raises(NetworkError) { @client.get_status(@invoice) }
    assert_equal [made], made_of(29_000)
    # Taken again, the third relay slow: read on the first two, declared on a majority, shown.
    b.behaviour = b.behaviour.except(:refuse_event, :mute_query)
    c.behaviour = c.behaviour.except(:refuse_event).merge(query_delay_ms: 500)
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    declared = lambda do |relay|
      relay.events.any? do |event|
        event["pubkey"] == sale.author && Declarations.open(event, sale)&.decoded&.payment_hash == made.payment_hash
      end
    end
    eventually { [a, b, c].count { |relay| declared.call(relay) } >= 2 }
    # Paid, then read without the first relay: still counted, never asked again.
    @merchant.pay_invoice(made.payment_hash)
    c.behaviour = c.behaviour.except(:query_delay_ms)
    a.behaviour = a.behaviour.merge(query_delay_ms: 500)
    status = @client.get_status(@invoice)
    assert_equal %w[unconfirmed 49000], [status.state, status.received]
    assert_equal [made], made_of(29_000)
  end

  test "shows an invoice of the rest only once its record is on a majority of the relays" do
    pay_part("part", 20_000)
    author = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at).author
    recorded_on = -> { relays.count { |relay| relay.events.any? { |event| event["pubkey"] == author } } }
    # Its record taken by one relay of three: a checkout link's page reading the other two would
    # not see it, nor its payment. Declared, never shown.
    relays.drop(1).each do |relay|
      relay.behaviour = relay.behaviour.merge(refuse_event: lambda { |event|
        event["pubkey"] == author ? "blocked: not now" : nil
      })
    end
    assert_equal({ "sats" => "29000", "bolt11" => nil, "paymentUri" => "bitcoin:#{ADDRESS}?amount=0.00029" },
                 @client.get_status(@invoice).rest.to_h)
    eventually { recorded_on.call == 1 }
    assert_match(/record of an invoice of the rest was not published/, warnings[0])
    # Still refused: still not shown, never asked again.
    assert_nil @client.get_status(@invoice).rest.bolt11
    made = made_of(29_000)[0]
    assert_equal [made], made_of(29_000)
    # Taken: published again on a majority at the next check, shown.
    relays.each { |relay| relay.behaviour = relay.behaviour.except(:refuse_event) }
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    assert_operator recorded_on.call, :>=, 2
    assert_equal [made], made_of(29_000)
  end

  test "shows an invoice of the rest whose record a majority took in the check, though fewer than a majority answer the read of rest records" do
    pay_part("part", 20_000)
    author = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at).author
    # Two relays of three take its record, then stall on the read of the rest records.
    stall = ->(filter) { filter["authors"]&.include?(author) == true && filter["#d"].nil? }
    relays.drop(1).each { |relay| relay.behaviour = relay.behaviour.merge(mute_query: stall) }
    status = @client.get_status(@invoice)
    made = made_of(29_000)[0]
    assert_equal ["29000", made.pr], [status.rest.sats, status.rest.bolt11]
    eventually { rest_records(@invoice).size == 1 }
    # The next check, which took nothing, cannot tell: not shown until a majority answers.
    assert_nil @client.get_status(@invoice).rest.bolt11
    relays.each { |relay| relay.behaviour = relay.behaviour.except(:mute_query) }
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    assert_equal [made], made_of(29_000)
  end

  test "publishes no rest record again when fewer than a majority answer their read, and never shows its invoice" do
    pay_part("part", 20_000)
    author = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at).author
    # Its record taken by one relay of three: to be published again at a check that reads them.
    relays.drop(1).each do |relay|
      relay.behaviour = relay.behaviour.merge(refuse_event: lambda { |event|
        event["pubkey"] == author ? "blocked: not now" : nil
      })
    end
    assert_nil @client.get_status(@invoice).rest.bolt11
    made = made_of(29_000)[0]
    # They take it now, but stall on the read of the rest records: what they hold cannot be told.
    stall = ->(filter) { filter["authors"]&.include?(author) == true && filter["#d"].nil? }
    relays.drop(1).each do |relay|
      relay.behaviour = relay.behaviour.except(:refuse_event).merge(mute_query: stall)
    end
    # Every publication goes to every relay: once each has the same count, none is on its way.
    sent = -> { relays.map { |relay| relay.received.count { |event| event["pubkey"] == author } } }
    before = eventually { sent.call.then { |counts| counts.uniq.size == 1 && counts } }
    assert_nil @client.get_status(@invoice).rest.bolt11
    # Nothing published again, on any relay; the invoice not shown, never asked again.
    assert_equal before, sent.call
    assert_equal [made], made_of(29_000)
    # A majority answers: published again on a majority, shown.
    relays.each { |relay| relay.behaviour = relay.behaviour.except(:mute_query) }
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    eventually { relays.count { |relay| relay.events.any? { |event| event["pubkey"] == author } } >= 2 }
  end

  test "never writes a rest record over one of a newer format at its address, which holds it, and warns of it" do
    pay_part("part", 20_000)
    keys = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    # Its record taken by one relay of three: to be published again at the next check.
    relays.drop(1).each do |relay|
      relay.behaviour = relay.behaviour.merge(refuse_event: lambda { |event|
        event["pubkey"] == keys.author ? "blocked: not now" : nil
      })
    end
    assert_nil @client.get_status(@invoice).rest.bolt11
    made = made_of(29_000)[0]
    # Meanwhile a newer version wrote that invoice's record, in a format this one cannot read.
    tags = [["d", Derive.rest_record_address(keys.key, made.payment_hash)],
            ["expiration", (@invoice.expires_at + 604_800).to_s]]
    newer = Events.sign(keys.secret_key, SecureRandom.method(:random_bytes),
                        created_at: @merchant.now + 1, kind: 30_078, tags: tags, content: "#")
    relays.each do |relay|
      relay.take(newer)
      relay.behaviour = relay.behaviour.except(:refuse_event)
    end
    @merchant.now += 1
    # What the next check writes as the rest author: nothing.
    written = lambda do
      relays.sum do |relay|
        relay.received.count { |event| event["pubkey"] == keys.author && event["created_at"] >= @merchant.now }
      end
    end
    logged = warnings.size
    # It holds the address: the invoice is shown, its record never written over.
    assert_equal made.pr, @client.get_status(@invoice).rest.bolt11
    assert_equal 0, written.call
    assert(relays.all? { |relay| relay.events.any? { |event| event["id"] == newer.id } })
    assert_equal ["sattleme-checkout: a record of an invoice of the rest has a newer format than this version " \
                  "reads; update the gem"], warnings.drop(logged)
    assert_equal [made], made_of(29_000)
  end

  # A mixed payment

  # The invoice underpaid on-chain, and the invoice of its rest made by a check.
  def underpaid
    tx = TestChain.payment(TestChain.txid("part"), ADDRESS, 20_000)
    @merchant.chain.add(ADDRESS, tx)
    status = @client.get_status(@invoice)
    rest = @merchant.invoices.fetch(made_of(29_000)[0].payment_hash)
    assert_equal rest.pr, status.rest.bolt11
    [tx, rest]
  end

  test "is unconfirmed once the rest is paid, then paid at 3 confirmations, with the preimage" do
    tx, rest = underpaid
    @merchant.pay_invoice(rest.payment_hash)
    assert_equal({ "state" => "unconfirmed", "received" => "49000", "confirmations" => 0, "txids" => [tx["txid"]] },
                 @client.get_status(@invoice).to_h)
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    @merchant.now = @invoice.expires_at + 3600
    assert_equal({ "state" => "paid", "method" => "mixed", "received" => "49000", "txids" => [tx["txid"]],
                   "preimages" => [rest.preimage] }, @client.get_status(@invoice).to_h)
    # The order is paid: its next invoice is refused, without the preimage of its own invoice.
    error = assert_raises(OrderPaidError) { @client.create_invoice(ref: "R-1", sats: 49_000) }
    assert_nil error.preimage
    assert_equal "mixed", error.status.payment_method
  end

  test "counts a rest paid when the on-chain payment is gone, and expires with all received" do
    tx, rest = underpaid
    @merchant.pay_invoice(rest.payment_hash)
    @merchant.chain.drop(ADDRESS, tx["txid"])
    status = @client.get_status(@invoice)
    assert_equal %w[open 29000 20000], [status.state, status.received, status.rest.sats]
    @merchant.now = @invoice.expires_at + 3600
    assert_equal({ "state" => "expired", "received" => "29000" }, @client.get_status(@invoice).to_h)
  end

  test "never leases the address again for the order once a witness names it, its payment gone" do
    tx, rest = underpaid
    @merchant.pay_invoice(rest.payment_hash)
    # The on-chain payment gone, the explorer shows nothing paid the address; its witness does
    # (SPEC.md §31, "Leasing an address"): the earlier invoice's 29 000 never counts for a new one.
    @merchant.chain.drop(ADDRESS, tx["txid"])
    @merchant.now = @invoice.expires_at + 421
    assert_equal({ "state" => "expired", "received" => "29000" }, @client.get_status(@invoice).to_h)
    following = @client.create_invoice(ref: "R-1", sats: 49_000, duration_seconds: 600)
    assert_nil following.onchain_address
    refute_equal @invoice.bolt11, following.bolt11
  end

  test "lets the order get a new invoice once the invoice and its rest ended unpaid" do
    underpaid
    @merchant.now = @invoice.expires_at + 100
    assert_raises(InvoicePendingError) { @client.create_invoice(ref: "R-1", sats: 49_000) }
    # The rest invoice ended with the invoice: both final 120 s later.
    @merchant.now = @invoice.expires_at + 200
    following = @client.create_invoice(ref: "R-1", sats: 49_000)
    refute_equal @invoice.bolt11, following.bolt11
    # The address was paid: never leased again.
    assert_nil following.onchain_address
  end

  test "is paid by wait_for_payment once the rest is paid, without a push of the explorer" do
    @merchant.start_explorer_socket
    tx, rest = underpaid
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    statuses = Queue.new
    waiting = Thread.new { @client.wait_for_payment(@invoice, interval_ms: 250) { |status| statuses << status } }
    first = statuses.pop(timeout: 5)
    assert_equal %w[open 29000], [first.state, first.rest.sats]
    @merchant.pay_invoice(rest.payment_hash)
    assert_equal({ "state" => "paid", "method" => "mixed", "received" => "49000", "txids" => [tx["txid"]],
                   "preimages" => [rest.preimage] }, waiting.value.to_h)
  end

  test "never ends wait_for_payment on what was due before the rest was paid" do
    tx, rest = underpaid
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    # The rest paid in time, its verify URL failing once past the grace period: the full check
    # (no push of the explorer here, the next one is 60 s later) judges the on-chain part against
    # the whole amount, final, and cannot tell the rest.
    @merchant.pay_invoice(rest.payment_hash)
    @merchant.now = @invoice.expires_at + 121
    failures = 1
    mutex = Mutex.new
    @merchant.override = lambda do |url|
      next nil unless url.to_s == rest.verify

      fail_now = mutex.synchronize { (failures -= 1) >= 0 }
      fail_now ? FakeHttp.answer({ "oops" => true }, 500) : nil
    end
    statuses = []
    # The rest seen paid by the next Lightning check: only a full check, with the 20 000 on-chain
    # all that is due, gives the status (never "expired" with 49 000 received).
    final = @client.wait_for_payment(@invoice, interval_ms: 250) { |status| statuses << status }
    assert_equal({ "state" => "paid", "method" => "mixed", "received" => "49000", "txids" => [tx["txid"]],
                   "preimages" => [rest.preimage] }, final.to_h)
    # Failed once, then read by the Lightning check and by the full check it started.
    assert_equal(-2, failures)
    assert_empty(statuses.select(&:expired?))
  end
end
