# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Deposit addresses (SPEC.md §31, "Deposit addresses", "Payment URIs"): the taproot
      # addresses the merchant's wallet hands out, in their one spelling, and what the shop's page
      # shows of an invoice as one QR code.
      module Addresses
        # `bc1p` and 58 more characters.
        LENGTH = 62
        # The witness version (1) and the 32-byte program, as 5-bit words.
        PROGRAM_WORDS = 53

        module_function

        # Whether `value` is a deposit address: the bech32m encoding (BIP-350) of the human-readable
        # part `bc`, witness version 1 and a 32-byte program (BIP-341), in lowercase. Another
        # network, witness version or length, bech32 instead of bech32m, upper case or a padding
        # with bits that are not zero is not one.
        def deposit?(value)
          return false unless Text.match?(value, /\Abc1[02-9ac-hj-np-z]+\z/) && value.length == LENGTH

          decoded = Bech32.decode(value, Bech32::BECH32M)
          return false unless decoded && decoded.hrp == "bc"

          words = decoded.words
          # 52 words after the version: 256 bits of program and 4 bits of padding, which are zeros.
          words.size == PROGRAM_WORDS && words[0] == 1 && words[-1].nobits?(0b1111)
        end

        # Where the leases of `address` are in the registry: HMAC(registry key, "onchain/v1/" +
        # address).
        def lease_address(registry_key, address)
          Text.hex(Crypto.hmac(registry_key, (Protocol::LEASE_ADDRESS_PREFIX + address).b))
        end

        # `sats` in bitcoins, exact, as BIP-21's `amount`: no trailing zero in the fraction, no
        # fraction when whole (49 000 sats is "0.00049", 100 000 000 sats is "1").
        def btc_amount(sats)
          whole, fraction = sats.divmod(Protocol::SATS_PER_BTC)
          fraction = fraction.to_s.rjust(8, "0").sub(/0+\z/, "")
          fraction.empty? ? whole.to_s : "#{whole}.#{fraction}"
        end

        # What the shop's page shows as one QR code: `bitcoin:<address>?amount=<BTC>`, with
        # `&lightning=<invoice>` when there is one (BIP-21, the "unified QR" wallets read), or
        # `lightning:<invoice>` without an address. Both are written as they are (lowercase).
        def payment_uri(address, sats, bolt11)
          return "lightning:#{bolt11}" if address.nil?

          uri = "bitcoin:#{address}?amount=#{btc_amount(sats)}"
          bolt11.nil? ? uri : "#{uri}&lightning=#{bolt11}"
        end
      end
    end
  end
end
