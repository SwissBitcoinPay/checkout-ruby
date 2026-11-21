# frozen_string_literal: true

require_relative "test_helper"

# get_status and wait_for_payment of an invoice without an address (SPEC.md §22, §23): its
# Lightning part, from breez.tips's LUD-21 answers.
class PaymentTest < Minitest::Test
  include TestHelpers

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100), 100)
    @client = client
    @invoice = @client.create_invoice(ref: "P-1", sats: 2100, duration_seconds: 600)
  end

  def teardown
    @merchant.stop
  end

  def client(logger = QUIET)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, logger: logger)
  end

  # breez.tips's verify answer for the invoice, replaced.
  def verify_answers(json, status = 200)
    @merchant.override = ->(url) { url.path.include?("/verify/") ? FakeHttp.answer(json, status) : nil }
  end

  def made = @merchant.invoices.fetch(@invoice.payment_hash)

  # get_status

  test "is open, then paid with the preimage, the proof of payment" do
    assert_equal({ "state" => "open", "expiresAt" => @invoice.expires_at, "received" => "0", "rest" => nil },
                 @client.get_status(@invoice).to_h)
    @merchant.pay_invoice(@invoice.payment_hash)
    assert_equal({ "state" => "paid", "method" => "lightning", "preimage" => made.preimage },
                 @client.get_status(@invoice).to_h)
    # A look, without state: from the stored invoice, as JSON (its text, or the Hash of it).
    assert_predicate @client.get_status(@invoice.to_json), :paid?
    assert_predicate @client.get_status(Sattleme::Checkout::Internal::Json.parse(@invoice.to_json)), :paid?
  end

  test "reads the invoice whatever its case, and an upper-case preimage" do
    verify_answers({ "status" => "OK", "settled" => true, "preimage" => made.preimage.upcase, "pr" => made.pr.upcase })
    assert_equal({ "state" => "paid", "method" => "lightning", "preimage" => made.preimage },
                 @client.get_status(@invoice).to_h)
  end

  test "refuses an answer about another invoice, and a wrong preimage" do
    paid = made
    other = @client.create_invoice(ref: "P-2", sats: 2100, duration_seconds: 600)
    [{ "status" => "OK", "settled" => true, "preimage" => paid.preimage, "pr" => other.bolt11 },
     { "status" => "OK", "settled" => true, "preimage" => "11" * 32, "pr" => paid.pr },
     { "status" => "OK", "settled" => true, "preimage" => nil, "pr" => paid.pr },
     { "status" => "OK", "settled" => true, "preimage" => paid.preimage }].each do |json|
      verify_answers(json)
      assert_raises(InvalidInvoiceError) { @client.get_status(@invoice) }
    end
  end

  test "is expired 120 s after the invoice's end, not before" do
    @merchant.now = @invoice.expires_at + 119
    assert_predicate @client.get_status(@invoice), :open?
    @merchant.now = @invoice.expires_at + 120
    assert_equal({ "state" => "expired", "received" => "0" }, @client.get_status(@invoice).to_h)
  end

  test "is expired on \"Not found\" after the grace only" do
    verify_answers({ "status" => "ERROR", "reason" => "Not found" })
    @merchant.now = @invoice.expires_at + 119
    assert_predicate @client.get_status(@invoice), :open?
    @merchant.now = @invoice.expires_at + 120
    assert_equal({ "state" => "expired", "received" => "0" }, @client.get_status(@invoice).to_h)
    verify_answers({ "status" => "ERROR", "reason" => "Not found" }, 404)
    assert_equal({ "state" => "expired", "received" => "0" }, @client.get_status(@invoice).to_h)
  end

  test "keeps the invoice open on any other error before the grace, retries after" do
    verify_answers({ "status" => "ERROR", "reason" => "Internal server error" })
    assert_predicate @client.get_status(@invoice), :open?
    @merchant.now = @invoice.expires_at + 600
    assert_raises(NetworkError) { @client.get_status(@invoice) }
  end

  test "throws NetworkError, retryable, when breez.tips does not answer" do
    [500, 502, 429].each do |status|
      verify_answers({ "status" => "ERROR", "reason" => "Not found" }, status)
      error = assert_raises(NetworkError) { @client.get_status(@invoice) }
      assert_predicate error, :retryable?
    end
    @merchant.override = lambda do |url|
      raise SocketError, "fetch failed" if url.path.include?("/verify/")
    end
    assert_raises(NetworkError) { @client.get_status(@invoice) }
    @merchant.override = ->(url) { url.path.include?("/verify/") ? { status: 200, text: "<html>" } : nil }
    assert_raises(NetworkError) { @client.get_status(@invoice) }
  end

  test "refuses a stored invoice that is not what create_invoice gave" do
    [@invoice.with(payment_hash: "00" * 32), @invoice.with(expires_at: @invoice.expires_at + 3600),
     @invoice.with(verify_url: "http://breez.tips/x"), @invoice.with(bolt11: "lnbc1")].each do |changed|
      error = assert_raises(InvalidOrderError) { @client.get_status(changed) }
      assert_equal "invoice", error.param
    end
  end

  # wait_for_payment

  test "checks until the invoice is paid, network errors retried" do
    seen = []
    calls = 0
    mutex = Mutex.new
    @merchant.override = lambda do |url|
      next nil unless url.path.include?("/verify/")

      call = mutex.synchronize { calls += 1 }
      raise SocketError, "fetch failed" if call == 2

      @merchant.pay_invoice(@invoice.payment_hash) if call == 3
      nil
    end
    final = @client.wait_for_payment(@invoice, interval_ms: 250) { |status| seen << status.state }
    assert_predicate final, :paid?
    assert_equal %w[open paid], seen
  end

  test "takes its listener as on_status: too, never with a block" do
    seen = []
    @merchant.pay_invoice(@invoice.payment_hash)
    assert_predicate @client.wait_for_payment(@invoice, interval_ms: 250, on_status: ->(status) { seen << status }),
                     :paid?
    assert_equal 1, seen.size
    error = assert_raises(InvalidOptionError) do
      @client.wait_for_payment(@invoice, on_status: ->(_) {}) { |_| nil }
    end
    assert_equal "on_status", error.param
  end

  test "logs a failure each check meets again once, and again only after it stopped" do
    logger = TestLogger.new
    logged = client(logger)
    # Down for 3 checks, up for 1, down for 2 again, then paid.
    down = [true, true, true, false, true, true]
    calls = 0
    mutex = Mutex.new
    @merchant.override = lambda do |url|
      next nil unless url.path.include?("/verify/")

      call = mutex.synchronize { calls += 1 }
      @merchant.pay_invoice(@invoice.payment_hash) if call > down.size
      down[call - 1] ? { status: 503, text: "down" } : nil
    end
    assert_predicate logged.wait_for_payment(@invoice, interval_ms: 250), :paid?
    assert_equal down.size + 1, calls
    message = "sattleme-checkout: the payment check failed (breez.tips answered HTTP 503 without an LNURL " \
              "answer); checked again"
    assert_equal [message, message], logger.messages
  end

  test "stops at expired" do
    @merchant.now = @invoice.expires_at + 120
    assert_equal({ "state" => "expired", "received" => "0" }, @client.wait_for_payment(@invoice, interval_ms: 250).to_h)
  end

  test "stops when its cancellation is cancelled" do
    cancellation = Cancellation.new
    Thread.new do
      sleep 0.3
      cancellation.cancel("order cancelled")
    end
    error = assert_raises(Cancelled) do
      @client.wait_for_payment(@invoice, interval_ms: 250, cancellation: cancellation)
    end
    assert_equal ["order cancelled", "order cancelled"], [error.message, error.reason]
  end

  test "stops on an answer that is not about this invoice" do
    verify_answers({ "status" => "OK", "settled" => false, "pr" => "lnbc1other" })
    assert_raises(InvalidInvoiceError) { @client.wait_for_payment(@invoice, interval_ms: 250) }
  end
end
