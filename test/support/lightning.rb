# frozen_string_literal: true

require "digest"

# BOLT11 invoices built for tests, so that a test chooses their fields. The signature is 65 zero
# bytes: nothing verifies it.
module TestLightning
  CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  GENERATOR = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3].freeze

  module_function

  def polymod(values)
    chk = 1
    values.each do |value|
      top = chk >> 25
      chk = ((chk & 0x1ffffff) << 5) ^ value
      5.times { |i| chk ^= GENERATOR[i] if top[i] == 1 }
    end
    chk
  end

  def expand_hrp(hrp)
    codes = hrp.bytes
    codes.map { |c| c >> 5 } + [0] + codes.map { |c| c & 31 }
  end

  def encode_bech32(hrp, words, constant = 1)
    mod = polymod(expand_hrp(hrp) + words + ([0] * 6)) ^ constant
    checksum = (0..5).map { |i| (mod >> (5 * (5 - i))) & 31 }
    "#{hrp}1#{(words + checksum).map { |w| CHARSET[w] }.join}"
  end

  def bytes_to_words(bytes)
    words = []
    accumulator = 0
    bits = 0
    bytes.each_byte do |byte|
      accumulator = (accumulator << 8) | byte
      bits += 8
      while bits >= 5
        bits -= 5
        words << ((accumulator >> bits) & 31)
      end
    end
    words << ((accumulator << (5 - bits)) & 31) if bits.positive?
    words
  end

  def integer_words(value, length = nil)
    words = []
    rest = value
    loop do
      words.unshift(rest % 32)
      rest /= 32
      break if rest.zero?
    end
    words.unshift(0) while length && words.size < length
    words
  end

  def field(tag, data)
    [tag, data.size / 32, data.size % 32, *data]
  end

  # A 32-byte preimage made of `seed`, and its payment hash, hex.
  def preimage_pair(seed)
    preimage = ([seed & 0xff].pack("C") * 32)
    [preimage.unpack1("H*"), Digest::SHA256.hexdigest(preimage)]
  end

  def metadata_hash(metadata)
    Digest::SHA256.hexdigest(metadata.b)
  end

  def amount_part(msat)
    return (msat / 100_000_000_000).to_s if (msat % 100_000_000_000).zero?
    return "#{msat / 100_000_000}m" if (msat % 100_000_000).zero?
    return "#{msat / 100_000}u" if (msat % 100_000).zero?
    return "#{msat / 100}n" if (msat % 100).zero?

    "#{msat * 10}p"
  end

  # An invoice of the fields given; `extra` more tagged fields after them ([tag, 5-bit words]).
  def make_invoice(payment_hash:, timestamp:, amount_msat: nil, network: "bc", description_hash: nil,
                   expiry_seconds: nil, extra: [])
    hrp = "ln#{network}#{amount_part(amount_msat) unless amount_msat.nil?}"
    words = integer_words(timestamp, 7)
    words += field(1, bytes_to_words([payment_hash].pack("H*")))
    words += field(23, bytes_to_words([description_hash].pack("H*"))) if description_hash
    words += field(6, integer_words(expiry_seconds)) unless expiry_seconds.nil?
    extra.each { |tag, data| words += field(tag, data) }
    words += [0] * 104
    encode_bech32(hrp, words)
  end
end
