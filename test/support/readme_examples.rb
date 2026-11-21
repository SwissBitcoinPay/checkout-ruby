# frozen_string_literal: true

# Runs the Ruby examples of README.md as they are written, against the tests' world: local relays,
# fakes of breez.tips, of the rate sources and of the explorers. Only the network is replaced: each
# Client an example makes is given the world's HTTP and WebSocket clients and clock, unless the
# example gives its own, and Net::HTTP.get_response answers the custom rate source's example.
# Prints each example's outcome; exits 1 when one does not run as the README says. In a process
# of its own (test/readme_test.rb): it changes Client and Net::HTTP for the whole process.
#
#   ruby -Ilib -Itest test/support/readme_examples.rb

require "sattleme/checkout"
require_relative "merchant"
require "net/http"
require "json"

README = File.read(File.expand_path("../../README.md", __dir__), encoding: "UTF-8")
BLOCKS = README.scan(/^```ruby\n(.*?)^```/m).flatten

LOT = [TestChain.deposit_address(1), TestChain.deposit_address(2), TestChain.deposit_address(3)].freeze
WORLD = TestMerchant.new.start
WORLD.publish_channel(WORLD.channel_value(100, { "relays" => WORLD.key_relays,
                                                 "checkout" => { "origin" => "https://pay.example" } }), 100)
WORLD.publish_lot(LOT, 90)
ENV["SATTLEME_INTEGRATION_KEY"] = WORLD.key

# The world's network for every client an example makes (what it does not give).
module TestWorld
  def initialize(**)
    defaults = { http_client: WORLD.http, websocket_client: WORLD.net.websocket_client, now: -> { WORLD.now },
                 relay_timeout_ms: 2000 }
    super(**defaults, **)
  end
end
Sattleme::Checkout::Client.prepend(TestWorld)

# rates.example.ch, the custom source's own service in the README.
module RatesExample
  def get_response(uri, *rest, **options)
    return super unless uri.host == "rates.example.ch"

    Struct.new(:code, :body).new("200", JSON.generate({ "price" => "69012.50", "time" => WORLD.now - 5 }))
  end
end
Net::HTTP.singleton_class.prepend(RatesExample)

# An order of the shop, as the Quick start uses it.
Order = Struct.new(:ref, :number, :invoice, :paid_with) do
  def update!(invoice:) = (self.invoice = invoice)
  def mark_paid!(status) = (self.paid_with = status)
end

# What the examples call of Rails.
module Rails
  def self.logger = Object.new.tap { |quiet| def quiet.info(_message) = nil }
end

# Runs `code`: nil when it ran as the README says (raising `expected` when given), else its name.
def run(name, code, scope, expected: nil)
  eval(code, scope, "README.md (#{name})") # rubocop:disable Security/Eval
  return "#{name} (no #{expected})" if expected

  puts "ran: #{name}"
  nil
rescue Exception => e # rubocop:disable Lint/RescueException
  if expected && e.is_a?(expected)
    puts "ran: #{name}: #{e.class}, as the README says"
    return nil
  end
  puts "FAILS: #{name}: #{e.class}: #{e.message}"
  name
end

failures = []
scope = binding
failures << run("Quick start", BLOCKS[1], scope)
order = Order.new("ORD-1", 1)
scope.local_variable_set(:order, order)
failures << run("Quick start: invoice_of and status_of", "invoice_of(order); status_of(order)", scope)
# wait_for_payment in a job, the invoice paid meanwhile.
WORLD.pay_invoice(Sattleme::Checkout::Invoice.from_json(order.invoice).payment_hash)
failures << run("wait_for_payment", BLOCKS[3], scope)
# Checkout links, prices in a currency (the default list asks CoinGecko first).
WORLD.override = lambda do |url|
  next unless url.host == "api.coingecko.com"

  FakeHttp.answer({ "bitcoin" => { "chf" => 69_012, "last_updated_at" => WORLD.now - 30 } })
end
failures << run("a checkout link", BLOCKS[4], scope)
failures << run("a price in a currency", BLOCKS[5], scope)
# Rate sources (key, ref, fiat as the example names them).
scope.local_variable_set(:key, WORLD.key)
scope.local_variable_set(:ref, "ORD-1044")
scope.local_variable_set(:fiat, { amount: "24.50", currency: "CHF" })
WORLD.override = lambda do |url|
  next unless url.host == "mempool.space" && url.path == "/api/v1/prices"

  FakeHttp.answer({ "time" => WORLD.now - 30, "CHF" => 69_012 })
end
failures << run("rate sources", BLOCKS[6], scope)
WORLD.override = nil
failures << run("a custom rate source", BLOCKS[7], scope)
failures << run("an order with the custom source",
                'SATTLEME.create_invoice(ref: "ORD-1045", fiat: { amount: "24.50", currency: "CHF" })', scope)
# Cancellation (its 5 s made 0.2 s: the example's wait never ends otherwise).
cancelled = Sattleme::Checkout::Client.new(key: WORLD.key).create_invoice(ref: "ORD-1046", sats: 600)
scope.local_variable_set(:invoice, cancelled)
failures << run("cancellation", BLOCKS[8].sub("sleep 5", "sleep 0.2").sub(/\n# Or bounded.*\z/m, ""), scope,
                expected: Sattleme::Checkout::Cancelled)
failures << run("options", BLOCKS[9], scope)
WORLD.stop
failures.compact!
if failures.empty?
  puts "every example ran"
else
  puts "FAILS: #{failures.join(", ")}"
  exit 1
end
