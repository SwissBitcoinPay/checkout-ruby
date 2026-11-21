# frozen_string_literal: true

require_relative "test_helper"

# The merchant's tolerance of on-chain underpayments (SPEC.md §31, "The merchant's tolerance",
# "Acceptance records"), end to end against local relays and fakes of breez.tips and of the
# explorers: read in the channel, kept in the order's lease, its payment judged with it whatever the
# channel says later; a payment short by no more than it is paid (being confirmed first), one short
# by more asks its whole rest; the pages of the order's checkout links told by an acceptance
# record, never the tolerance itself.
class ToleranceTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  ORIGIN = "https://pay.example"
  ADDRESS = TestChain.deposit_address(1)
  # 5 %: of 49 000 sats, 2 450 may be missing, 46 550 pay the order.
  TOLERANCE = 500
  SATS = 49_000
  LEAST = 46_550

  def setup
    @logger = TestLogger.new
    @merchant = TestMerchant.new.start
    @merchant.publish_lot([ADDRESS], 90)
    @client = client
  end

  def teardown
    @merchant.stop
  end

  def client
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 1000, logger: @logger)
  end

  def warnings = @logger.messages

  # Publishes the channel, with `tolerance` (none given: no `onchainTolerance`), dated `created_at`.
  def publish_channel(created_at, *tolerance)
    extra = { "relays" => @merchant.key_relays, "checkout" => { "origin" => ORIGIN } }
    extra["onchainTolerance"] = tolerance[0] unless tolerance.empty?
    @merchant.publish_channel(@merchant.channel_value(created_at, extra), created_at)
  end

  # The events a relay holds (the first by default).
  def held(relay = @merchant.key_relays[0]) = @merchant.net.get(relay).events

  def sale_of_ref(ref)
    Derive.sale(@merchant.integration_key, Derive.registry(to_hex(@merchant.registry_key), @merchant.reader), ref)
  end

  # The inside of the sale of `ref`'s lease the first relay holds.
  def lease_inside(ref)
    sale = sale_of_ref(ref)
    leases = held.filter_map do |event|
      opened = Leases.open_sale_lease(event, sale)
      opened[:lease] if opened&.fetch(:kind) == :lease
    rescue Records::Newer
      nil
    end
    assert_equal 1, leases.size
    leases[0].inside
  end

  # The acceptance records of `invoice` a relay holds, as a checkout link's page opens them.
  def acceptances(invoice, relay = @merchant.key_relays[0])
    keys = Derive.rest_keys(@merchant.integration_key, invoice.ref, invoice.onchain_address, invoice.expires_at)
    held(relay).filter_map do |event|
      opened = Acceptances.open_record(event, keys, Integer(invoice.sats, 10))
      opened if opened.is_a?(Acceptances::Opened)
    end
  end

  # The invoices breez.tips made of `sats`.
  def made_of(sats) = @merchant.made_invoices.select { |made| made.amount_msat == sats * 1000 }

  def create_invoice(ref = "R-1")
    invoice = @client.create_invoice(ref: ref, sats: SATS, duration_seconds: 600, note: "Order 1", checkout: true)
    assert_equal ADDRESS, invoice.onchain_address
    # The lease marked confirmed on the first relay too.
    eventually { confirmed_lease?(ref) }
    invoice
  end

  # Whether the first relay holds the sale of `ref`'s lease, marked confirmed.
  def confirmed_lease?(ref)
    sale = sale_of_ref(ref)
    held.any? do |event|
      opened = Leases.open_sale_lease(event, sale)
      opened&.fetch(:kind) == :lease && opened[:lease].terms.confirmed?
    rescue Records::Newer
      false
    end
  end

  def pay(id, sats, **options)
    TestChain.payment(TestChain.txid(id), ADDRESS, sats, **options).tap { |tx| @merchant.chain.add(ADDRESS, tx) }
  end

  # The order's tolerance

  test "is the channel's, kept in the order's lease, never in what the shop gets" do
    publish_channel(100, TOLERANCE)
    invoice = create_invoice
    inside = lease_inside("R-1")
    assert_equal [SATS, TOLERANCE], inside.values_at("sats", "tolerance")
    # Neither the Invoice nor the checkout link's record (the customer reads it) holds it.
    assert_equal %w[bolt11 checkoutUrl createdAt expiresAt fiat note onchainAddress paymentHash paymentUri rate
                    redirectUrl ref sats verifyUrl], invoice.to_h.keys.sort
    refute_match(/toleran/i, invoice.to_json)
    fragment = CheckoutLinks.parse_fragment(URI.parse(invoice.checkout_url).fragment)
    assert_equal :link, fragment.status
    keys = CheckoutLinks.keys(fragment.link_key)
    link = eventually { held.find { |event| event["pubkey"] == fragment.author } }
    plaintext = Nip44.decrypt(link["content"], keys.encryption_key)
    refute_match(/toleran/i, plaintext)
    record = Json.parse(plaintext)
    assert_equal "checkout", record["t"]
    refute_nil CheckoutLinks.parse_value(record["v"])
  end

  [["absent", []], ["0", [0]], ["a fraction", [2.5]], ["a string", ["500"]], ["negative", [-1]],
   ["above 10 %", [1001]], ["null", [nil]]].each do |name, value|
    test "is none when the channel's is #{name}: the lease holds none" do
      publish_channel(100, *value)
      create_invoice
      refute lease_inside("R-1").key?("tolerance")
    end
  end

  test "is 10 % at most" do
    publish_channel(100, 1000)
    create_invoice
    assert_equal 1000, lease_inside("R-1")["tolerance"]
  end

  # A payment within the tolerance

  def within
    publish_channel(100, TOLERANCE)
    @invoice = create_invoice
    @merchant.now += 60
  end

  test "pays the order: being confirmed, then paid at 3 confirmations, without a rest" do
    within
    tx = pay("least", LEAST)
    assert_equal({ "state" => "unconfirmed", "received" => LEAST.to_s, "confirmations" => 0, "txids" => [tx["txid"]] },
                 @client.get_status(@invoice).to_h)
    assert_empty made_of(SATS - LEAST)
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    @merchant.now = @invoice.expires_at + 3600
    paid = { "state" => "paid", "method" => "onchain", "received" => LEAST.to_s, "txids" => [tx["txid"]] }
    assert_equal paid, @client.get_status(@invoice).to_h
    # The order is paid: no new invoice for it.
    error = assert_raises(OrderPaidError) { @client.create_invoice(ref: "R-1", sats: SATS) }
    assert_equal [paid, nil], [error.status.to_h, error.preimage]
  end

  test "asks the whole rest of a payment short by more" do
    within
    pay("short", LEAST - 1)
    status = @client.get_status(@invoice)
    made = made_of(SATS - LEAST + 1)[0]
    refute_nil made
    assert_equal({ "state" => "open", "expiresAt" => @invoice.expires_at, "received" => (LEAST - 1).to_s,
                   "rest" => { "sats" => (SATS - LEAST + 1).to_s, "bolt11" => made.pr,
                               "paymentUri" => "bitcoin:#{ADDRESS}?amount=0.00002451&lightning=#{made.pr}" } },
                 status.to_h)
    assert_empty acceptances(@invoice)
  end

  test "is reached by a second payment after an underpayment" do
    within
    pay("first", 44_100)
    status = @client.get_status(@invoice)
    assert_equal %w[open 44100 4900], [status.state, status.received, status.rest.sats]
    pay("second", 2450)
    status = @client.get_status(@invoice)
    assert_equal ["unconfirmed", LEAST.to_s], [status.state, status.received]
  end

  test "with an invoice of the rest paid, needs on-chain only what the tolerance leaves" do
    within
    tx = pay("part", 20_000)
    @client.get_status(@invoice)
    rest = made_of(29_000)[0]
    @merchant.pay_invoice(rest.payment_hash)
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    assert_equal({ "state" => "paid", "method" => "mixed", "received" => "49000", "txids" => [tx["txid"]],
                   "preimages" => [rest.preimage] }, @client.get_status(@invoice).to_h)
  end

  test "is waited for by wait_for_payment until paid" do
    within
    @merchant.start_explorer_socket
    tx = pay("least", LEAST)
    @merchant.chain.confirm(ADDRESS, tx["txid"], @merchant.chain.height - 2)
    assert_equal({ "state" => "paid", "method" => "onchain", "received" => LEAST.to_s, "txids" => [tx["txid"]] },
                 @client.wait_for_payment(@invoice, interval_ms: 250).to_h)
  end

  # The tolerance of the order's creation

  test "still judges its payment when the channel's is lowered" do
    publish_channel(100, TOLERANCE)
    invoice = create_invoice
    publish_channel(200, 0)
    @merchant.now += 60
    pay("least", LEAST)
    assert_predicate @client.get_status(invoice), :unconfirmed?
  end

  test "never judges a payment of an order created without one" do
    publish_channel(100)
    invoice = create_invoice
    publish_channel(200, TOLERANCE)
    @merchant.now += 60
    pay("least", LEAST)
    status = @client.get_status(invoice)
    assert_equal ["open", LEAST.to_s, (SATS - LEAST).to_s], [status.state, status.received, status.rest.sats]
    # Past its end, for good: never paid by a tolerance set afterwards.
    @merchant.now = invoice.expires_at + 3600
    assert_equal({ "state" => "expired", "received" => LEAST.to_s }, @client.get_status(invoice).to_h)
  end

  # The acceptance record

  test "tells the checkout link's page what was received, on every relay, once" do
    within
    pay("least", 47_000)
    @client.get_status(@invoice)
    @merchant.key_relays.each do |relay|
      eventually { acceptances(@invoice, relay).map(&:received) == [47_000] }
    end
    # Its address, from the invoice's rest key, and its life, the links'.
    keys = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    event = acceptances(@invoice)[0].event
    assert_equal keys.author, event.pubkey
    assert_equal [["d", Derive.acceptance_record_address(keys.key)],
                  ["expiration", (@invoice.expires_at + 604_800).to_s]], event.tags
    # What was received, never the tolerance.
    assert_equal({ "t" => "checkout-accepted", "v" => { "version" => 1, "received" => 47_000 } },
                 Json.parse(Nip44.decrypt(event.content, keys.encryption_key)))
    published = lambda do
      @merchant.net.get(@merchant.key_relays[0]).received.count do |sent|
        Acceptances.open_record(sent, keys, SATS).is_a?(Acceptances::Opened)
      end
    end
    sent = published.call
    @client.get_status(@invoice)
    # Known on a majority: not published again.
    assert_equal sent, published.call
  end

  test "is never written over one of a newer format, which it warns of" do
    within
    keys = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    # A newer version's acceptance record, in a format this one cannot read.
    tags = [["d", Derive.acceptance_record_address(keys.key)], ["expiration", (@invoice.expires_at + 604_800).to_s]]
    newer = Events.sign(keys.secret_key, SecureRandom.method(:random_bytes),
                        created_at: @merchant.now, kind: 30_078, tags: tags, content: "#")
    relays = @merchant.key_relays.map { |url| @merchant.net.get(url) }
    relays.each { |relay| relay.take(newer) }
    pay("least", 47_000)
    status = @client.get_status(@invoice)
    assert_equal %w[unconfirmed 47000], [status.state, status.received]
    assert(relays.all? { |relay| relay.received.none? { |event| event["pubkey"] == keys.author } })
    assert_equal ["sattleme-checkout: an acceptance record of this order has a newer format than this version " \
                  "reads; update the gem"], warnings
  end

  test "is published again, of less, when a replacement lowers what was received" do
    within
    first = pay("first", 48_000)
    @client.get_status(@invoice)
    @merchant.now += 1
    @merchant.chain.drop(ADDRESS, first["txid"])
    # A fee bump of the same coin, paying less.
    coins = first["vin"].map { |input| "#{input["txid"]}:#{input["vout"]}" }
    pay("bump", 47_000, coins: coins)
    status = @client.get_status(@invoice)
    assert_equal %w[unconfirmed 47000], [status.state, status.received]
    eventually { acceptances(@invoice).max_by { |opened| opened.event.created_at }&.received == 47_000 }
  end

  test "is never published for a payment of the whole amount" do
    within
    pay("whole", SATS)
    assert_predicate @client.get_status(@invoice), :unconfirmed?
    assert_empty acceptances(@invoice)
  end

  test "publishes nothing when fewer than a majority answer its read, and publishes at the next check" do
    within
    address = Derive.acceptance_record_address(Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS,
                                                                @invoice.expires_at).key)
    muting = true
    @merchant.key_relays.drop(1).each do |relay|
      # The read of the acceptance records alone never answered there.
      @merchant.net.get(relay).behaviour = { mute_query: ->(filter) { muting && filter["#d"]&.include?(address) } }
    end
    pay("least", LEAST)
    status = @client.get_status(@invoice)
    assert_equal ["unconfirmed", LEAST.to_s], [status.state, status.received]
    # What those relays hold, of a newer format perhaps, cannot be told: nothing written over it.
    keys = Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS, @invoice.expires_at)
    @merchant.key_relays.each do |relay|
      assert(@merchant.net.get(relay).received.none? do |event|
        event["pubkey"] == keys.author && event["tags"].include?(["d", address])
      end)
    end
    assert_equal 1, warnings.size
    assert_includes warnings[0], "the acceptance record of a payment was not published"
    muting = false
    @client.get_status(@invoice)
    eventually { acceptances(@invoice).map(&:received) == [LEAST] }
  end

  test "logs a failed publication, never the check's error, and publishes at the next check" do
    within
    address = Derive.acceptance_record_address(Derive.rest_keys(@merchant.integration_key, "R-1", ADDRESS,
                                                                @invoice.expires_at).key)
    refusing = true
    @merchant.key_relays.each do |relay|
      @merchant.net.get(relay).behaviour = {
        refuse_event: lambda do |event|
          "blocked: no" if refusing && event["tags"].any? { |name, value| name == "d" && value == address }
        end
      }
    end
    pay("least", LEAST)
    status = @client.get_status(@invoice)
    assert_equal ["unconfirmed", LEAST.to_s], [status.state, status.received]
    assert_equal 1, warnings.size
    assert_includes warnings[0], "the acceptance record of a payment was not published"
    refute_match(/toleran|500/, warnings[0])
    assert_empty acceptances(@invoice)
    refusing = false
    @client.get_status(@invoice)
    eventually { acceptances(@invoice).map(&:received) == [LEAST] }
  end
end
