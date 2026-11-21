# frozen_string_literal: true

require_relative "test_helper"

class ChannelTest < Minitest::Test
  include TestHelpers

  def teardown
    @merchant&.stop
    @net&.close
  end

  # Channels.read over a pool of its own, closed once it is done.
  def read_on(key, net, timeout_ms: 2000, logger: QUIET)
    stop = Internal::Stop.new(Cancellation::NONE)
    pool = Internal::Relay::Pool.new(websocket: net.websocket_client, timeout_ms: timeout_ms, stop: stop,
                                     random: SecureRandom.method(:random_bytes), now: -> { Time.now.to_i })
    Internal::Channels.read(pool, key, random: SecureRandom.method(:random_bytes), logger: logger, stop: stop)
  ensure
    pool&.close
  end

  def read(merchant, timeout_ms = 2000, logger = QUIET)
    read_on(Internal::IntegrationKey.parse(merchant.key), merchant.net, timeout_ms: timeout_ms, logger: logger)
  end

  def start(others = [], behaviours = {})
    @merchant = TestMerchant.new.start(others, behaviours)
  end

  test "reads the channel of the app's vectors with its key alone" do
    @net = RelayNet.new
    relay = @net.add("wss://relay.example")
    relay.store(SpecVectors.app["channel"]["event"])
    read = read_on(Internal::IntegrationKey.parse(SpecVectors.app["secretKey"]), @net)
    channel = read.channel
    assert_equal [:active, "Sunrise Bakery", "sattleme02c6047f94@breez.tips",
                  SpecVectors.app["channel"]["value"]["v"]["registryKey"]],
                 [channel.status, channel.business_name, channel.lightning_address, channel.registry_key]
    assert_equal ["wss://relay.example"], read.relays
    assert_equal [{ "kinds" => [30_078], "authors" => [SpecVectors.app["parsed"]["team"]],
                    "#d" => [SpecVectors.app["derived"]["channelAddress"]] }], relay.queries
  end

  test "keeps the newest copy, and ignores one signed by another key" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    merchant.publish_channel(
      merchant.channel_value(200, "profile" => { "businessName" => "Old", "lightningAddress" => "a@b.test",
                                                 "currency" => "CHF" }),
      200,
      # On a majority, as the app publishes it: any majority that answers holds it.
      ["wss://relay-a.test", "wss://relay-b.test"]
    )
    # Newer, but by another author: whoever saw the address could publish there.
    merchant.publish_channel(merchant.channel_value(300, "status" => "removed"), 300, merchant.key_relays,
                             TestMerchant.bytes(66))
    channel = read(merchant).channel
    assert_equal ["Old", 200], [channel.business_name, channel.updated_at]
  end

  test "ignores a copy whose updatedAt is not its date, or that is damaged" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    merchant.publish_channel(merchant.channel_value(150), 200)
    relay = merchant.net.get("wss://relay-b.test")
    good = merchant.channel_event(merchant.channel_value(300), 300).to_h
    relay.store(good.merge("content" => good["content"].sub(/\AA/, "B")))
    relay.store(good.merge("sig" => "00" * 64))
    assert_equal 100, read(merchant).channel.updated_at
  end

  test "ignores a channel whose Lightning address is on an IP address or under localhost, or whose business name holds a lone surrogate" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    profile = merchant.channel_value(0)["profile"]
    [[200, { "lightningAddress" => "shop@10.0.0.1" }], [201, { "lightningAddress" => "shop@pay.localhost" }],
     [202, { "businessName" => Internal::Json.parse('"Sunrise \\ud800"') }]].each do |at, changed|
      merchant.publish_channel(merchant.channel_value(at).merge("profile" => profile.merge(changed)), at)
    end
    assert_equal 100, read(merchant).channel.updated_at
  end

  test "throws RevokedError when the integration was removed" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    merchant.publish_channel({ "version" => 1, "status" => "removed", "updatedAt" => 200 }, 200)
    assert_raises(RevokedError) { read(merchant) }
  end

  test "warns of a newer format, and ignores it" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    merchant.publish_channel(merchant.channel_value(200).merge("version" => 2), 200)
    logger = TestLogger.new
    assert_equal 100, read(merchant, 2000, logger).channel.updated_at
    assert_equal 1, logger.messages.size
  end

  test "follows the account's relays where the channel moved, 3 times at most" do
    @merchant = merchant = TestMerchant.new
    lists = [merchant.key_relays, ["wss://second.test"], ["wss://third.test", "wss://third-b.test"],
             ["wss://fourth.test"], ["wss://fifth.test"]]
    merchant.start(lists.drop(1).flatten)
    lists.each_with_index do |list, i|
      following = lists[i + 1] || list
      merchant.publish_channel(
        merchant.channel_value(100 + i, "relays" => following,
                                        "profile" => { "businessName" => "List #{i}",
                                                       "lightningAddress" => "sattleme02c6047f94@breez.tips",
                                                       "currency" => "CHF" }),
        100 + i, list
      )
    end
    read = read(merchant)
    assert_equal "List 3", read.channel.business_name
    assert_equal ["wss://fourth.test"], read.relays
    refute merchant.net.connections.key?("wss://fifth.test")
  end

  test "sees a removal on the list the channel moved to" do
    merchant = start(["wss://new.test"])
    merchant.publish_channel(merchant.channel_value(100, "relays" => ["wss://new.test"]), 100)
    merchant.publish_channel({ "version" => 1, "status" => "removed", "updatedAt" => 200 }, 200, ["wss://new.test"])
    assert_raises(RevokedError) { read(merchant) }
  end

  test "throws NetworkError when the list the channel moved to does not answer" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100, "relays" => ["wss://gone.test"]), 100)
    assert_raises(NetworkError) { read(merchant) }
  end

  test "throws ChannelNotFoundError when the relays answer without it" do
    merchant = start
    error = assert_raises(ChannelNotFoundError) { read(merchant) }
    assert_equal ["channel_not_found", true, false], [error.code, error.retryable?, error.newer_format?]
  end

  test "goes on once a majority answered, past a silent relay, and one asking to authenticate" do
    merchant = start([], "wss://relay-a.test" => { mute: true }, "wss://relay-b.test" => { require_auth: true })
    merchant.publish_channel(merchant.channel_value(100), 100, ["wss://relay-b.test"])
    started = Internal::Clock.now
    # relay-b and relay-c are a majority: the silent relay's 5 s are not waited for.
    channel = read(merchant, 5000).channel
    assert_operator Internal::Clock.now - started, :<, 3
    assert_equal 100, channel.updated_at
    # A key of this read alone: never the team's nor a sale's.
    auth_key = merchant.net.get("wss://relay-b.test").authenticated.first
    refute_nil auth_key
    refute_equal merchant.team, auth_key
  end

  test "closes a relay that never completes the handshake, without an uncaught error" do
    merchant = start
    merchant.net.add_blackhole("wss://hole.test")
    merchant.publish_channel(merchant.channel_value(100), 100, ["wss://relay-b.test"])
    access = Internal::IntegrationKey.parse(merchant.key)
    on = lambda do |list|
      Internal::IntegrationKey.new(access.team_public_key, Internal::Secret.new(access.key), list)
    end
    threads = Thread.list.size
    # Read on the two others, a majority of three; the hole's connection closed meanwhile.
    channel = read_on(on.call(["wss://hole.test", "wss://relay-b.test", "wss://relay-c.test"]), merchant.net,
                      timeout_ms: 300).channel
    assert_equal 100, channel.updated_at
    # One of two is no majority: no answer is no absence.
    assert_raises(NetworkError) do
      read_on(on.call(["wss://hole.test", "wss://relay-b.test"]), merchant.net, timeout_ms: 300)
    end
    # Every thread of the reads ends: the handshake's within its timeout.
    eventually { Thread.list.size <= threads + 1 }
  end

  test "throws NetworkError, not an absence, when no relay answers" do
    merchant = start([], "wss://relay-a.test" => { mute: true })
    merchant.net.remove("wss://relay-b.test")
    merchant.net.remove("wss://relay-c.test")
    started = Internal::Clock.now
    assert_raises(NetworkError) { read(merchant, 300) }
    assert_operator Internal::Clock.now - started, :<, 2
  end

  test "reads the merchant at every call, as JSON, and keeps nothing open" do
    merchant = start
    merchant.publish_channel(merchant.channel_value(100), 100)
    client = Client.new(key: merchant.key, http_client: merchant.http,
                        websocket_client: merchant.net.websocket_client, logger: QUIET)
    found = client.merchant
    assert_equal({ "businessName" => "Sunrise Bakery", "minSats" => "1", "maxSats" => "100000000",
                   # No lot of addresses yet: no on-chain payment.
                   "onchainAddresses" => 0 }, found.to_h)
    assert_equal found, Merchant.from_json(found.to_json)
    # Nothing kept: a removal stops the very next call.
    merchant.publish_channel({ "version" => 1, "status" => "removed", "updatedAt" => 200 }, 200)
    assert_raises(RevokedError) { client.merchant }
    assert_equal 2, merchant.net.connections["wss://relay-a.test"]
    merchant.key_relays.each do |url|
      eventually { merchant.net.get(url).server.open_connections.empty? }
    end
  end
end
