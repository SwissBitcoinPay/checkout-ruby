# frozen_string_literal: true

require_relative "test_helper"

# The gem's cancellation (SPEC.md §4: every method takes one): a call cancelled stops its requests
# and raises Cancelled, never an Error of SPEC.md §5.
class CancellationTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  def setup
    @merchant = TestMerchant.new.start
    @merchant.publish_channel(@merchant.channel_value(100), 100)
  end

  def teardown
    @merchant.stop
  end

  def client(**)
    Client.new(key: @merchant.key, http_client: @merchant.http, websocket_client: @merchant.net.websocket_client,
               now: -> { @merchant.now }, relay_timeout_ms: 5000, logger: QUIET, **)
  end

  test "is cancelled once, with the first reason" do
    cancellation = Cancellation.new
    refute_predicate cancellation, :cancelled?
    assert_nil cancellation.reason
    assert_same cancellation, cancellation.cancel("first")
    cancellation.cancel("second")
    assert_predicate cancellation, :cancelled?
    assert_equal "first", cancellation.reason
    error = assert_raises(Cancelled) { cancellation.raise_if_cancelled }
    assert_equal %w[first first], [error.message, error.reason]
    # A reason that is not a String is kept, its message the default.
    other = Cancellation.new.cancel(:timeout)
    error = assert_raises(Cancelled) { other.raise_if_cancelled }
    assert_equal [:timeout, "The call was cancelled"], [error.reason, error.message]
  end

  test "is no Error of the gem: a program tells a cancellation from a failure" do
    refute_operator Cancelled, :<=, Sattleme::Checkout::Error
    assert_operator Cancelled, :<=, StandardError
  end

  test "waits until it is cancelled, or for a time" do
    cancellation = Cancellation.new
    started = Clock.now
    refute cancellation.wait(0.05)
    assert_operator Clock.now - started, :>=, 0.04
    Thread.new do
      sleep 0.05
      cancellation.cancel
    end
    assert cancellation.wait(5)
  end

  test "runs its callbacks once, at once when it is cancelled already, and forgets those removed" do
    cancellation = Cancellation.new
    heard = []
    cancellation.on_cancel { heard << :a }
    handle = cancellation.on_cancel { heard << :b }
    cancellation.remove(handle)
    # A callback that fails stops none of the others.
    cancellation.on_cancel { raise "broken" }
    cancellation.on_cancel { heard << :c }
    cancellation.cancel
    cancellation.cancel
    assert_equal %i[a c], heard
    cancellation.on_cancel { heard << :late }
    assert_equal %i[a c late], heard
  end

  test "cancels itself after a time" do
    cancellation = Cancellation.after(0.05, "too long")
    assert cancellation.wait(5)
    assert_equal "too long", cancellation.reason
    assert_raises(ArgumentError) { Cancellation.after(-1) }
    assert_raises(ArgumentError) { Cancellation.after("1") }
  end

  test "cancels each in its time, the earliest first, whatever the order they were made in" do
    late = Cancellation.after(3, "late")
    early = Cancellation.after(0.2, "early")
    assert early.wait(10)
    assert_equal "early", early.reason
    refute_predicate late, :cancelled?
    assert late.wait(10)
    assert_equal "late", late.reason
  end

  # How many threads of the gem wait for deadlines now.
  def timers = Thread.list.count { |thread| thread.name == "sattleme-checkout timer" && thread.alive? }

  test "waits for every deadline in one thread, which ends once none is left" do
    eventually { timers.zero? }
    before = Thread.list.size
    # 50 calls bounded in time, each done long before: one thread waits for all of them, not 50.
    bounded = Array.new(50) { Cancellation.after(60) }
    assert_operator Thread.list.size, :<=, before + 1
    assert_equal 1, timers
    # Those cancelled before their time are forgotten: once none is left, the thread ends.
    bounded.each { |cancellation| cancellation.cancel("done") }
    eventually { timers.zero? }
    assert_equal ["done"], bounded.map(&:reason).uniq
    # And starts again with the next deadline.
    assert Cancellation.after(0.05, "again").wait(10)
    eventually { timers.zero? }
  end

  test "NONE is never cancelled" do
    assert_raises(FrozenError) { Cancellation::NONE.cancel }
    refute_predicate Cancellation::NONE, :cancelled?
    assert_nil(Cancellation::NONE.on_cancel { flunk "never" })
  end

  test "stops every method at once when it was cancelled before the call, asking nothing" do
    cancelled = Cancellation.new.cancel("before")
    invoice = client.create_invoice(ref: "C-0", sats: 1)
    calls = @merchant.http.calls.size
    connections = @merchant.net.connections
    [-> { client.merchant(cancellation: cancelled) },
     -> { client.create_invoice(ref: "C-1", sats: 1, cancellation: cancelled) },
     -> { client.get_status(invoice, cancellation: cancelled) },
     -> { client.wait_for_payment(invoice, cancellation: cancelled) },
     -> { client.find_invoices("C-0", cancellation: cancelled) }].each do |call|
      assert_equal "before", assert_raises(Cancelled) { call.call }.reason
    end
    assert_equal calls, @merchant.http.calls.size
    assert_equal connections, @merchant.net.connections
  end

  test "stops a call waiting for its relays, and closes its connections" do
    @merchant.key_relays.each { |url| @merchant.net.get(url).behaviour = { query_delay_ms: 3000 } }
    [->(cancellation) { client.merchant(cancellation: cancellation) },
     ->(cancellation) { client.find_invoices("C-2", cancellation: cancellation) }].each do |call|
      cancellation = Cancellation.after(0.1, "left")
      started = Clock.now
      assert_equal "left", assert_raises(Cancelled) { call.call(cancellation) }.reason
      assert_operator Clock.now - started, :<, 1.5
    end
    @merchant.key_relays.each { |url| eventually(3) { @merchant.net.get(url).server.open_connections.empty? } }
  end

  test "stops a call waiting for an HTTP answer" do
    invoice = client.create_invoice(ref: "C-3", sats: 1)
    @merchant.override = lambda do |url|
      next nil unless url.path.include?("/verify/")

      sleep 3
      nil
    end
    started = Clock.now
    error = assert_raises(Cancelled) { client.get_status(invoice, cancellation: Cancellation.after(0.1, "enough")) }
    assert_equal "enough", error.reason
    assert_operator Clock.now - started, :<, 1.5
  end

  test "fails with the cancellation, never an error, when a step that does not stop at once delayed it" do
    cancellation = Cancellation.new
    blocking = false
    # A clock that blocks while the call is cancelled.
    clock = lambda do
      if blocking
        blocking = false
        cancellation.cancel("the customer left")
        sleep 0.1
      end
      @merchant.now
    end
    # breez.tips answers an invoice that fails the checks, which read the clock next.
    @merchant.tamper = lambda do |made|
      blocking = true
      { pr: made.pr.sub(/.{8}\z/, "qqqqqqqq") }
    end
    sattleme = client(now: clock)
    error = assert_raises(Cancelled) { sattleme.create_invoice(ref: "C-1", sats: 1000, cancellation: cancellation) }
    assert_equal "the customer left", error.message
    assert_kind_of InvalidInvoiceError, error.cause
  end

  test "fails with the cancellation when it came while the call ended" do
    sattleme = client
    invoice = sattleme.create_invoice(ref: "C-2", sats: 1000)
    @merchant.pay_invoice(invoice.payment_hash)
    cancellation = Cancellation.new
    # The listener of the final status: the call is cancelled meanwhile.
    listener = ->(_status) { cancellation.cancel("enough") }
    error = assert_raises(Cancelled) do
      sattleme.wait_for_payment(invoice, on_status: listener, cancellation: cancellation)
    end
    assert_equal "enough", error.message
  end

  test "refuses a cancellation that is not one" do
    error = assert_raises(InvalidOptionError) { client.merchant(cancellation: Object.new) }
    assert_equal "cancellation", error.param
    assert_raises(InvalidOptionError) { client.find_invoices("C-4", cancellation: true) }
  end
end
