# frozen_string_literal: true

require_relative "test_helper"

# The gem against vectors/onchain-rests.json (SPEC.md §31, "The rest of an underpayment"): the rest
# keys of an order's invoice, the rest records and acceptance records the page reads, the
# declarations of invoices of the rest, and when a check asks for an invoice of the rest. Read
# only: these vectors are written in checkout-spec.
class RestVectorsTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTORS = SpecVectors.read("vectors/onchain-rests.json")
  INTEGRATION_KEY = Text.hex_bytes(VECTORS["integrationKey"])
  ADDRESS = VECTORS["keys"][0]["address"]

  def self.each_case(file, cases, name = ->(item) { item["name"] }, &block)
    cases.each_with_index do |item, index|
      test("#{file} #{index}: #{name.call(item)}") { instance_exec(item, &block) }
    end
  end

  # The rest keys of the order ORD-1042's invoice with the vectors' address and end.
  def link_keys
    Derive.rest_keys(INTEGRATION_KEY, "ORD-1042", ADDRESS, VECTORS["records"]["link"]["expiresAt"].to_i)
  end

  each_case("onchain-rests.json keys", VECTORS["keys"],
            ->(item) { "#{item["ref"]}, #{item["address"]} and #{item["expiresAt"]}" }) do |item|
    keys = Derive.rest_keys(INTEGRATION_KEY, item["ref"], item["address"], item["expiresAt"].to_i)
    assert_equal({ "restKey" => item["restKey"], "restSecret" => item["restSecret"], "restAuthor" => item["restAuthor"],
                   "restEncryptionKey" => item["restEncryptionKey"], "records" => item["records"],
                   "acceptanceAddress" => item["acceptanceAddress"] },
                 { "restKey" => to_hex(keys.key), "restSecret" => to_hex(keys.secret_key), "restAuthor" => keys.author,
                   "restEncryptionKey" => to_hex(keys.encryption_key),
                   "records" => item["records"].map do |record|
                     { "paymentHash" => record["paymentHash"],
                       "address" => Derive.rest_record_address(keys.key, record["paymentHash"]) }
                   end,
                   "acceptanceAddress" => Derive.acceptance_record_address(keys.key) })
  end

  records = VECTORS["records"]

  each_case("onchain-rests.json records", records["cases"]) do |item|
    keys = link_keys
    assert_equal records["restKey"], to_hex(keys.key)
    link = records["link"]
    terms = Rests::LinkTerms.new(sats: Integer(link["sats"], 10), created_at: link["createdAt"].to_i,
                                 expires_at: link["expiresAt"].to_i)
    opened = Rests.open_record(item["event"], keys.with(author: records["restAuthor"]), terms)
    read = if opened.nil? || opened == :newer
             opened&.to_s
           else
             { "invoice" => opened.invoice.bolt11, "paymentHash" => opened.invoice.payment_hash,
               "verifyUrl" => opened.invoice.verify_url, "sats" => opened.invoice.sats.to_s }
           end
    assert_value item["expected"], read
  end

  acceptances = VECTORS["acceptances"]

  each_case("onchain-rests.json acceptances", acceptances["cases"]) do |item|
    keys = link_keys
    assert_equal [acceptances["restKey"], acceptances["restAuthor"]], [to_hex(keys.key), keys.author]
    opened = Acceptances.open_record(item["event"], keys, Integer(acceptances["link"]["sats"], 10))
    read = opened.nil? || opened == :newer ? opened&.to_s : { "received" => opened.received.to_s }
    assert_value item["expected"], read
  end

  declarations = VECTORS["declarations"]

  each_case("onchain-rests.json declarations", declarations["cases"]) do |item|
    sale = Derive.sale(INTEGRATION_KEY, Derive.registry(declarations["registryKey"], declarations["registryReader"]),
                       declarations["ref"])
    opened = Declarations.open(item["event"], sale)
    read = opened && { "invoice" => opened.invoice, "note" => opened.note,
                       "rest" => opened.rest && { "address" => opened.rest.address,
                                                  "expiresAt" => opened.rest.expires_at } }
    assert_value item["expected"], read
  end

  each_case("onchain-rests.json asking", VECTORS["asking"]) do |item|
    invoices = item["rests"].map do |rest|
      Rests::Invoice.new(bolt11: rest["id"], payment_hash: rest["paymentHash"], verify_url: "https://breez.tips/verify",
                         sats: Integer(rest["sats"], 10), created_at: rest["createdAt"].to_i,
                         expires_at: rest["expiresAt"].to_i)
    end
    paid = invoices.each_with_index.filter_map do |invoice, index|
      [invoice.payment_hash, true] if item["rests"][index]["paid"]
    end
    paid = paid.to_h
    sats = Integer(item["sats"], 10)
    expires_at = item["expiresAt"].to_i
    now = item["now"].to_i
    rest = Rests.rest_of(sats: sats, expires_at: expires_at, address: ADDRESS, received: Integer(item["received"], 10),
                         now: now, rests: invoices, paid: paid)
    lease = item["lease"] && Payments::Terms.new(sats: Integer(item["lease"]["sats"], 10),
                                                 expires_at: item["lease"]["expiresAt"].to_i, address: ADDRESS)
    ask = Rests.to_ask(rest: rest, sats: sats, expires_at: expires_at, now: now, lease: lease)
    bounds = [Integer(item["sendable"]["min"], 10), Integer(item["sendable"]["max"], 10)]
    ask = nil if ask && !Rests.sendable?(ask.sats, bounds)
    assert_equal item["expected"],
                 { "rest" => rest && { "sats" => rest.sats, "invoice" => rest.bolt11 },
                   "ask" => ask && { "sats" => ask.sats.to_s, "expirySeconds" => ask.expiry_seconds } }
  end
end
