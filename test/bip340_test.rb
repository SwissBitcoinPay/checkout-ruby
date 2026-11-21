# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# BIP-340 signatures of libsecp256k1, as the gem binds it, against BIP-340's official vectors:
# test/fixtures/bip-0340/test-vectors.csv is
# https://github.com/bitcoin/bips/blob/93f161194fbaed12c44f5e2a0c1d4f2b1b317cb0/bip-0340/test-vectors.csv,
# unchanged (its SHA-256 below).
class Bip340Test < Minitest::Test
  include TestHelpers
  include Sattleme::Checkout::Internal

  FILE = File.join(__dir__, "fixtures", "bip-0340", "test-vectors.csv")
  # Its rows: no field quoted, a comma in none but the last (the comment).
  ROWS = File.readlines(FILE, chomp: true).then do |header, *lines|
    names = header.split(",")
    lines.map { |line| names.zip(line.split(",", names.size).map { |field| field.empty? ? nil : field }).to_h }
  end

  test "the file is the official one" do
    assert_equal "34c9d1d9c3a88d524bc80778540dc43f8306ec249a7485293063c376db851c2d", Digest::SHA256.file(FILE).hexdigest
    assert_equal 19, ROWS.size
  end

  # libsecp256k1's verification of a message of any length, as BIP-340 defines it: the gem's own
  # `verify` takes the 32 bytes of a Nostr id only.
  def library_verifies?(signature, message, public_key)
    FFI::MemoryPointer.new(:uchar, Secp256k1::PUBKEY_BYTES) do |xonly|
      Secp256k1.with_bytes(public_key) do |input|
        return false unless Secp256k1.secp256k1_xonly_pubkey_parse(Secp256k1::CONTEXT, xonly, input) == 1
      end
      Secp256k1.with_bytes(signature) do |sig|
        # An empty message: a pointer all the same, its length 0.
        Secp256k1.with_bytes(message.empty? ? "\x00".b : message) do |pointer|
          return Secp256k1.secp256k1_schnorrsig_verify(Secp256k1::CONTEXT, sig, pointer, message.bytesize, xonly) == 1
        end
      end
    end
  end

  ROWS.each do |row|
    test "vector #{row["index"]}: #{row["comment"] || "valid"}" do
      public_key = hex(row["public key"])
      message = hex(row["message"].to_s)
      signature = hex(row["signature"])
      expected = row["verification result"] == "TRUE"
      if row["secret key"]
        secret = hex(row["secret key"])
        assert_equal public_key, Secp256k1.public_key(secret)
        if message.bytesize == 32
          assert_equal signature, Secp256k1.sign(message, secret, hex(row["aux_rand"]))
        else
          # Nostr signs 32-byte ids only: any other message is refused.
          assert_raises(ArgumentError) { Secp256k1.sign(message, secret, hex(row["aux_rand"])) }
        end
      end
      assert_equal expected, library_verifies?(signature, message, public_key)
      # The gem's verification: the vector's result for an id of 32 bytes, false for anything else.
      assert_equal message.bytesize == 32 && expected, Secp256k1.verify(signature, message, public_key)
      assert_equal Secp256k1.xonly?(public_key), Events.public_key?(row["public key"].downcase)
    end
  end

  test "refuses secret keys out of the curve's order, and malformed input" do
    order = hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    refute Secp256k1.valid_secret?("\x00".b * 32)
    refute Secp256k1.valid_secret?(order)
    assert Secp256k1.valid_secret?(hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140"))
    refute Secp256k1.valid_secret?("\x01".b * 31)
    refute Secp256k1.valid_secret?(nil)
    assert_raises(ArgumentError) { Secp256k1.public_key(order) }
    assert_raises(ArgumentError) { Secp256k1.sign("\x00".b * 32, "\x00".b * 32, "\x00".b * 32) }
    refute Secp256k1.verify("\x00".b * 63, "\x00".b * 32, "\x00".b * 32)
    refute Secp256k1.verify(nil, "\x00".b * 32, "\x00".b * 32)
    refute Secp256k1.xonly?("\x00".b * 32)
    refute Secp256k1.xonly?("\x02".b * 33)
  end

  test "gives the ECDH of NIP-44: the same x either way, refused for a point off the curve" do
    a = TestMerchant.bytes(7)
    b = TestMerchant.bytes(8)
    shared = Secp256k1.shared_x(a, Secp256k1.public_key(b))
    assert_equal shared, Secp256k1.shared_x(b, Secp256k1.public_key(a))
    assert_equal 32, shared.bytesize
    assert_raises(ArgumentError) { Secp256k1.shared_x(a, "\x00".b * 32) }
    assert_raises(ArgumentError) { Secp256k1.shared_x("\x00".b * 32, Secp256k1.public_key(b)) }
  end
end
