# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The declaration of an invoice in the merchant's registry of payments (SPEC.md §20), as the
      # merchant's app reads it: published on a majority of the merchant's relays before the invoice
      # is shown, so that its payment counts for this order's sale and for no other. Its format is
      # the app's, version 1: changing it needs a new version there first, but for an optional field
      # the app ignores (as `taker`): `rest`, in a rest invoice's.
      module Declarations
        # The invoice an invoice of the rest is of: its deposit address and its end (Unix seconds).
        RestOf = Data.define(:address, :expires_at)

        # A declaration of the sale, opened by its holder: `price` as the declaration holds it
        # ({"minor", "digits", "currency"}), `declared_at` its event's `created_at`, `rest` the
        # invoice whose rest it is (nil for an invoice of the order).
        Opened = Data.define(:event, :invoice, :decoded, :verify_url, :price, :note, :declared_at, :rest)

        module_function

        # The price a sale is declared with, as the declaration's JSON holds it: `minor` a JSON
        # number (at most 2^53 − 1); for a sale in sats, `{minor: <sats>, digits: 0, currency: SAT}`.
        def price(minor:, digits:, currency:)
          { "minor" => minor, "digits" => digits, "currency" => currency }
        end

        # The price of an order: its Fiat's, else its sats.
        def price_of(fiat, sats)
          return price(minor: sats, digits: 0, currency: Protocol::SATS_CURRENCY) if fiat.nil?

          price(minor: Integer(fiat.minor, 10), digits: fiat.digits, currency: fiat.currency)
        end

        # The signed declaration of an invoice for `sale`: the declaration (inside, NIP-44 with the
        # ECDH conversation key of the sale's secret and the merchant's reading key), then
        # `{"t": "registry-declaration", "v": {"sealed": …}}` padded to a multiple of 256 bytes
        # (outside, NIP-44 with the outer key), kind 30078, `d` the registry address, signed by the
        # sale's secret. Nip44::TooLong when it does not fit a NIP-44 plaintext.
        def event(sale:, invoice:, verify_url:, payment_hash:, price:, note:, created_at:, random:, rest: nil)
          declaration = { "version" => Protocol::DECLARATION_VERSION, "invoice" => invoice, "verifyUrl" => verify_url,
                          "sale" => { "key" => Text.hex(sale.key), "fiat" => price, "note" => note },
                          # "By" in the app: this integration.
                          "taker" => sale.taker }
          # Only in a rest invoice's: the app ignores it, and counts the payment for the sale.
          declaration["rest"] = { "address" => rest.address, "expiresAt" => rest.expires_at } if rest
          address = Derive.registry_address(sale.registry.key, payment_hash)
          sealed = Nip44.encrypt(Json.generate(declaration), sale.inner_key, random)
          Records.seal(type: Protocol::DECLARATION_RECORD_TYPE, value: { "sealed" => sealed }, signer: sale.secret_key,
                       encryption_key: Derive.outer_key(sale.registry.key, address, sale.author), address: address,
                       created_at: created_at, random: random)
        end

        # A declared price, checked: `minor` a safe integer from 0, `digits` 0 to 8, `currency` three
        # letters A–Z. Nil when it is not one.
        def parse_price(value)
          return nil unless value.is_a?(Hash)

          minor, digits, currency = value.values_at("minor", "digits", "currency")
          return nil unless Json.safe_integer?(minor) && minor >= 0
          return nil unless Json.integer?(digits) && digits.between?(0, Protocol::MAX_DECLARED_DIGITS)
          return nil unless Text.match?(currency, /\A[A-Z]{3}\z/)

          price(minor: minor.to_i, digits: digits.to_i, currency: currency)
        end

        # A declaration's `rest`: absent (nil), or the invoice it names; Order::ABSENT when invalid.
        def rest_of(value, present)
          return nil unless present
          return Order::ABSENT unless value.is_a?(Hash)

          address, expires_at = value.values_at("address", "expiresAt")
          return Order::ABSENT unless Addresses.deposit?(address) && Json.safe_integer?(expires_at) && expires_at >= 0

          RestOf.new(address: address, expires_at: expires_at.to_i)
        end

        # What a relay sent, if it is a declaration of `sale`: author, `d` tag (the address of its
        # own invoice), outer and inner encryption, signature, and the sale's own key inside. Nil
        # otherwise; raises Records::Newer for one of a newer format.
        def open(value, sale)
          d = Records.d_tag_of(value)
          return nil if d.nil?

          opened = Records.open(value, type: Protocol::DECLARATION_RECORD_TYPE,
                                       encryption_key: Derive.outer_key(sale.registry.key, d, sale.author),
                                       address: d, author: sale.author) do |outside, event|
            parse(outside, event, sale, d)
          end
          raise Records::Newer if opened&.newer?

          opened&.value
        end

        def parse(outside, event, sale, d)
          sealed = outside.is_a?(Hash) ? outside["sealed"] : nil
          return nil unless sealed.is_a?(String)

          inside = inside_of(sealed, sale)
          return nil unless inside.is_a?(Hash)

          version = inside["version"]
          raise Records::Newer if Json.number?(version) && version > Protocol::DECLARATION_VERSION
          return nil unless version == Protocol::DECLARATION_VERSION && inside["invoice"].is_a?(String)
          return nil unless Urls.https_url(inside["verifyUrl"])

          sale_value = inside["sale"]
          return nil unless sale_value.is_a?(Hash) && sale_value["key"] == Text.hex(sale.key)
          return nil unless sale_value["note"].is_a?(String)

          price = parse_price(sale_value["fiat"])
          return nil unless price

          rest = rest_of(inside["rest"], inside.key?("rest"))
          return nil if rest.equal?(Order::ABSENT)

          decoded = Text.well_formed?(inside["invoice"]) ? Bolt11.decode(inside["invoice"]) : nil
          return nil unless decoded && decoded.network == "bc" && decoded.amount_msat
          return nil unless decoded.amount_msat.positive? && (decoded.amount_msat % 1000).zero?
          return nil unless d == Derive.registry_address(sale.registry.key, decoded.payment_hash)

          Opened.new(event: event, invoice: inside["invoice"], decoded: decoded, verify_url: inside["verifyUrl"],
                     price: price, note: sale_value["note"], declared_at: event.created_at, rest: rest)
        end

        # The JSON inside a declaration's `sealed`, nil when it does not open or is not JSON.
        def inside_of(sealed, sale)
          Json.parse_or(Nip44.decrypt(sealed, sale.inner_key))
        rescue Nip44::Invalid, Nip44::UnknownVersion
          nil
        end
      end
    end
  end
end
