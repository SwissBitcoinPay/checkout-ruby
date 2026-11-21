# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # What a caller gives, checked before any request (SPEC.md §17, §22, §23): an order, a stored
      # invoice, an option. Refused, never repaired. Each refusal names the parameter as the caller
      # wrote it (`duration_seconds`, `redirect_url`).
      module Order
        # An order, checked: exactly one of `sats` (Integer) and `fiat` (Fiat); the rate sources of
        # an order in a currency (nil in sats); the label (the note, else the reference); `checkout`;
        # its redirect URL (nil without one).
        Checked = Data.define(:ref, :sats, :fiat, :rate_sources, :duration_seconds, :label, :checkout,
                              :redirect_url)

        # A stored invoice, checked: what its payment check asks. `ref` with an address only (its
        # witnesses are its order's), `lightning` nil for an order paid on-chain only.
        Stored = Data.define(:ref, :lightning, :onchain_address, :sats, :expires_at)

        PARAMETERS = %i[ref sats fiat rate_source duration_seconds note checkout redirect_url].freeze
        RATE_SOURCE_RULE = "#{Rates::NAMES.map { |name| "\"#{name}\"" }.join(", ")} or a callable, or a " \
                           "non-empty list of them without the same name twice".freeze
        NOT_STORED = "not an invoice made by create_invoice"
        INVOICE_MEMBERS = %w[ref bolt11 paymentHash verifyUrl onchainAddress sats expiresAt].freeze
        ABSENT = Object.new.freeze

        module_function

        # `ref`, checked: InvalidOrderError (`ref`) unless it is 1 to 64 characters of REF_PATTERN.
        # A String only: every order without one would otherwise be one sale (`sale//v1`).
        def check_ref(value)
          ref = Text.caller_text(value)
          raise InvalidOrderError.new("ref", Protocol::REF_RULE) unless ref&.match?(Protocol::REF_PATTERN)

          ref
        end

        # The order's parameters (`order`: a Hash of PARAMETERS, nil for absent), checked.
        # `client_rate_sources` are the client's: an order in a currency without its own
        # `rate_source` uses them.
        def check(order, client_rate_sources)
          unknown = order.keys - PARAMETERS
          unless unknown.empty?
            raise InvalidOrderError.new("order", "unknown parameter #{unknown.map(&:inspect).join(", ")}; " \
                                                 "expected ref:, sats: or fiat:, and optionally " \
                                                 "#{PARAMETERS.drop(3).map { |name| "#{name}:" }.join(", ")}")
          end
          ref = check_ref(order[:ref])
          raise InvalidOrderError.new("sats", "give either sats or fiat") if order[:sats].nil? == order[:fiat].nil?

          sats = order[:sats].nil? ? nil : check_sats(order[:sats])
          fiat = order[:fiat].nil? ? nil : Rates.parse_fiat(order[:fiat])
          # Given, nil included, it is checked: only absent does it take the client's (SPEC.md §26).
          rate_sources = rate_sources_of(order.fetch(:rate_source, ABSENT), fiat, client_rate_sources)
          Checked.new(ref: ref, sats: sats, fiat: fiat, rate_sources: rate_sources,
                      duration_seconds: duration_of(order[:duration_seconds]), label: label_of(order[:note], ref),
                      checkout: checkout_of(order[:checkout]), redirect_url: redirect_url_of(order))
        end

        def rate_sources_of(value, fiat, client_rate_sources)
          return fiat ? client_rate_sources : nil if value.equal?(ABSENT)
          raise InvalidOrderError.new("rate_source", "only for an order priced in a currency (fiat)") unless fiat

          Rates.source_list(value) || raise(InvalidOrderError.new("rate_source", RATE_SOURCE_RULE))
        end

        def duration_of(value)
          return Protocol::DEFAULT_DURATION_SECONDS if value.nil?

          least = Protocol::MIN_DURATION_SECONDS
          most = Protocol::MAX_DURATION_SECONDS
          return value if value.is_a?(Integer) && value.between?(least, most)

          raise InvalidOrderError.new("duration_seconds", "#{least} to #{most} seconds")
        end

        def checkout_of(value)
          return false if value.nil?
          raise InvalidOrderError.new("checkout", "true or false") unless [true, false].include?(value)

          value
        end

        # The redirect URL: with `checkout` true only, a redirect URL (SPEC.md §30).
        def redirect_url_of(order)
          return nil if order[:redirect_url].nil?
          raise InvalidOrderError.new("redirect_url", "only with checkout: true") unless order[:checkout] == true

          url = Text.caller_text(order[:redirect_url])
          if url.nil? || CheckoutLinks.redirect_shown(url).nil?
            raise InvalidOrderError.new("redirect_url",
                                        "an https URL (lowercase host, no user name nor password) or an app's " \
                                        "link (scheme://…), 2048 characters at most, without spaces nor other " \
                                        "characters to escape")
          end

          url
        end

        # Sats: an Integer, or a String of 1 to 18 digits, from 1 to 21 million BTC.
        def check_sats(value)
          text = value.is_a?(String) ? Text.caller_text(value) : nil
          sats = if value.is_a?(Integer)
                   value
                 elsif text&.match?(/\A[0-9]{1,18}\z/)
                   Integer(text, 10)
                 end
          unless sats&.between?(1, Protocol::MAX_SATS)
            raise InvalidOrderError.new("sats", "a whole number of sats, from 1 to #{Protocol::MAX_SATS}")
          end

          sats
        end

        # The note, without the spaces (U+0020) around it, else the reference: 100 code points at
        # most, well-formed, without control characters.
        def label_of(value, ref)
          return ref if value.nil?
          raise InvalidOrderError.new("note", "a string") unless value.is_a?(String)
          # Control characters are ASCII bytes, the same in every ASCII-compatible encoding.
          if value.encoding.ascii_compatible? && value.b.match?(/[\x00-\x1F\x7F]/n)
            raise InvalidOrderError.new("note", "no control characters")
          end

          note = Text.caller_text(value)
          raise InvalidOrderError.new("note", "well-formed Unicode") if note.nil?
          raise InvalidOrderError.new("note", "no control characters") if Text.control_character?(note)

          label = note.sub(/\A +/, "").sub(/ +\z/, "")
          label = ref if label.empty?
          if Text.code_point_length(label) > Protocol::MAX_NOTE_LENGTH
            raise InvalidOrderError.new("note", "#{Protocol::MAX_NOTE_LENGTH} characters at most")
          end

          label
        end

        # A stored invoice (an Invoice, a DeclaredInvoice, a Hash of its JSON members, String or
        # Symbol names, or its JSON text), checked (SPEC.md §22): its sats and end; a mainnet invoice
        # of exactly its sats, its own payment hash and end, an https verify URL, or none of the
        # three; a deposit address, or none (absent: none); at least one of the two. With an address,
        # its reference: the witnesses of its payment are its order's. InvalidOrderError (`invoice`).
        def check_stored_invoice(invoice)
          fields = invoice_fields(invoice)
          raise InvalidOrderError.new("invoice", NOT_STORED) unless fields

          sats_text = Text.caller_text(fields["sats"])
          sats = sats_text&.match?(/\A[0-9]{1,16}\z/) ? Integer(sats_text, 10) : nil
          expires_at = fields["expiresAt"]
          unless sats&.between?(1, Protocol::MAX_SATS) && Json.safe_integer?(expires_at)
            raise InvalidOrderError.new("invoice", NOT_STORED)
          end

          expires_at = expires_at.to_i
          lightning = stored_lightning(fields, sats, expires_at)
          address = fields["onchainAddress"]
          address = nil if address.equal?(ABSENT)
          address = Text.caller_text(address) unless address.nil?
          raise InvalidOrderError.new("invoice", NOT_STORED) unless address.nil? || Addresses.deposit?(address)
          raise InvalidOrderError.new("invoice", NOT_STORED) if lightning.nil? && address.nil?

          ref = nil
          unless address.nil?
            ref = Text.caller_text(fields["ref"])
            unless ref&.match?(Protocol::REF_PATTERN)
              raise InvalidOrderError.new("invoice", "#{NOT_STORED}: with an address, its ref (#{Protocol::REF_RULE})")
            end
          end
          Stored.new(ref: ref, lightning: lightning, onchain_address: address, sats: sats, expires_at: expires_at)
        end

        # The Lightning invoice of a stored invoice: nil, with its payment hash and verify URL nil
        # too, or a mainnet invoice of exactly its sats, its payment hash and end, an https verify URL.
        def stored_lightning(fields, sats, expires_at)
          bolt11, payment_hash, verify_url = fields.values_at("bolt11", "paymentHash", "verifyUrl")
          if bolt11.nil?
            raise InvalidOrderError.new("invoice", NOT_STORED) unless payment_hash.nil? && verify_url.nil?

            return nil
          end

          bolt11 = Text.caller_text(bolt11)
          decoded = bolt11 && Bolt11.decode(bolt11)
          payment_hash = Text.caller_text(payment_hash)
          verify_url = Text.caller_text(verify_url)
          unless decoded && decoded.network == "bc" && decoded.amount_msat == sats * 1000 &&
                 Text.hex32?(payment_hash) && decoded.payment_hash == payment_hash &&
                 decoded.expires_at == expires_at && Urls.https_url(verify_url)
            raise InvalidOrderError.new("invoice", NOT_STORED)
          end

          Lnurl::LightningInvoice.new(bolt11: bolt11, payment_hash: payment_hash, verify_url: verify_url,
                                      expires_at: expires_at)
        end

        # The members of a stored invoice by their JSON names (ABSENT for one it lacks), nil when it
        # is none of the forms taken.
        def invoice_fields(invoice)
          hash = case invoice
                 when Invoice, DeclaredInvoice then invoice.to_h
                 when Hash then invoice
                 when String then Json.parse_or(Text.caller_text(invoice) || "")
                 end
          return nil unless hash.is_a?(Hash)

          INVOICE_MEMBERS.to_h do |name|
            [name, if hash.key?(name)
                     hash[name]
                   else
                     (hash.key?(name.to_sym) ? hash[name.to_sym] : ABSENT)
                   end]
          end
        end

        # A whole number of milliseconds within [min, max], `fallback` when nil. InvalidOptionError
        # naming `name`.
        def check_milliseconds(value, fallback, min, max, name)
          return fallback if value.nil?
          unless value.is_a?(Integer) && value.between?(min, max)
            raise InvalidOptionError.new(name, "a whole number of milliseconds, #{min} to #{max}")
          end

          value
        end
      end
    end
  end
end
