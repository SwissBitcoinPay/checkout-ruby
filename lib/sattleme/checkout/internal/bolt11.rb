# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Bech32 decoding (BIP-173), without its 90-character limit: BOLT11 invoices are longer.
      # Bech32m (BIP-350), for taproot addresses, differs by its checksum's constant alone.
      module Bech32
        CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        VALUES = CHARSET.each_char.with_index.to_h.freeze
        GENERATOR = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3].freeze
        # The checksum's constant: BIP-173's bech32, BIP-350's bech32m.
        BECH32 = 1
        BECH32M = 0x2bc830a3

        # A decoded string: its human-readable part (lower case) and its 5-bit words, checksum
        # removed.
        Decoded = Data.define(:hrp, :words)

        module_function

        def polymod(values)
          checksum = 1
          values.each do |value|
            top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ value
            5.times { |i| checksum ^= GENERATOR[i] if top[i] == 1 }
          end
          checksum
        end

        def expand_hrp(hrp)
          codes = hrp.bytes
          codes.map { |code| code >> 5 } + [0] + codes.map { |code| code & 31 }
        end

        # A bech32 string (either case, never mixed), or nil when it is not valid bech32 (bech32m
        # with `constant` BECH32M).
        def decode(input, constant = BECH32)
          return nil unless Text.well_formed?(input) && input.ascii_only?

          text = Text.ascii_lower(input)
          return nil unless input == text || input == input.tr("a-z", "A-Z")

          separator = text.rindex("1")
          return nil if separator.nil? || separator < 1 || separator + 7 > text.length

          hrp = text[0, separator]
          return nil unless hrp.bytes.all? { |code| code.between?(33, 126) }

          values = text[(separator + 1)..].each_char.map { |char| VALUES[char] }
          return nil if values.include?(nil)
          return nil unless polymod(expand_hrp(hrp) + values) == constant

          Decoded.new(hrp: hrp, words: values[0...-6])
        end

        # 5-bit words regrouped into bytes; the trailing padding bits (fewer than 8) dropped.
        def words_to_bytes(words)
          bytes = []
          accumulator = 0
          bits = 0
          words.each do |word|
            accumulator = ((accumulator << 5) | word) & 0xfff
            bits += 5
            next unless bits >= 8

            bits -= 8
            bytes << ((accumulator >> bits) & 0xff)
          end
          bytes.pack("C*")
        end

        # The big-endian unsigned integer of 5-bit words.
        def words_to_integer(words)
          words.reduce(0) { |value, word| (value * 32) + word }
        end
      end

      # The fields of a BOLT11 invoice the gem checks (SPEC.md §19): network, amount, payment hash,
      # description hash, date and expiry. The signature is not verified: the payee is the LNURL
      # server's node, which nothing here can check it against; the description hash ties the
      # invoice to the merchant's Lightning address instead. The first `p` and `h` fields count and
      # the last `x`, as in the merchant's app; an `x` field of more than 7 words or an amount above
      # 21 million bitcoins makes the invoice invalid.
      module Bolt11
        # A decoded invoice. `amount_msat` is nil for an invoice without an amount; `expiry_seconds`
        # 3600 when the invoice does not say; `description_hash` nil with a plain description.
        Invoice = Data.define(:network, :amount_msat, :timestamp, :expiry_seconds, :payment_hash,
                              :description_hash) do
          # The end of the invoice: its timestamp and its expiry.
          def expires_at = timestamp + expiry_seconds
        end

        HRP = /\Aln(bcrt|bc|tbs|tb)([0-9]+)?([munp])?\z/
        # Millisatoshis per unit of the amount, by multiplier (1 BTC = 10^11 msat).
        MSAT_PER_UNIT = { nil => 100_000_000_000, "m" => 100_000_000, "u" => 100_000, "n" => 100 }.freeze
        TIMESTAMP_WORDS = 7
        # A 65-byte signature, as 5-bit words.
        SIGNATURE_WORDS = 104
        TAG_PAYMENT_HASH = 1
        TAG_DESCRIPTION_HASH = 23
        TAG_EXPIRY = 6
        # 256 bits as 5-bit words.
        HASH_WORDS = 52
        DEFAULT_EXPIRY_SECONDS = 3600

        module_function

        # A BOLT11 invoice, decoded; nil when it is not a valid one.
        def decode(input)
          decoded = Bech32.decode(input)
          return nil unless decoded

          hrp = HRP.match(decoded.hrp)
          return nil unless hrp

          valid, amount = amount_msat(hrp[2], hrp[3])
          return nil unless valid

          words = decoded.words
          return nil if words.size < TIMESTAMP_WORDS + SIGNATURE_WORDS

          fields = words[TIMESTAMP_WORDS...(words.size - SIGNATURE_WORDS)]
          payment_hash, description_hash, expiry = read_fields(fields)
          return nil if payment_hash.nil? || payment_hash == :invalid

          Invoice.new(network: hrp[1], amount_msat: amount,
                      timestamp: Bech32.words_to_integer(words[0, TIMESTAMP_WORDS]),
                      expiry_seconds: expiry || DEFAULT_EXPIRY_SECONDS, payment_hash: payment_hash,
                      description_hash: description_hash)
        end

        # The payment hash, the description hash and the expiry of the tagged fields; the payment
        # hash :invalid when a field runs past the signature or an expiry field is too long.
        def read_fields(fields)
          payment_hash = nil
          description_hash = nil
          expiry = nil
          index = 0
          while index < fields.size
            return [:invalid] if index + 3 > fields.size

            tag = fields[index]
            length = (fields[index + 1] * 32) + fields[index + 2]
            data = fields[index + 3, length]
            return [:invalid] unless data && data.size == length

            # Fields of an unexpected length are skipped, as BOLT11 requires for p and h; the first
            # of each counts, and the last x.
            if tag == TAG_PAYMENT_HASH && length == HASH_WORDS && payment_hash.nil?
              payment_hash = Text.hex(Bech32.words_to_bytes(data))
            elsif tag == TAG_DESCRIPTION_HASH && length == HASH_WORDS && description_hash.nil?
              description_hash = Text.hex(Bech32.words_to_bytes(data))
            elsif tag == TAG_EXPIRY
              return [:invalid] if length > Protocol::MAX_BOLT11_EXPIRY_WORDS

              expiry = Bech32.words_to_integer(data)
            end
            index += 3 + length
          end
          [payment_hash, description_hash, expiry]
        end

        # [valid, millisatoshis] of the amount's digits and multiplier: digits without a leading
        # zero, an optional multiplier (a pico-bitcoin is a tenth of a millisatoshi: only whole
        # ones), 21 million bitcoins at most; no digits, no amount (a multiplier alone is invalid).
        def amount_msat(digits, multiplier)
          return [multiplier.nil?, nil] if digits.nil?
          return [false, nil] if digits.length > 1 && digits.start_with?("0")
          # Longer than any amount up to 21 million bitcoins, whatever the multiplier.
          return [false, nil] if digits.length > 22

          value = digits.to_i
          msat = if multiplier == "p"
                   return [false, nil] unless (value % 10).zero?

                   value / 10
                 else
                   value * MSAT_PER_UNIT.fetch(multiplier)
                 end
          msat > Protocol::MAX_BOLT11_AMOUNT_MSAT ? [false, nil] : [true, msat]
        end
      end
    end
  end
end
