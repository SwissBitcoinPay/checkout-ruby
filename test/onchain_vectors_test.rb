# frozen_string_literal: true

require_relative "test_helper"

# The gem against the on-chain conformance vectors (SPEC.md §31) of the pinned copy of the
# specification: deposit addresses, the methods of an order, leases, witnesses, replacements, the
# statuses of an invoice with an address, complete reads, tolerances and the earlier invoices of
# an order. Read only: these vectors are written in checkout-spec.
class OnchainVectorsTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  RANDOM = SecureRandom.method(:random_bytes)
  APP = SpecVectors.app

  def self.vectors(name) = SpecVectors.read("vectors/#{name}")

  def self.each_case(file, cases, name = ->(item) { item["name"] }, &block)
    cases.each_with_index do |item, index|
      test("#{file} #{index}: #{name.call(item)}") { instance_exec(item, &block) }
    end
  end

  # The value of the block, or its error as the vectors write it: `{ error: code, param? }`.
  def outcome
    yield
  rescue Sattleme::Checkout::Error => e
    param = e.respond_to?(:param) ? e.param : nil
    { "error" => e.code }.merge(param ? { "param" => param.gsub(/_([a-z])/) { Regexp.last_match(1).upcase } } : {})
  end

  def http(fake) = Http::Context.new(client: fake, timeout_ms: 1000, stop: Stop.new(Cancellation::NONE))

  # vectors/app/onchain-lot.json

  test "vectors/app/onchain-lot.json: opens the lot the merchant's app made, with the integration key alone" do
    vector = SpecVectors.read("vectors/app/onchain-lot.json")
    access = IntegrationKey.parse(vector["secretKey"])
    _, encryption_key = Derive.channel_keys(access.key)
    assert_equal [vector["team"], vector["lotAddress"], vector["channelEncryptionKey"]],
                 [access.team_public_key, Derive.lot_address(access.key), to_hex(encryption_key)]
    opened = Records.open(vector["lot"]["event"], type: vector["lot"]["value"]["t"],
                                                  encryption_key: encryption_key, address: vector["lotAddress"],
                                                  author: vector["team"]) do |value, event|
      Lot.parse(value, event.created_at)
    end
    assert_equal [:ok, vector["lot"]["value"]["v"]["addresses"]], [opened.status, opened.value]
  end

  # vectors/app/merchant-acceptance.json

  accepted = SpecVectors.read("vectors/app/merchant-acceptance.json")
  ACCEPTED = accepted
  ACCEPTED_ACCESS = IntegrationKey.parse(accepted["secretKey"])
  MADE_ACCESS = IntegrationKey.parse(accepted["made"]["secretKey"])

  test "vectors/app/merchant-acceptance.json: is of the team and the channel's key of its integration key" do
    assert_equal [ACCEPTED["team"], ACCEPTED["channelEncryptionKey"]],
                 [ACCEPTED_ACCESS.team_public_key, to_hex(Derive.channel_keys(ACCEPTED_ACCESS.key)[1])]
  end

  test "vectors/app/merchant-acceptance.json: made, by a team of its own, for the same integration" do
    assert_equal [ACCEPTED["made"]["team"], to_hex(ACCEPTED_ACCESS.key)],
                 [MADE_ACCESS.team_public_key, to_hex(MADE_ACCESS.key)]
    assert_equal ACCEPTED["made"]["team"], Events.public_key(hex(ACCEPTED["made"]["teamSecret"]))
  end

  each_case("vectors/app/merchant-acceptance.json invoices", accepted["invoices"],
            ->(item) { "the merchant's acceptance address of #{item["ref"]} at #{item["expiresAt"]}" }) do |item|
    sale_key, _, author = Derive.sale_keys(ACCEPTED_ACCESS.key, item["ref"])
    assert_equal [item["saleKey"], item["sale"]], [to_hex(sale_key), author]
    assert_equal item["acceptanceAddress"],
                 Derive.merchant_acceptance_address(ACCEPTED_ACCESS.key, item["sale"], item["onchainAddress"],
                                                    item["expiresAt"].to_i)
  end

  # `item` read as a check reads it for its invoice, with the integration key `access`: through the
  # reading of one record (MerchantAcceptances.open), and through the count of a read on every relay
  # where each relay sent it (MerchantAcceptances.of).
  def read_acceptance(item, access)
    invoice = ACCEPTED["invoices"][item["invoice"]]
    keys = MerchantAcceptances.keys(access.key, access.team_public_key, invoice["sale"], invoice["onchainAddress"],
                                    invoice["expiresAt"].to_i)
    terms = MerchantAcceptances::Terms.new(sats: Integer(invoice["sats"], 10), expires_at: invoice["expiresAt"].to_i)
    opened = MerchantAcceptances.open(item["event"], keys, terms)
    shown = case opened&.status
            when :ok then { "received" => opened.received, "createdAt" => opened.event.created_at }
            when :newer then "newer"
            end
    assert_value item["expected"], shown
    every_relay = %w[a b c].to_h { |relay| [relay, [item["event"]]] }
    assert_value item["expected"].is_a?(Hash) ? item["expected"]["received"] : nil,
                 MerchantAcceptances.of(every_relay, keys, terms, 3).received
  end

  each_case("vectors/app/merchant-acceptance.json records", accepted["records"]) do |item|
    read_acceptance(item, ACCEPTED_ACCESS)
  end

  each_case("vectors/app/merchant-acceptance.json made", accepted["made"]["records"]) do |item|
    read_acceptance(item, MADE_ACCESS)
  end

  # onchain-addresses.json

  addresses = vectors("onchain-addresses.json")

  each_case("onchain-addresses.json addresses", addresses["addresses"],
            ->(item) { "#{item["name"]}: #{item["valid"]}" }) do |item|
    assert_equal item["valid"], Addresses.deposit?(item["address"])
  end

  each_case("onchain-addresses.json registry", addresses["registry"]["cases"], ->(item) { item["address"] }) do |item|
    assert_equal item["registryAddress"],
                 Addresses.lease_address(hex(addresses["registry"]["registryKey"]), item["address"])
  end

  each_case("onchain-addresses.json uris", addresses["uris"]) do |item|
    assert_equal item["uri"], Addresses.payment_uri(item["address"], Integer(item["sats"], 10), item["bolt11"])
  end

  each_case("onchain-addresses.json amounts", addresses["amounts"], ->(item) { "#{item["sats"]} sats" }) do |item|
    assert_equal item["btc"], Addresses.btc_amount(Integer(item["sats"], 10))
  end

  # payment-methods.json

  each_case("payment-methods.json", vectors("payment-methods.json")["cases"]) do |item|
    leased = if item["address"] == "explorer_failed"
               NetworkError.new("The explorer did not answer")
             else
               item["address"].to_sym
             end
    result = outcome do
      order = Order.check({ ref: "A-1", sats: item["sats"] }, [])
      sendable = [Integer(item["sendable"]["min"], 10), Integer(item["sendable"]["max"], 10)]
      methods = Methods.with(Methods.of(order.sats, sendable, "sats"), leased)
      { "methods" => [("lightning" if methods.lightning), ("onchain" if methods.onchain)].compact }
    end
    assert_equal item["expected"], result
  end

  # onchain-leases.json

  # A record of a vector's leased or confirmed lists, as a read opens it (one whose id is not its
  # hash never is): its signature check, counted.
  class VectorRecord < Leases::Record
    def initialize(event, hold, index, signature, checked)
      super(event, "", hold)
      @index = index
      @signature = signature
      @checked = checked
    end

    def signed?
      @checked << @index
      @signature != false
    end
  end

  def records_of(records, checked = [])
    records.each_with_index.filter_map do |record, index|
      next if record["id"] == false

      outside = record["outside"]
      hold = if outside == "newer"
               :newer
             elsif outside["withdrawn"]
               :withdrawn
             else
               outside["end"].to_i
             end
      event = Leases::LeaseEvent.new(id: record["eventId"] || index.to_s.rjust(64, "0"), pubkey: record["author"],
                                     created_at: record["createdAt"].to_i, sig: nil)
      VectorRecord.new(event, hold, index, record["signature"], checked)
    end
  end

  leases = vectors("onchain-leases.json")
  REGISTRY_KEY = Text.hex_bytes(leases["registryKey"])
  # The sale of vectors/app/app.json's declaration, in this registry.
  LEASE_SALE = Derive.sale(Text.hex_bytes(APP["parsed"]["integrationKey"]),
                           Derive.registry(leases["registryKey"], leases["registryReader"]), APP["declaration"]["ref"])

  test "onchain-leases.json: is the sale of the app's declaration" do
    assert_equal [leases["saleAuthor"], leases["saleSecret"], leases["innerConversationKey"]],
                 [LEASE_SALE.author, to_hex(LEASE_SALE.secret_key), to_hex(LEASE_SALE.inner_key)]
  end

  each_case("onchain-leases.json derived", leases["derived"], ->(item) { item["address"] }) do |item|
    d = Addresses.lease_address(REGISTRY_KEY, item["address"])
    assert_equal [item["registryAddress"], item["outerKey"]],
                 [d, to_hex(Derive.outer_key(REGISTRY_KEY, d, LEASE_SALE.author))]
  end

  def outside_of(whole)
    return nil unless whole

    outside = whole[1]
    case outside[0]
    when :newer then "newer"
    when :withdrawn then { "version" => 1, "withdrawn" => true }
    else { "version" => 1, "end" => outside[1], "sealed" => outside[2] }
    end
  end

  each_case("onchain-leases.json events", leases["events"]) do |item|
    event = item["event"]
    d = Addresses.lease_address(REGISTRY_KEY, item["address"])
    record = Leases.open_record(event, REGISTRY_KEY, d)
    whole = Leases.open_outside(event, REGISTRY_KEY, d)
    assert_value item["outside"], outside_of(whole)
    # A read keeps of it only its id, author, date and signature, and its outside's end.
    if whole
      kept = Leases::LeaseEvent.new(id: event["id"], pubkey: event["pubkey"], created_at: event["created_at"].to_i,
                                    sig: event["sig"])
      assert_equal kept, record.event
    else
      assert_nil record
    end
    # Opening it checks no signature; the record checks it when asked.
    signature = item.key?("signature") ? item["signature"] : true
    assert_equal signature, Events.signature_checks?(event)
    assert_equal signature, record.signed? if record
    opened = whole && whole[1][0] == :lease ? Leases.open_inside(whole[1][1], whole[1][2], d, LEASE_SALE) : nil
    inside = item["inside"]
    assert_value inside, opened&.last
    # The order's tolerance it gives: absent, or not one, none.
    assert_value(inside && (item.key?("tolerance") ? item["tolerance"] : 0), opened&.first&.tolerance)
    # Confirmed: `confirmed` true alone (the vector's field, absent: true).
    assert_value(inside && (item.key?("confirmed") ? item["confirmed"] : true), opened&.first&.confirmed?)
  end

  # A lease the gem makes for the same sale and terms opens with the vector's keys into the
  # vector's inside, as its JSON text.
  each_case("onchain-leases.json makes again", leases["events"].reject { |item| item["inside"].nil? }) do |item|
    v = item["inside"]
    terms = Leases::Terms.new(address: item["address"], sats: v["sats"].to_i, invoice: v["invoice"],
                              verify_url: v["verifyUrl"], created_at: v["createdAt"].to_i,
                              expires_at: v["expiresAt"].to_i, price: v["sale"]["fiat"], note: v["sale"]["note"],
                              tolerance: v["tolerance"] || 0, confirmed: v.key?("confirmed") ? v["confirmed"] : nil)
    made = Leases.event(sale: LEASE_SALE, terms: terms, created_at: item["event"]["created_at"].to_i, random: RANDOM)
    d = Addresses.lease_address(REGISTRY_KEY, item["address"])
    assert_equal [["d", d]], made.tags
    assert_equal leases["saleAuthor"], made.pubkey
    derived = leases["derived"].find { |entry| entry["address"] == item["address"] }
    plaintext = Nip44.decrypt(made.content, hex(derived["outerKey"]))
    assert_equal 0, plaintext.bytesize % 256
    record = Json.parse(plaintext)
    assert_equal "registry-onchain", record["t"]
    assert_equal item["outside"]["end"], record["v"]["end"]
    assert_equal Json.generate(v), Nip44.decrypt(record["v"]["sealed"], hex(leases["innerConversationKey"]))
    assert_equal leases["innerConversationKey"],
                 to_hex(Nip44.conversation_key(LEASE_SALE.secret_key, leases["registryReader"]))
  end

  each_case("onchain-leases.json leased", leases["leased"]) do |item|
    asked = []
    assert_equal item["expected"], Leases.leased?(records_of(item["records"], asked), item["t"].to_i)
    # The signatures checked: those of the records that would end an older one's hold.
    assert_equal item["checked"].map(&:to_i), asked.sort
  end

  each_case("onchain-leases.json confirmed", leases["confirmed"]) do |item|
    read = records_of(item["records"])
    # This lease, or one that is not among the records read.
    own = if item["lease"].nil?
            Leases::LeaseEvent.new(id: "f" * 64, pubkey: item["sale"], created_at: item["t"].to_i, sig: nil)
          else
            read.find { |record| record.event.id == item["lease"].to_i.to_s.rjust(64, "0") }.event
          end
    assert_equal item["expected"], item["complete"] && Leases.confirmed?(read, own, item["t"].to_i)
  end

  # onchain-witnesses.json

  witnesses = vectors("onchain-witnesses.json")
  SEEN = Derive.seen_keys(Text.hex_bytes(witnesses["integrationKey"]))

  test "onchain-witnesses.json: derives the seen keys" do
    assert_equal witnesses["derived"], { "seenSecret" => to_hex(SEEN.secret_key), "seenAuthor" => SEEN.author,
                                         "seenAddressKey" => to_hex(SEEN.address_key) }
    assert_equal witnesses["channelEncryptionKey"], to_hex(SEEN.encryption_key)
  end

  each_case("onchain-witnesses.json addresses", witnesses["addresses"],
            ->(item) { "#{item["txid"]}, #{item["sale"].inspect}" }) do |item|
    assert_equal item["witnessAddress"],
                 Witnesses.witness_address(SEEN.address_key, item["address"], item["txid"], item["sale"])
  end

  each_case("onchain-witnesses.json orderTags", witnesses["orderTags"],
            ->(item) { "#{item["address"]}, #{item["sale"].inspect}" }) do |item|
    assert_equal item["orderTag"], Witnesses.order_tag(SEEN.address_key, item["address"], item["sale"])
  end

  each_case("onchain-witnesses.json addressTags", witnesses["addressTags"], ->(item) { item["address"] }) do |item|
    assert_equal item["addressTag"], Witnesses.address_tag(SEEN.address_key, item["address"])
  end

  def witness_value(event)
    opened = Witnesses.open(event, SEEN)
    return nil unless opened
    return "newer" if opened.status == :newer

    witness = opened.witness
    { "version" => 1, "address" => witness.address, "txid" => witness.txid, "sale" => witness.sale,
      "sats" => witness.sats, "inputs" => witness.inputs, "replacement" => witness.replacement,
      "expiresAt" => witness.expires_at }
  end

  each_case("onchain-witnesses.json events", witnesses["events"]) do |item|
    assert_value item["value"], witness_value(item["event"])
  end

  # The addresses an event names (SPEC.md §31, "Leasing an address", step 3), of those of
  # addressTags: whatever its content, once it is of the seen author and checks out.
  BY_TAG = witnesses["addressTags"].to_h { |item| [item["addressTag"], item["address"]] }

  each_case("onchain-witnesses.json names", witnesses["events"]) do |item|
    assert_equal item["names"].sort, Witnesses.names(item["event"], SEEN, BY_TAG).sort
  end

  # A witness the gem makes for the same value has the vector's `d` and `o` tags (a vector's other
  # tags are ignored), and opens to it.
  each_case("onchain-witnesses.json makes again",
            witnesses["events"].reject { |item| item["value"].nil? || item["value"] == "newer" }) do |item|
    v = item["value"]
    witness = Witnesses::Witness.new(address: v["address"], txid: v["txid"], sale: v["sale"], sats: v["sats"].to_i,
                                     inputs: v["inputs"], replacement: v["replacement"],
                                     expires_at: v["expiresAt"]&.to_i)
    made = Witnesses.event(SEEN, witness, item["event"]["created_at"].to_i, RANDOM)
    assert_equal witnesses["derived"]["seenAuthor"], made.pubkey
    assert_equal(item["event"]["tags"].select { |tag| %w[d o].include?(tag[0]) }, made.tags)
    assert_equal v, witness_value(made)
  end

  # onchain-replacements.json

  each_case("onchain-replacements.json", vectors("onchain-replacements.json")["cases"]) do |item|
    txs = item["txs"].map do |tx|
      Replacements::PaymentTx.new(txid: tx["txid"], sats: Integer(tx["sats"], 10), inputs: tx["inputs"],
                                  order: tx["order"]&.to_i, listed: tx["listed"])
    end
    made = Replacements.parts(txs).transform_values do |list|
      list.map { |part| { "sats" => part.sats.to_s, "root" => part.root } }
    end
    assert_equal item["parts"], made
  end

  # onchain-payments.json

  payments = vectors("onchain-payments.json")
  INVOICE = payments["invoice"]
  ADDRESS = INVOICE["onchainAddress"]
  SATS = Integer(INVOICE["sats"], 10)
  EXPIRES_AT = INVOICE["expiresAt"].to_i
  SALE = APP["declaration"]["saleAuthor"]
  PAYMENT_SEEN = Derive.seen_keys(Text.hex_bytes(APP["parsed"]["integrationKey"]))

  def witness_at(txid, of) = Witnesses.witness_address(PAYMENT_SEEN.address_key, ADDRESS, txid, of)

  def error_of(code)
    case code
    when "network" then NetworkError.new("The Lightning address did not answer")
    when "invalid_invoice" then InvalidInvoiceError.new("Not this invoice")
    else Sattleme::Checkout::Error.new(code, code)
    end
  end

  def part_of(state) = Lnurl::Part.new(state: state["state"], preimage: state["preimage"])

  # The explorer read (at `base`: mempool.space's, or the node's), BlockCypher, as the vector's case
  # has them.
  def chain_route(item, uri, asked, base)
    url = uri.to_s
    explorer = item["explorer"]
    if url == "#{base}/address/#{ADDRESS}/txs"
      explorer.key?("error") ? { status: 500, text: "down" } : { json: explorer["txs"] }
    elsif url == "#{base}/blocks/tip/height"
      explorer.key?("error") ? { status: 500, text: "down" } : { text: explorer["height"].to_i.to_s }
    elsif uri.host == "api.blockcypher.com"
      txid = uri.path.split("/").last
      asked << txid
      if item["blockcypher"].key?("error")
        { status: 500, json: { "error" => "down" } }
      elsif item["blockcypher"].key?(txid)
        { json: { "hash" => txid, "received" => item["blockcypher"][txid], "confirmations" => 0 } }
      else
        { status: 404, json: { "error" => "Transaction #{txid} not found." } }
      end
    else
      raise "Not asked in this vector: #{url}"
    end
  end

  # Another order's deposit address, and another sale.
  OTHER_ADDRESS = "bc1p4gmh64rd4m5y5nn8hwfnvtz2mm6lngpmwys5a257klyg03ju0pyqu65xe8"
  OTHER_SALE = Derive.sale_keys(Text.hex_bytes(APP["parsed"]["integrationKey"]), "ANOTHER-ORDER")[2]

  test "onchain-payments.json: makes witnesses of another order at a deposit address of its own" do
    assert_equal [true, false], [Addresses.deposit?(OTHER_ADDRESS), OTHER_ADDRESS == ADDRESS]
  end

  # The event of `held`, a witness of the vector, as a relay sends it: made by the seen secret as the
  # client makes witnesses (Witnesses.event), at the invoice's address or, `address` "other", at
  # another order's; for the order's sale ("this", with the `expiresAt` of the invoice it is of),
  # another sale (with the invoice's `expiresAt`: nothing here depends on it) or none. One of a
  # newer format: a record of the seen secret at the witness address of its txid and the order's
  # sale ("newer") or none ("newer none"), with that address's `o` tags, dated `newer_at` (the
  # vector gives no date of it).
  def witness_event(held, newer_at)
    at = held["address"] == "other" ? OTHER_ADDRESS : ADDRESS
    if ["newer", "newer none"].include?(held["sale"])
      of = held["sale"] == "newer" ? SALE : nil
      return Records.seal(
        type: Protocol::WITNESS_RECORD_TYPE, value: { "version" => Protocol::WITNESS_VERSION + 1 },
        signer: PAYMENT_SEEN.secret_key, encryption_key: PAYMENT_SEEN.encryption_key,
        address: Witnesses.witness_address(PAYMENT_SEEN.address_key, at, held["txid"], of), created_at: newer_at,
        random: RANDOM, tags: [[Protocol::ORDER_TAG, Witnesses.order_tag(PAYMENT_SEEN.address_key, at, of)],
                               [Protocol::ORDER_TAG, Witnesses.address_tag(PAYMENT_SEEN.address_key, at)]]
      ).to_h
    end
    of = { "this" => SALE, "other" => OTHER_SALE }[held["sale"]]
    witness = Witnesses::Witness.new(address: at, txid: held["txid"], sale: of, sats: held["sats"].to_i,
                                     inputs: held["inputs"], replacement: held["replacement"],
                                     expires_at: of && (held["expiresAt"] || EXPIRES_AT).to_i)
    Witnesses.event(PAYMENT_SEEN, witness, held["seenAt"].to_i, RANDOM).to_h
  end

  # The rest part: the invoices of the rest the relays hold, and the Lightning part of each.
  def rests_of(item)
    return nil unless item["rests"]

    invoices = item["rests"].map do |rest|
      decoded = Bolt11.decode(rest["invoice"])
      # What the vector writes of it is the invoice's own.
      assert_equal [rest["paymentHash"], rest["sats"], rest["createdAt"], rest["expiresAt"]],
                   [decoded.payment_hash, (decoded.amount_msat / 1000).to_s, decoded.timestamp, decoded.expires_at]
      Rests::Invoice.new(bolt11: rest["invoice"], payment_hash: decoded.payment_hash,
                         verify_url: "https://breez.tips/lnurlp/verify/#{decoded.payment_hash}",
                         sats: decoded.amount_msat / 1000, created_at: decoded.timestamp,
                         expires_at: decoded.expires_at)
    end
    results = item["rests"].map do |rest|
      lightning = rest["lightning"]
      lightning.key?("error") ? Settled.failed(error_of(lightning["error"])) : Settled.ok(part_of(lightning))
    end
    Payments::RestPart.of(invoices, results)
  end

  # The merchant's acceptances (the team's records, SPEC.md §31, "The merchant's acceptance"), made
  # by a team of merchant-acceptance.json's own (`made`: its secret is in the vector) for the app's
  # integration key, so that they check out: at the address of the invoice of the order's sale.
  TEAM = SpecVectors.read("vectors/app/merchant-acceptance.json")["made"]
  TEAM_ACCESS = IntegrationKey.parse(TEAM["secretKey"])
  MERCHANT_KEYS = MerchantAcceptances.keys(TEAM_ACCESS.key, TEAM_ACCESS.team_public_key, SALE, ADDRESS, EXPIRES_AT)
  MERCHANT_TERMS = MerchantAcceptances::Terms.new(sats: SATS, expires_at: EXPIRES_AT)
  # The merchant's relays of the vector: 3, of which 2 are a majority.
  MERCHANT_RELAYS = %w[wss://merchant-1.test wss://merchant-2.test wss://merchant-3.test].freeze

  test "onchain-payments.json: makes merchant's acceptances that check out, with the app's integration key" do
    assert_equal APP["parsed"]["integrationKey"], to_hex(TEAM_ACCESS.key)
    event = acceptance_events("check", [{ "received" => "30000", "createdAt" => 1_791_378_300 }])[0]
    opened = MerchantAcceptances.open(event, MERCHANT_KEYS, MERCHANT_TERMS)
    assert_equal [:ok, 30_000], [opened.status, opened.received]
  end

  # Random bytes of their own for each case, the same at each run: SHA-256 of `seed` and a count.
  def fixed_random(seed)
    count = 0
    lambda do |size|
      Array.new((size + 31) / 32) { Crypto.sha256("#{seed}/#{count += 1}".b) }.join.byteslice(0, size)
    end
  end

  # The events of a case's merchant's acceptances, sealed and signed by the team as the merchant's
  # app does (Records.seal): of its `received` (a JSON number, whatever it is), or of version 2 for
  # one of a newer format, dated its `createdAt`. Where the vector gives two of one date ids, made
  # again until their ids sort as the vector's do (the lowest counts).
  def acceptance_events(name, records)
    random = fixed_random("merchant's acceptance: #{name}")
    loop do
      events = records.map do |record|
        value = if record["newer"]
                  { "version" => Protocol::MERCHANT_ACCEPTANCE_VERSION + 1 }
                else
                  { "version" => Protocol::MERCHANT_ACCEPTANCE_VERSION, "received" => Integer(record["received"], 10) }
                end
        Records.seal(type: Protocol::MERCHANT_ACCEPTANCE_RECORD_TYPE, value: value,
                     signer: hex(TEAM["teamSecret"]), encryption_key: MERCHANT_KEYS.encryption_key,
                     address: MERCHANT_KEYS.address, created_at: record["createdAt"].to_i, random: random).to_h
      end
      sorted = records.each_with_index.all? do |a, i|
        records.each_with_index.all? do |b, j|
          a["id"].nil? || b["id"].nil? || (a["id"] < b["id"]) == (events[i]["id"] < events[j]["id"])
        end
      end
      return events if sorted
    end
  end

  # What each of the 3 relays holds: each record on the first `sentBy` of them (absent: all).
  def held_by_relay(name, records)
    events = acceptance_events(name, records || [])
    MERCHANT_RELAYS.each_with_index.to_h do |url, index|
      [url, events.select.with_index { |_, i| index < (records[i]["sentBy"] || MERCHANT_RELAYS.size) }]
    end
  end

  # The check's read of the merchant's acceptance, through the gem's count of what the relays sent
  # (MerchantAcceptances.of), each relay answering with what it holds; "unreadable": fewer than a
  # majority answered (NetworkError, as MerchantAcceptances.read raises).
  def counted_read(item)
    lambda do
      if item["merchantAccepted"] == "unreadable"
        raise NetworkError, "Fewer than a majority of the merchant's relays answered"
      end

      MerchantAcceptances.of(held_by_relay(item["name"], item["merchantAccepted"]), MERCHANT_KEYS, MERCHANT_TERMS,
                             MERCHANT_RELAYS.size)
    end
  end

  # The same, end to end: the merchant's 3 relays, local, each storing what held_by_relay says as it
  # is (several at one address); the check reads them on every relay (MerchantAcceptances.read over
  # a pool). The first, which holds every record, answers 150 ms after the others: a read that went
  # on with the first majority to answer would miss what it holds. "unreadable": the 2 others never
  # answer the read.
  def relay_read(item)
    held = item["merchantAccepted"] == "unreadable" ? nil : held_by_relay(item["name"], item["merchantAccepted"])
    net = RelayNet.new
    relays = MERCHANT_RELAYS.each_with_index.map do |url, index|
      behaviour = if index.zero? then { query_delay_ms: 150 }
                  elsif held.nil? then { mute: true }
                  else {}
                  end
      net.add(url, behaviour).tap { |relay| (held&.fetch(url) || []).each { |event| relay.store(event) } }
    end
    stop = Stop.new(Cancellation::NONE)
    pool = Relay::Pool.new(websocket: net.websocket_client, timeout_ms: 500, stop: stop, random: RANDOM,
                           now: -> { item["now"].to_i })
    begin
      yield -> { MerchantAcceptances.read(pool, MERCHANT_KEYS, MERCHANT_TERMS, MERCHANT_RELAYS, random: RANDOM, stop:) }
    ensure
      pool.close
    end
    # Nothing published there: a check never publishes a merchant's acceptance, nor again.
    relays.each { |relay| assert_empty relay.received }
    # Read on every relay, as the check reads it: each relay asked, by its address alone.
    if held && relays.any? { |relay| !relay.queries.empty? }
      filter = { "kinds" => [30_078], "authors" => [MERCHANT_KEYS.team], "#d" => [MERCHANT_KEYS.address] }
      relays.each { |relay| assert_equal [filter], relay.queries }
    end
  ensure
    net&.close
  end

  each_case("onchain-payments.json", payments["cases"]) { |item| payment_case(item, counted_read(item)) }

  # The explorer read is the merchant's Bitcoin node when the channel names one (SPEC.md §31): the
  # same answers, at the node's URL, mempool.space never asked ("none").
  each_case("onchain-payments.json read from the merchant's Bitcoin node", payments["cases"]) do |item|
    payment_case(item, counted_read(item), BitcoinNodes::Node.new(url: "http://192.168.1.10:3006", fallback: "none",
                                                                  payers: false))
  end

  each_case("onchain-payments.json end to end on 3 local relays",
            payments["cases"].select { |item| item.key?("merchantAccepted") }) do |item|
    relay_read(item) { |read| payment_case(item, read) }
  end

  # One case through the gem's payment check (Payments.check_onchain, Payments.combine), with
  # `read_merchant_acceptance` as the check's read of the merchant's acceptance; then the acceptance
  # record it publishes (Acceptances.publish).
  def payment_case(item, read_merchant_acceptance, node = nil)
    mutex = Mutex.new
    asked = []
    published = []
    base = node ? NodeUrl.parse(node.url).rest : Protocol::MEMPOOL_URL
    fake = FakeHttp.new { |uri| mutex.synchronize { chain_route(item, uri, asked, base) } }
    rests = rests_of(item)
    now = item["now"].to_i
    # The witnesses the check published, as the relays then hold them.
    published_events = []
    reads = 0
    read_witnesses = lambda do |_every_relay|
      # The first read, then the one after publishing: the vector's witnesses again, unless it
      # says, and those the check published.
      again = reads.positive?
      reads += 1
      held = again ? (item["witnessesAgain"] || item["witnesses"]) : item["witnesses"]
      raise NetworkError, "Fewer than a majority of the merchant's relays answered" if held == "unreadable"

      # What the relays sent to the read (`address` "other": of no invoice of the read, which a
      # relay sent anyway), read as Witnesses.read_of_order reads it.
      sent = held.map { |w| witness_event(w, now - 1) }
      sent += mutex.synchronize { published_events.dup } if again && item["witnessesAgain"].nil?
      Witnesses.of_order(sent, PAYMENT_SEEN, ADDRESS, SALE, EXPIRES_AT)
    end
    publish = lambda do |witness|
      raise NetworkError, "Fewer than a majority took the witness" if item["publishFails"]

      mutex.synchronize do
        published << { "txid" => witness.txid, "sale" => witness.sale.nil? ? nil : "this",
                       "replacement" => witness.replacement, "address" => witness.address,
                       "expiresAt" => witness.expires_at }
        published_events << Witnesses.event(PAYMENT_SEEN, witness, now, RANDOM).to_h
      end
    end
    logger = TestLogger.new
    read_it = false
    check = Payments::Check.new(
      address: ADDRESS, sats: SATS, expires_at: EXPIRES_AT, sale: SALE, clock: -> { now }, http: http(fake),
      explorer: CallExplorer.new(node, NodeFailures.new, -> { now }), read_witnesses: read_witnesses,
      witness_address: method(:witness_at), publish: publish, logger: logger,
      paid_by_rests: -> { Payments.rest_summary(rests).paid }, tolerance: -> { Tolerance.of(item["tolerance"]) },
      read_merchant_acceptance: lambda {
        read_it = true
        read_merchant_acceptance.call
      }
    )
    onchain = begin
      Settled.ok(Payments.check_onchain(check, Stop.new(Cancellation::NONE)))
    rescue StandardError => e
      Settled.failed(e)
    end
    lightning = item["lightning"]
    lightning = if lightning.nil?
                  nil
                elsif lightning.key?("error")
                  Settled.failed(error_of(lightning["error"]))
                else
                  Settled.ok(part_of(lightning))
                end
    status = nil
    result = outcome do
      status = Payments.combine(Payments::Terms.new(sats: SATS, expires_at: EXPIRES_AT, address: ADDRESS), now,
                                lightning, onchain, rests)
      status.to_h
    end
    assert_equal item["expected"], result
    failed = item["expected"].key?("error")
    unless failed
      # Published at once: in any order.
      published.each do |witness|
        assert_equal ADDRESS, witness.delete("address")
        # Of this invoice: its expiresAt; of none: null.
        assert_value(witness["sale"].nil? ? nil : EXPIRES_AT, witness.delete("expiresAt"))
      end
      order = ->(witness) { [witness["txid"], witness["sale"].to_s, witness["replacement"].to_s] }
      assert_equal item["published"].sort_by(&order), published.sort_by(&order)
    end
    assert_equal item["asked"], asked
    # The explorer read alone, and BlockCypher: no other explorer asked.
    assert_empty(fake.calls.map(&:url).reject { |url| url.start_with?("#{base}/", "#{Protocol::BLOCKCYPHER_URL}/") })
    # The acceptance record the check publishes, unless the relays hold one of what it received or
    # less (SPEC.md §31, "Acceptance records"); none when the status is an error.
    assert_value item["acceptance"], (acceptance_published(status, now, item["accepted"]) unless failed)
    # A merchant's acceptance of a newer format is logged when the check read it, whatever its date
    # and however many relays sent it.
    accepted = item["merchantAccepted"]
    newer = accepted.is_a?(Array) && accepted.any? { |record| record["newer"] }
    assert_equal(newer && read_it ? 1 : 0, logger.messages.count(MerchantAcceptances::NEWER_FORMAT))
  end

  # The rest keys of the invoice, for an order of the app's sale.
  PAYMENT_REST = Derive.rest_keys(Text.hex_bytes(APP["parsed"]["integrationKey"]), APP["declaration"]["ref"], ADDRESS,
                                  EXPIRES_AT)

  # What the check publishes of an acceptance record when its status is `status` (SPEC.md §31,
  # "Acceptance records"), as the client does (Acceptances.publish), on three local relays each of
  # which holds one of `accepted` (nil: none holds one), so that every majority that answers reads
  # it: the `received` of the records the relays took, nil when none.
  def acceptance_published(status, now, accepted)
    net = RelayNet.new
    urls = %w[wss://acceptance-1.test wss://acceptance-2.test wss://acceptance-3.test]
    relays = urls.map { |url| net.add(url) }
    if accepted
      held = Acceptances.record_event(keys: PAYMENT_REST, received: Integer(accepted, 10), expires_at: EXPIRES_AT,
                                      created_at: now - 60, random: RANDOM)
      relays.each { |relay| relay.store(held) }
    end
    pool = Relay::Pool.new(websocket: net.websocket_client, timeout_ms: 2000, stop: Stop.new(Cancellation::NONE),
                           random: RANDOM, now: -> { now })
    begin
      Acceptances.publish(pool, status, sats: SATS, expires_at: EXPIRES_AT, now: now, keys: -> { PAYMENT_REST },
                                        relays: urls, clock: -> { now }, random: RANDOM, logger: QUIET,
                                        stop: Stop.new(Cancellation::NONE))
    ensure
      pool.close
    end
    took = relays.flat_map(&:received).map do |event|
      opened = Acceptances.open_record(event, PAYMENT_REST, SATS)
      opened.is_a?(Acceptances::Opened) ? opened.received.to_s : opened.inspect
    end.uniq
    assert_operator took.size, :<=, 1
    took.first
  ensure
    net&.close
  end

  # relay-reads.json

  reads = vectors("relay-reads.json")

  test "relay-reads.json: has the page's limit and the pages of a read" do
    assert_equal [reads["limit"], reads["pages"]], [Protocol::COMPLETE_READ_LIMIT, Protocol::MAX_PAGES]
  end

  # What a pool reads of one relay: each page through after_complete_page; a page that fails ends
  # the read incomplete, the first one the relay's failure.
  each_case("relay-reads.json cases", reads["cases"]) do |item|
    seen = {}
    kept = []
    untils = [nil]
    finish = nil
    page = 1
    while finish.nil?
      answer = item["pages"][page - 1]
      if answer == "fails"
        finish = { "answered" => page > 1, "complete" => false }
        break
      end
      # Every event kept: the vector counts each id once, whatever opens.
      entries = answer.map do |id, created_at|
        Relay.entry_of({ "id" => id, "created_at" => created_at }, lambda { |value|
          value
        })
      end
      kind, value = Relay.after_complete_page(entries, seen, kept, page)
      if kind == :complete
        finish = { "answered" => true, "complete" => value }
      else
        untils << value
      end
      page += 1
    end
    assert_equal item["expected"], { "untils" => untils, **finish, "kept" => kept.size }
  end

  # What a complete read of a list gives from each relay's read: Relay.outcome, by which the pool's
  # reads decide (end to end, on local relays: test/relay_reads_test.rb).
  each_case("relay-reads.json lists", reads["lists"]) do |item|
    assert_equal item["expected"], Relay.outcome(item["relays"].map(&:to_sym)).complete
  end

  # What a pool's paged read takes of one relay: each page through after_paged_page, at most
  # MAX_PAGES; a page that fails ends the read with what it read, the first one the relay's failure.
  each_case("relay-reads.json paged", reads["paged"]) do |item|
    seen = {}
    kept = []
    untils = [nil]
    answered = true
    Protocol::MAX_PAGES.times do |page|
      answer = item["pages"][page]
      if answer == "fails"
        answered = page.positive?
        break
      end
      # Every event kept: the vector counts each id once, whatever opens.
      entries = answer.map { |id, created_at| Relay.entry_of({ "id" => id, "created_at" => created_at }, ->(v) { v }) }
      following = Relay.after_paged_page(entries, seen, kept)
      break if following.nil?

      untils << following if page + 1 < Protocol::MAX_PAGES
    end
    assert_equal item["expected"], { "untils" => untils, "answered" => answered, "kept" => kept.size }
  end

  # The reads of `cases` and `paged` on a pool (Relay::Pool), over the gem's WebSocket client: a
  # local relay answers the read's queries in turn with the vector's pages, whatever they ask, and
  # "fails" with a CLOSED. The block reads with the pool from the relay's URL. [what it read, the
  # `until` of each query the relay received, how many events the read kept of it].
  def on_pool(pages)
    net = RelayNet.new
    url = "wss://relay.test"
    relay = net.add(url, pages: pages.map do |page|
      page == "fails" ? page : page.map { |id, created_at| { "id" => id, "created_at" => created_at } }
    end)
    pool = Relay::Pool.new(websocket: net.websocket_client, timeout_ms: 5000, stop: Stop.new(Cancellation::NONE),
                           random: RANDOM, now: -> { 1_791_378_000 })
    read = yield pool, url
    [read, relay.queries.map { |filter| filter["until"] }, read.answers.fetch(url, []).size]
  ensure
    pool&.close
    net&.close
  end

  each_case("relay-reads.json cases, on a pool", reads["cases"]) do |item|
    read, untils, kept = on_pool(item["pages"]) do |pool, url|
      pool.query_complete([url], { "kinds" => [30_078] }, "\x00".b * 32, keep: ->(value) { value })
    end
    assert_equal item["expected"],
                 { "untils" => untils, "answered" => read.answered, "complete" => read.complete,
                   "kept" => kept }
  end

  each_case("relay-reads.json paged, on a pool", reads["paged"]) do |item|
    read, untils, kept = on_pool(item["pages"]) do |pool, url|
      pool.query_relays([url], { "kinds" => [30_078] }, "\x00".b * 32, paged: true, keep: ->(v) { v })
    end
    assert_equal item["expected"], { "untils" => untils, "answered" => read.answered, "kept" => kept }
  end

  # What a read on every relay gives from each relay's read when it went on, only the relays whose
  # read ended having answered: Relay.outcome, by which the pool's reads decide (end to end, on local
  # relays: test/relay_reads_test.rb).
  each_case("relay-reads.json onEveryRelay", reads["onEveryRelay"]) do |item|
    outcome = Relay.outcome(item["relays"].map(&:to_sym))
    assert_equal item["expected"], { "answered" => outcome.answered, "complete" => outcome.complete }
  end

  # onchain-tolerances.json

  tolerances = vectors("onchain-tolerances.json")

  each_case("onchain-tolerances.json values", tolerances["values"]) do |item|
    assert_equal item["expected"], Tolerance.of(item["value"])
  end

  each_case("onchain-tolerances.json accepted", tolerances["accepted"],
            ->(item) { "#{item["expected"]} of #{item["sats"]} at #{item["tolerance"]}" }) do |item|
    assert_equal item["expected"], Tolerance.least_accepted(Integer(item["sats"], 10), item["tolerance"]).to_s
  end

  each_case("onchain-tolerances.json due", tolerances["due"],
            lambda { |item|
              "#{item["expected"]} of #{item["sats"]} at #{item["tolerance"]}, #{item["paidByRests"]} by rests, " \
                "accepted #{item["merchantAccepted"]}"
            }) do |item|
    accepted = item.key?("merchantAccepted") ? Integer(item["merchantAccepted"], 10) : nil
    due = Tolerance.due_onchain(Integer(item["sats"], 10), item["tolerance"], Integer(item["paidByRests"], 10),
                                accepted)
    assert_equal item["expected"], due.to_s
  end

  # earlier-invoices.json

  earlier = vectors("earlier-invoices.json")
  EARLIER_SATS = 49_000
  PRICE = { "minor" => 49_000, "digits" => 0, "currency" => "SAT" }.freeze

  # The records as the sale opens them. `d`: the address itself, one per address.
  def event_of(event)
    Event.new(id: event["id"], pubkey: nil, created_at: event["createdAt"].to_i, kind: nil, tags: [], content: nil,
              sig: nil)
  end

  def declaration_of(declared)
    created_at = declared["createdAt"].to_i
    decoded = Bolt11::Invoice.new(network: "bc", amount_msat: EARLIER_SATS * 1000, timestamp: created_at,
                                  expiry_seconds: declared["expiresAt"].to_i - created_at,
                                  payment_hash: declared["paymentHash"], description_hash: nil)
    event = event_of({ "createdAt" => declared["declaredAt"], "id" => declared["paymentHash"] })
    Declarations::Opened.new(event: event,
                             invoice: declared["invoice"], decoded: decoded, verify_url: "https://example.com/verify",
                             price: PRICE, note: "order", declared_at: declared["declaredAt"].to_i,
                             rest: declared["rest"] ? Declarations::RestOf.new(address: "", expires_at: 0) : nil)
  end

  def record_of(record)
    return { kind: :withdrawn, event: event_of(record["event"]), d: record["address"] } if record["withdrawn"]
    return { kind: :newer, event: event_of(record["event"]), d: record["address"] } if record["newer"]

    terms = Leases::Terms.new(address: record["address"], sats: EARLIER_SATS, invoice: record["invoice"],
                              verify_url: record["invoice"].nil? ? nil : "https://example.com/verify",
                              created_at: record["createdAt"].to_i, expires_at: record["expiresAt"].to_i, price: PRICE,
                              note: "order", tolerance: 0,
                              confirmed: record.key?("confirmed") ? record["confirmed"] : nil)
    { kind: :lease, lease: Leases::Opened.new(event: event_of(record["event"]), d: record["address"], terms: terms,
                                              inside: {}) }
  end

  each_case("earlier-invoices.json", earlier["cases"]) do |item|
    list = (item["relays"] || earlier["relays"]).to_i
    expected = item["expected"]
    declared = Sales.invoices_of("order", item["declarations"].map { |d| declaration_of(d) },
                                 Sales.newest_records(item["records"].map { |r| record_of(r) }))
    invoices = declared.map(&:invoice)
    assert_equal expected["invoices"], (invoices.map do |invoice|
      { "paymentHash" => invoice.payment_hash, "onchainAddress" => invoice.onchain_address,
        "createdAt" => invoice.created_at, "declaredAt" => invoice.declared_at }
    end)
    may_be_paid = Sales.may_still_be_paid(invoices, item["now"].to_i)
    assert_equal expected["mayBePaid"], may_be_paid
    # Every one that may still be paid is checked, even alone.
    assert_equal expected["checked"], may_be_paid
    if may_be_paid.empty?
      assert_nil item["statuses"]
      assert_nil expected["outcome"]
      next
    end
    # What a read on every relay sent: each event's sentBy, all the relays when absent; nothing when
    # fewer than a majority answered it.
    sent_by = {}
    item["declarations"].each { |d| sent_by[d["paymentHash"]] = (d["sentBy"] || list).to_i }
    item["records"].each { |r| sent_by[r["event"]["id"]] = (r["sentBy"] || list).to_i }
    held = (Sales.held(may_be_paid.map { |index| declared[index] }, sent_by, list) unless item["readFails"])
    settled = may_be_paid.map do |index|
      status = item["statuses"][index]
      if status.key?("state")
        Settled.ok(PaymentStatus.new(state: status["state"], received: status["received"]))
      else
        Settled.failed(status)
      end
    end
    kind, index = Sales.pending_outcome(settled, held)
    shown = case kind
            when :paid then { "orderPaid" => may_be_paid[index] }
            when :failed then settled[index].error
            when :unread then { "error" => "network" }
            else { "handOut" => may_be_paid[index] }
            end
    assert_equal expected["outcome"], shown
  end
end
