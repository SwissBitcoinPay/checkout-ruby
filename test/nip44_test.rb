# frozen_string_literal: true

require_relative "test_helper"

# The official vectors of NIP-44 (https://github.com/paulmillr/nip44, see `source`), the app's copy.
class Nip44Test < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  VECTORS = SpecVectors.read("vectors/nip44/nip44.vectors.json")
  RANDOM = SecureRandom.method(:random_bytes)

  test "pads plaintexts to the spec's lengths" do
    VECTORS["calc_padded_len"].each do |length, padded|
      assert_equal padded.to_i, Nip44.padded_length(length.to_i)
    end
  end

  test "derives the spec's conversation keys, and refuses invalid ones" do
    VECTORS["get_conversation_key"].each do |vector|
      key = Nip44.conversation_key(hex(vector["sec1"]), vector["pub2"])
      assert_equal vector["conversation_key"], to_hex(key)
    end
    VECTORS["invalid_get_conversation_key"].each do |vector|
      assert_raises(ArgumentError) { Nip44.conversation_key(hex(vector["sec1"]), vector["pub2"]) }
    end
  end

  test "gives both parties the same conversation key" do
    a = SecureRandom.random_bytes(32)
    b = SecureRandom.random_bytes(32)
    assert_equal to_hex(Nip44.conversation_key(a, Events.public_key(b))),
                 to_hex(Nip44.conversation_key(b, Events.public_key(a)))
  end

  test "derives the spec's message keys" do
    key = hex(VECTORS["get_message_keys"]["conversation_key"])
    VECTORS["get_message_keys"]["keys"].each do |expected|
      chacha_key, chacha_nonce, hmac_key = Nip44.message_keys(key, hex(expected["nonce"]))
      assert_equal [expected["chacha_key"], expected["chacha_nonce"], expected["hmac_key"]],
                   [to_hex(chacha_key), to_hex(chacha_nonce), to_hex(hmac_key)]
    end
  end

  test "encrypts and decrypts the spec's payloads" do
    VECTORS["encrypt_decrypt"].each do |vector|
      key = hex(vector["conversation_key"])
      assert_equal vector["payload"], Nip44.encrypt_with_nonce(vector["plaintext"], key, hex(vector["nonce"]))
      assert_equal vector["plaintext"], Nip44.decrypt(vector["payload"], key)
    end
  end

  test "refuses the spec's invalid payloads, telling another version apart" do
    VECTORS["invalid_decrypt"].each do |vector|
      assert_raises(Nip44::Invalid, Nip44::UnknownVersion) do
        Nip44.decrypt(vector["payload"], hex(vector["conversation_key"]))
      end
    end
    assert_raises(Nip44::UnknownVersion) { Nip44.decrypt("#future", "\x00".b * 32) }
  end

  test "keeps a plaintext's leading byte order mark: UTF-8 is decoded strictly (SPEC.md §6)" do
    key = SecureRandom.random_bytes(32)
    assert_equal "\uFEFF{}", Nip44.decrypt(Nip44.encrypt("\uFEFF{}", key, RANDOM), key)
  end

  test "opens no record whose plaintext starts with a byte order mark: not JSON (SPEC.md §12)" do
    signer = TestMerchant.bytes(3)
    encryption_key = TestMerchant.bytes(4)
    address = "ab" * 32
    author = Events.public_key(signer)
    open = lambda do |event|
      Records.open(event, type: "t", encryption_key: encryption_key, address: address, author: author) do |value, _|
        value
      end
    end
    opened = open.call(Records.seal(type: "t", value: 1, signer: signer, encryption_key: encryption_key,
                                    address: address, created_at: 1_791_378_000, random: RANDOM))
    assert_equal [:ok, 1], [opened.status, opened.value]
    # The same record, its plaintext after a byte order mark, signed by its author.
    plaintext = "\uFEFF#{Json.generate({ "t" => "t", "v" => 1 })}".ljust(256 - 2, " ")
    event = Events.sign(signer, RANDOM, created_at: 1_791_378_000, kind: 30_078, tags: [["d", address]],
                                        content: Nip44.encrypt(plaintext, encryption_key, RANDOM))
    assert_nil open.call(event)
  end

  test "draws a fresh nonce each time" do
    key = SecureRandom.random_bytes(32)
    refute_equal Nip44.encrypt("Sunrise Bakery", key, RANDOM), Nip44.encrypt("Sunrise Bakery", key, RANDOM)
  end

  test "refuses a plaintext longer than 65 535 bytes, as too long" do
    assert_raises(Nip44::TooLong) { Nip44.encrypt("a" * 65_536, "\x01".b * 32, RANDOM) }
    assert_equal 65_535, Nip44.decrypt(Nip44.encrypt("a" * 65_535, "\x01".b * 32, RANDOM), "\x01".b * 32).bytesize
  end
end
