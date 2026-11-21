# frozen_string_literal: true

require_relative "test_helper"

# The merchant's acceptance (SPEC.md §31, "The merchant's acceptance"), end to end against local
# relays and fakes of breez.tips and of the explorers: the team's record, read on every relay with
# the witnesses, pays an order underpaid on-chain down to what the merchant accepted, only when a
# majority of the merchant's relays hold it, whichever majority answers; the pages of the order's
# checkout links told by an acceptance record (the server's); the check publishing nothing of it.
class MerchantAcceptanceTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"
  ADDRESS = TestChain.deposit_address(1)
  SATS = 49_000
  # What came on-chain, and what the merchant accepted.
  CAME = 30_000

  def setup
    start(nil, CAME)
  end

  def teardown
    @merchant.stop
  end

  # A merchant whose channel has `tolerance` (nil: none), an order of SATS with its invoice, and a
  # minute later a transaction paying `came` to its address.
  def start(tolerance, came)
    @logger = TestLogger.new
    @merchant = TestMerchant.new.start
    @merchant.publish_lot([ADDRESS], 90)
    extra = { "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN } }
    extra["onchainTolerance"] = tolerance unless tolerance.nil?
    @merchant.publish_channel(@merchant.channel_value(100, extra), 100)
    @client = Client.new(key: @merchant.key, http_client: @merchant.http,
                         websocket_client: @merchant.net.websocket_client, now: -> { @merchant.now },
                         relay_timeout_ms: 1000, logger: @logger)
    @invoice = @client.create_invoice(ref: "R-1", sats: SATS, duration_seconds: 600, note: "Order 1", checkout: true)
    assert_equal ADDRESS, @invoice.onchain_address
    @merchant.now += 60
    @tx = pay("came", came)
  end

  def warnings = @logger.messages

  def pay(id, sats, **options)
    TestChain.payment(TestChain.txid(id), ADDRESS, sats, **options).tap { |tx| @merchant.chain.add(ADDRESS, tx) }
  end

  def relay(index) = @merchant.net.get(@merchant.key_relays[index])

  def sale_author(ref)
    Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader), ref)
          .author
  end

  # Where the merchant's acceptance of the invoice is (or of what `of` changes of it).
  def address_of(of = {})
    Derive.merchant_acceptance_address(@merchant.integration_key, sale_author(of[:ref] || @invoice.ref),
                                       of[:address] || @invoice.onchain_address,
                                       of[:expires_at] || @invoice.expires_at)
  end

  # The merchant's acceptance of the invoice at `received`, as the merchant's app makes it: sealed
  # with the channel's key, signed by the team (or `signer`), dated `created_at` (a minute ago by
  # default), of `value` when given.
  def acceptance(received, created_at: @merchant.now - 60, signer: @merchant.team_secret, value: nil, of: {})
    Records.seal(type: "integration-onchain-accepted", value: value || { "version" => 1, "received" => received },
                 signer: signer, encryption_key: Derive.channel_keys(@merchant.integration_key)[1],
                 address: address_of(of), created_at: created_at, random: SecureRandom.method(:random_bytes)).to_h
  end

  # The relays at `indexes` of the key's (all by default) take `event`, as a relay keeps it.
  def hold(event, indexes = [0, 1, 2])
    indexes.each { |index| relay(index).take(event) }
  end

  # The relays at `indexes` never answer the read of the merchant's acceptance of the invoice.
  def mute_read(indexes)
    address = address_of
    @merchant.key_relays.each_with_index do |url, index|
      @merchant.net.get(url).behaviour = if indexes.include?(index)
                                           { mute_query: ->(filter) { (filter["#d"] || []).include?(address) } }
                                         else
                                           {}
                                         end
    end
  end

  # The acceptance records of the invoice a relay holds, as a checkout link's page opens them. A
  # relay past a publication's majority may take it after the check returned (SPEC.md §13): a test
  # waits until it holds one.
  def acceptance_records(index = 0)
    keys = Derive.rest_keys(@merchant.integration_key, @invoice.ref, ADDRESS, @invoice.expires_at)
    relay(index).events.filter_map do |event|
      opened = Acceptances.open_record(event, keys, SATS)
      opened.received if opened.is_a?(Acceptances::Opened)
    end
  end

  # What the check sent the relays of the team's, or at the merchant's acceptance's address.
  def sent_of_the_team
    address = address_of
    @merchant.key_relays.flat_map do |url|
      @merchant.net.get(url).received.select do |event|
        event["pubkey"] == @merchant.team || event["tags"].any? { |tag| tag[1] == address }
      end
    end
  end

  # The invoices breez.tips made of `sats`.
  def made_of(sats) = @merchant.made_invoices.select { |made| made.amount_msat == sats * 1000 }

  # The status of an order of 49 000 sats with 30 000 in time and the rest asked of 19 000.
  def underpaid
    rest = made_of(SATS - CAME)[0]
    { "state" => "open", "expiresAt" => @invoice.expires_at, "received" => CAME.to_s,
      "rest" => { "sats" => (SATS - CAME).to_s, "bolt11" => rest.pr,
                  "paymentUri" => "bitcoin:#{ADDRESS}?amount=0.00019&lightning=#{rest.pr}" } }
  end

  def unconfirmed(received = CAME)
    { "state" => "unconfirmed", "received" => received.to_s, "confirmations" => 0, "txids" => [@tx["txid"]] }
  end

  def status = @client.get_status(@invoice).to_h

  # A check gives `underpaid` (its rest asked by the check itself).
  def assert_underpaid
    checked = status
    assert_equal underpaid, checked
  end

  # A merchant's acceptance a majority of the relays hold

  test "pays the order down to it: unconfirmed, then paid, the pages told, nothing published of it" do
    hold(acceptance(CAME), [0, 1])
    assert_equal unconfirmed, status
    # No rest asked: the order is paid.
    assert_empty made_of(SATS - CAME)
    # The acceptance record (the server's, for the pages of the order's checkout links), on every
    # relay: what was received, nothing of the merchant's acceptance itself.
    3.times { |index| eventually { acceptance_records(index) == [CAME] } }
    # The merchant's acceptance never published again, nor anything of the team's.
    assert_empty sent_of_the_team
    refute(relay(2).events.any? { |event| event["pubkey"] == @merchant.team && event["tags"] == [["d", address_of]] })

    @merchant.chain.confirm(ADDRESS, @tx["txid"], @merchant.chain.height - 2)
    @merchant.now = @invoice.expires_at + 3600
    paid = { "state" => "paid", "method" => "onchain", "received" => CAME.to_s, "txids" => [@tx["txid"]] }
    assert_equal paid, status
    error = assert_raises(OrderPaidError) { @client.create_invoice(ref: "R-1", sats: SATS) }
    assert_equal paid, error.status.to_h
    assert_empty warnings
  end

  [["the third failing", [0, 1], [2]], ["the first failing, the 2 others holding it", [1, 2], [0]],
   ["every relay answering", [0, 1], []]].each do |name, holders, failing|
    test "counts whichever majority answers: #{name}" do
      hold(acceptance(CAME), holders)
      mute_read(failing)
      assert_equal unconfirmed, status
    end
  end

  test "waits for a relay that holds it and answers late" do
    hold(acceptance(CAME), [0, 1])
    relay(0).behaviour = { query_delay_ms: 400 }
    assert_equal unconfirmed, status
  end

  test "counts one made before the end after the lease's end: never expired" do
    assert_underpaid
    hold(acceptance(CAME, created_at: @invoice.expires_at - 60), [1, 2])
    @merchant.now = @invoice.expires_at + 3600
    assert_equal unconfirmed, status
  end

  test "counts one of less than what came: what came pays" do
    hold(acceptance(20_000))
    assert_equal unconfirmed, status
    eventually { acceptance_records == [CAME] }
  end

  test "asks the whole rest of one of more than what came" do
    hold(acceptance(35_000))
    assert_underpaid
    assert_empty acceptance_records
  end

  # A merchant's acceptance only a minority of the relays holds

  test "never counts one a minority holds, whichever relays answer: the rest asked, then expired" do
    hold(acceptance(CAME), [0])
    assert_underpaid
    # The relay that holds it and one that does not answer: still a minority's.
    mute_read([2])
    assert_underpaid
    mute_read([])
    @merchant.now = @invoice.expires_at + 60
    open = @client.get_status(@invoice)
    assert_equal ["open", nil], [open.state, open.rest]
    @merchant.now = @invoice.expires_at + 3600
    assert_equal({ "state" => "expired", "received" => CAME.to_s }, status)
    assert_empty acceptance_records
  end

  test "is what remains when a relay that holds it fails and the others that do are a minority" do
    # SPEC.md §27: that check does not count it; a later one, which that relay answers, does.
    hold(acceptance(CAME), [0, 1])
    mute_read([0])
    assert_underpaid
    mute_read([])
    assert_equal unconfirmed, status
  end

  test "counts a relay once, whatever copies of it it sends" do
    event = acceptance(CAME)
    # The same event under another signature (BIP-340: any of them verifies): the same record.
    resigned = event.merge("sig" => to_hex(Secp256k1.sign(hex(event["id"]), @merchant.team_secret,
                                                          TestMerchant.bytes(77))))
    refute_equal event["sig"], resigned["sig"]
    relay(0).store(event)
    relay(0).store(event)
    relay(0).store(resigned)
    assert_underpaid
    # The count itself, of what the relays sent (the pool already reads a relay's copies of one id
    # once): one relay, whatever copies it sent; then a second one, a majority.
    keys = MerchantAcceptances.keys(@merchant.integration_key, @merchant.team, sale_author(@invoice.ref), ADDRESS,
                                    @invoice.expires_at)
    terms = MerchantAcceptances::Terms.new(sats: SATS, expires_at: @invoice.expires_at)
    answers = { "a" => [event, event, resigned, event.merge("sig" => resigned["sig"])], "b" => [], "c" => [] }
    assert_equal MerchantAcceptances::NONE, MerchantAcceptances.of(answers, keys, terms, 3)
    answers["b"] = [resigned]
    assert_equal MerchantAcceptances::Acceptance.new(received: CAME, newer: false),
                 MerchantAcceptances.of(answers, keys, terms, 3)
  end

  # A record that is not this invoice's merchant's acceptance

  [["of another invoice of the order (another expiresAt)", ->(this) { { of: { expires_at: this.expires_at + 3600 } } }],
   ["of another order", ->(_) { { of: { ref: "R-2" } } }],
   ["of another address", ->(_) { { of: { address: TestChain.deposit_address(2) } } }],
   ["of another team", ->(_) { { signer: TestMerchant.bytes(9) } }],
   ["of the whole amount", ->(_) { { value: { "version" => 1, "received" => SATS } } }],
   ["of 0 sats", ->(_) { { value: { "version" => 1, "received" => 0 } } }],
   ["without a version", ->(_) { { value: { "received" => CAME } } }]].each do |name, options|
    test "is not counted: #{name}" do
      hold(acceptance(CAME, **options.call(self)))
      assert_underpaid
      assert_empty warnings
    end
  end

  # The invoice's end (for the cases above).
  def expires_at = @invoice.expires_at

  test "is not counted with a damaged signature" do
    event = acceptance(CAME)
    sig = event["sig"][0..-2] + (event["sig"].end_with?("0") ? "1" : "0")
    3.times { |index| relay(index).store(event.merge("sig" => sig)) }
    assert_underpaid
  end

  # Dated after now: its `created_at` is never compared with now, only with the lease's end.
  [["at the lease's end: counted", 120, true], ["a second after the lease's end: not counted", 121, false]]
    .each do |name, after, counted|
    test "is dated #{name}" do
      hold(acceptance(CAME, created_at: @invoice.expires_at + after))
      counted ? assert_equal(unconfirmed, status) : assert_underpaid
    end
  end

  # A merchant's acceptance of a newer format

  # A record of version 2, dated `created_at`, on every relay with `others` (relays send both).
  def newer_with(created_at, others)
    newer = acceptance(CAME, created_at: created_at, value: { "version" => 2 })
    3.times { |index| (others + [newer]).each { |event| relay(index).store(event) } }
  end

  def warned = warnings.count(MerchantAcceptances::NEWER_FORMAT)

  test "of a newer format, newer than a valid one, leaves the order without one, and is warned of" do
    newer_with(@merchant.now - 30, [acceptance(CAME, created_at: @merchant.now - 60)])
    assert_underpaid
    assert_equal 1, warned
  end

  test "of a newer format, older than a valid one, leaves it counted, and is warned of" do
    newer_with(@merchant.now - 90, [acceptance(CAME, created_at: @merchant.now - 60)])
    assert_equal unconfirmed, status
    assert_equal 1, warned
  end

  test "of a newer format dated after the lease's end is set aside, and warned of" do
    newer_with(@invoice.expires_at + 121, [acceptance(CAME)])
    assert_equal unconfirmed, status
    assert_equal 1, warned
  end

  # A merchant's acceptance with rest invoices, the tolerance, the Lightning part

  test "takes what rest invoices paid from it once: unconfirmed, then paid, mixed" do
    # 40 000 on-chain: a rest invoice of 9 000, paid; then the transaction replaced (RBF) by one
    # paying 21 000: 30 000 in all, 19 000 asked.
    @merchant.chain.drop(ADDRESS, @tx["txid"])
    first = pay("first", 40_000)
    @client.get_status(@invoice)
    rest = made_of(9000)[0]
    @merchant.pay_invoice(rest.payment_hash)
    @merchant.now += 1
    @merchant.chain.drop(ADDRESS, first["txid"])
    bump = pay("bump", 21_000, coins: first["vin"].map { |input| "#{input["txid"]}:#{input["vout"]}" })
    open = @client.get_status(@invoice)
    assert_equal %w[open 30000 19000], [open.state, open.received, open.rest.sats]
    # The merchant accepts what came: 21 000 due on-chain (30 000 less the 9 000 of the rest).
    hold(acceptance(CAME))
    assert_equal({ "state" => "unconfirmed", "received" => "30000", "confirmations" => 0, "txids" => [bump["txid"]] },
                 status)
    eventually { acceptance_records == [30_000] }
    @merchant.chain.confirm(ADDRESS, bump["txid"], @merchant.chain.height - 2)
    @merchant.now = @invoice.expires_at + 3600
    assert_equal({ "state" => "paid", "method" => "mixed", "received" => "30000", "txids" => [bump["txid"]],
                   "preimages" => [rest.preimage] }, status)
  end

  [["the merchant's acceptance's, lower", CAME, CAME], ["the tolerance's, lower", 48_000, 46_550]]
    .each do |name, accepted, came|
    test "with the tolerance, judges with the lower: #{name}" do
      @merchant.stop
      start(500, came)
      hold(acceptance(accepted))
      assert_equal unconfirmed(came), status
      eventually { acceptance_records == [came] }
    end
  end

  test "changes nothing once the Lightning invoice is paid" do
    hold(acceptance(CAME))
    @merchant.pay_invoice(@invoice.payment_hash)
    paid = @client.get_status(@invoice)
    assert_equal %w[paid lightning], [paid.state, paid.payment_method]
  end

  test "is network when fewer than a majority answer its read" do
    # A first check published the witness and asked the rest: the next one publishes nothing before
    # it reads (the relays that fail its read fail every later read on every relay too).
    assert_underpaid
    hold(acceptance(CAME))
    mute_read([1, 2])
    assert_raises(NetworkError) { @client.get_status(@invoice) }
    # Its Lightning invoice paid: paid all the same.
    @merchant.pay_invoice(@invoice.payment_hash)
    paid = @client.get_status(@invoice)
    assert_equal %w[paid lightning], [paid.state, paid.payment_method]
  end

  test "is seen by wait_for_payment at its next check of the on-chain part, the rest given till then" do
    socket = @merchant.start_explorer_socket
    statuses = Queue.new
    seen = []
    # The full checks so far: each asks the explorer for the address's transactions once.
    asked = @merchant.chain.asked.size
    full_checks = -> { @merchant.chain.asked.drop(asked).count { |url| url.end_with?("/txs") } }
    waiting = Thread.new do
      @client.wait_for_payment(@invoice, interval_ms: 250) { |status| statuses << status.to_h }
    end
    drain = -> { seen << statuses.pop until statuses.empty? }
    # The first full check, and the one the socket's connection starts, ended.
    eventually { socket.messages.size == 2 && full_checks.call == 2 }
    sleep 0.5
    drain.call
    assert_equal underpaid, seen.last
    # The merchant accepts: no message of the explorer, no check of the on-chain part; the checks of
    # the Lightning invoices give the status with its rest still.
    hold(acceptance(CAME))
    before = seen.size
    eventually do
      drain.call
      seen.size > before + 1
    end
    assert_equal 2, full_checks.call
    assert(seen.drop(before).all?(underpaid))
    # The next check of the on-chain part (a block here; every 60 s at least) counts it.
    socket.push({ "block" => { "height" => @merchant.chain.height } })
    eventually do
      drain.call
      seen.last["state"] == "unconfirmed"
    end
    assert_equal unconfirmed, seen.last
    @merchant.chain.confirm(ADDRESS, @tx["txid"], @merchant.chain.height - 2)
    socket.push({ "block" => { "height" => @merchant.chain.height } })
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => CAME.to_s, "txids" => [@tx["txid"]] },
                 waiting.value.to_h)
    eventually { acceptance_records == [CAME] }
  end
end
