# frozen_string_literal: true

require_relative "test_helper"

# relay-reads.json end to end (PORTING.md, steps 4 and 5): its `lists` and `onEveryRelay` cases,
# each relay's read made by a local relay and told apart by Relay::Pool itself, through
# Leases.read, the client's read of the leases of deposit addresses: a complete read (step 3 of
# "Leasing an address"), and on every relay (a lease's confirmation). test/onchain_vectors_test.rb
# runs the same cases through Relay.outcome, the function the pool decides them with.
#
# What each relay of a case does, by its state:
# - complete: holds a few events at the lease's address (one page, not full); or 250, at distinct
#   seconds (it pages: 100, 100, then 52); or caps its answers at 40 events (a page that is not
#   full: complete, whatever it leaves out: SPEC.md §13 relies on relays that honor the limit).
# - incomplete: holds 150 events of one second (a full page, then the same page again: no event it
#   had not sent); or 2 100 at distinct seconds (a 20th page that is full); or never answers its
#   second page (that page runs out of time).
# - failed: refuses connections (nothing listens); or accepts them and never answers (mute: its
#   first page runs out of time).
# - reading: a relay still reading when the read goes on: one that holds 2 100 events at distinct
#   seconds and answers each page a quarter of the timeout late (its read would last five
#   timeouts); or a mute one, when the read goes on before its first page runs out of time.
class RelayReadsTest < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTORS = SpecVectors.read("vectors/relay-reads.json")

  # relay_timeout_ms of these reads: each page, the connection included. Ample for a local relay on
  # a busy machine: a relay that reads completely, or ends its read, never runs out of time here.
  TIMEOUT_MS = 2000
  # How late a relay that is still reading answers each of its pages.
  SLOW_PAGE_MS = TIMEOUT_MS / 4
  # How late the relays that read completely answer each page, when the read goes on as soon as a
  # majority read completely and every other relay's read must have ended (or failed) by then.
  LATE_COMPLETE_MS = 400

  NOW = 1_791_378_000
  REGISTRY_KEY = TestMerchant.bytes(9)
  ADDRESS = "bc1px22v5j99gdwhxqyelg2p6tdcfajjd3njhzn22c2gura2dvxg2xlqw2wte4"
  D = Addresses.lease_address(REGISTRY_KEY, ADDRESS)

  # `count` events at the lease's address, anybody's (none opens as a lease: a read pages through
  # them all the same), the newest at NOW; of one second each, or all of NOW. Their ids from
  # `first`.
  def self.events(first, count, one_second: false)
    Array.new(count) do |i|
      { "id" => format("%064x", first + i), "pubkey" => "ab" * 32, "created_at" => one_second ? NOW : NOW - i,
        "kind" => Protocol::RECORD_KIND, "tags" => [["d", D]], "content" => "", "sig" => "00" * 64 }
    end
  end

  # The local relays that read as each state does, by name: [the events it holds, its behaviour],
  # nil for none at all (nothing listens there). `delay_ms`: how late a relay that reads completely
  # answers each page.
  MAKERS = {
    few: ->(delay_ms) { [events(0, 3), delay_ms ? { query_delay_ms: delay_ms } : {}] },
    pages: ->(delay_ms) { [events(10_000, 250), delay_ms ? { query_delay_ms: delay_ms } : {}] },
    caps: ->(delay_ms) { [events(20_000, 250), { cap: 40 }.merge(delay_ms ? { query_delay_ms: delay_ms } : {})] },
    one_second: ->(_) { [events(30_000, 150, one_second: true), {}] },
    twenty_pages: ->(_) { [events(40_000, 2100), {}] },
    stalls_at_page2: ->(_) { [events(50_000, 250), { mute_query: ->(filter) { filter.key?("until") } }] },
    refuses_connections: ->(_) {},
    mute: ->(_) { [[], { mute: true }] },
    slow_pager: ->(_) { [events(60_000, 2100), { query_delay_ms: SLOW_PAGE_MS }] }
  }.freeze

  # How many relays each choice of makers made so far: its makers take turns, so that the relays
  # of one state vary from case to case. Every maker the cases use.
  @turns = Hash.new(0)
  @used = []

  class << self
    attr_reader :used
  end

  # The next of `makers`, in turn.
  def self.next_maker(*makers)
    turn = @turns[makers]
    @turns[makers] += 1
    maker = makers[turn % makers.size]
    @used |= [maker]
    maker
  end

  # When Relay::Pool goes on with a complete read on every relay while these are its relays'
  # states (SPEC.md §13): once no relay is still reading (:settled); or, with some still reading, a
  # timeout after a majority read completely (:grace), or as soon as a majority can no longer read
  # completely (:at_once). Otherwise (nil) it never does: it waits for the relays still reading,
  # until each ends or fails.
  def self.goes_on_with(states)
    needed = Relay.majority(states.size)
    return :settled if states.count("reading").zero?
    return :grace if states.count("complete") >= needed
    return :at_once if states.count("complete") + states.count("reading") < needed

    nil
  end

  def teardown
    @net&.close
  end

  # Makes one local relay per maker (`[maker, delay_ms]`), reads the leases of ADDRESS on them
  # (on every relay or not), and tells how long the read took: [what it gave (answered, complete),
  # the seconds it took, the relays by URL (nil where nothing listens), the URLs].
  def read(makers, every_relay)
    @net = RelayNet.new
    urls = makers.each_with_index.map { |(maker, _), index| "wss://#{maker.to_s.tr("_", "-")}-#{index}.test" }
    relays = {}
    makers.each_with_index do |(maker, delay_ms), index|
      held, behaviour = MAKERS.fetch(maker).call(delay_ms)
      next relays[urls[index]] = nil if behaviour.nil?

      relay = @net.add(urls[index], behaviour)
      held.each { |event| relay.store(event) }
      relays[urls[index]] = relay
    end
    stop = Stop.new(Cancellation::NONE)
    pool = Relay::Pool.new(websocket: @net.websocket_client, timeout_ms: TIMEOUT_MS, stop: stop,
                           random: SecureRandom.method(:random_bytes), now: -> { NOW })
    started = Clock.now
    leases = begin
      Leases.read(pool, REGISTRY_KEY, [ADDRESS], urls,
                  now: NOW, random: ->(length) { TestMerchant.bytes(7, length) }, stop: stop, every_relay: every_relay)
    ensure
      pool.close
    end
    [{ "answered" => leases.answered, "complete" => leases.complete }, Clock.now - started, relays, urls]
  end

  # relay-reads.json lists, end to end: a complete read of a list.
  VECTORS["lists"].each_with_index do |item, index|
    # Complete: the read goes on as soon as a majority read completely, the others dropped; so that
    # each of those has ended as the case says by then, they end at once and the relays that read
    # completely answer late. Not complete: the read waits for every relay.
    expected = item["expected"]
    makers = item["relays"].map do |state|
      case state
      when "complete"
        maker = next_maker(:few, :pages, :caps)
        expected ? [maker, LATE_COMPLETE_MS] : [maker]
      when "incomplete"
        [expected ? next_maker(:one_second) : next_maker(:one_second, :stalls_at_page2, :twenty_pages)]
      else
        [expected ? next_maker(:refuses_connections) : next_maker(:mute, :refuses_connections)]
      end
    end
    test "relay-reads.json lists #{index}, end to end: #{item["name"]}" do
      outcome, = read(makers, false)
      assert_equal expected, outcome["complete"]
    end
  end

  # relay-reads.json onEveryRelay, end to end: a read of a lease's confirmation.
  producible, waited = VECTORS["onEveryRelay"].each_with_index.partition { |item, _| goes_on_with(item["relays"]) }

  test "relay-reads.json onEveryRelay has cases of every kind" do
    kinds = producible.map { |item, _| RelayReadsTest.goes_on_with(item["relays"]) }
    assert_equal %i[at_once grace settled], kinds.uniq.sort
    refute_empty waited
  end

  producible.each do |item, index|
    states = item["relays"]
    goes_on = goes_on_with(states)
    # A relay that is not still reading must have ended or failed when the read goes on: before the
    # timeout after a majority read completely (:grace), or at once.
    makers = states.map do |state|
      case state
      when "complete" then [next_maker(:few, :pages, :caps)]
      when "incomplete"
        settled = goes_on == :settled
        [settled ? next_maker(:one_second, :stalls_at_page2, :twenty_pages) : next_maker(:one_second, :twenty_pages)]
      when "failed"
        [goes_on == :settled ? next_maker(:refuses_connections, :mute) : next_maker(:refuses_connections)]
      else [goes_on == :grace ? next_maker(:slow_pager) : next_maker(:mute)]
      end
    end
    test "relay-reads.json onEveryRelay #{index}, end to end: #{item["name"]}" do
      outcome, seconds, relays, urls = read(makers, true)
      assert_equal item["expected"], outcome
      reading = urls.select.with_index { |_, i| states[i] == "reading" }
      if goes_on == :grace
        # The relays still reading were waited for a timeout after the majority, not until they end.
        assert_operator seconds, :>=, (TIMEOUT_MS - 50) / 1000.0
        reading.each { |url| assert_operator relays.fetch(url).queries.size, :<, Protocol::MAX_PAGES }
      end
      # Before a mute relay's first page could run out of time: it was still reading.
      assert_operator seconds, :<, (TIMEOUT_MS - 100) / 1000.0 if goes_on == :at_once
    end
  end

  # The cases Relay::Pool never goes on with: fewer than a majority read completely while a majority
  # still can, some relays still reading. A complete read on every relay then waits for them
  # (SPEC.md §13: it goes on once every relay did or failed, a timeout after a majority did, or as
  # soon as a majority can no longer read completely), so no local relay can make a relay still
  # reading when it goes on: a relay that reads slowly is waited for until it ends, a mute one until
  # its first page runs out of time. With mute relays in their place, the read goes on once they
  # failed, and gives what the case expects: a relay still reading answered no more than one that
  # failed (relay-reads.json says so).
  waited.each do |item, index|
    makers = item["relays"].map do |state|
      case state
      when "complete" then [next_maker(:few, :pages, :caps)]
      when "incomplete" then [next_maker(:one_second, :twenty_pages)]
      when "failed" then [next_maker(:refuses_connections)]
      else [next_maker(:mute)]
      end
    end
    test "relay-reads.json onEveryRelay #{index}, end to end: #{item["name"]}: waited for until the relays still " \
         "reading fail" do
      outcome, seconds = read(makers, true)
      assert_operator seconds, :>=, (TIMEOUT_MS - 50) / 1000.0
      assert_equal item["expected"], outcome
    end
  end

  test "the local relays of these reads were of every kind: each state made more than one way" do
    assert_equal MAKERS.keys.sort, RelayReadsTest.used.sort
  end
end
