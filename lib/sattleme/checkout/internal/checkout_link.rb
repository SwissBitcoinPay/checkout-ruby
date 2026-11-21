# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Checkout links (SPEC.md §30): a URL of the merchant's web app,
      # `<origin>/pay#c.<author>.<key>.<relays>`, whose page reads the invoice from the merchant's
      # relays, shows it, checks its payment from the customer's browser and, once it is paid, sends
      # the customer to the order's redirect URL. The record is sealed with a key of the link alone
      # (in the URL's fragment, which browsers never send to the web app's host) and signed by an
      # author of the link alone, whose secret is forgotten once it is published: nobody, the
      # integrator included, can change a link afterwards. The gem writes links; it also reads them
      # (fragments, records), as the page does, for the conformance vectors.
      module CheckoutLinks
        # The authority of an https URL as written: its host and its port.
        HTTPS_AUTHORITY = %r{\Ahttps://([^/?#]*)}
        APP_URL = %r{\A([a-z][a-z0-9+.-]*)://}
        # The first part of a newer link's fragment: 1 to 8 characters `a–z 0–9`.
        MARKER = /\A[a-z0-9]{1,8}\z/

        # A link's keys (from its link key, 32 bytes): its `d` tag (hex) and its NIP-44
        # conversation key.
        Keys = Data.define(:address, :encryption_key) do
          include Redacted

          def inspect = "#<CheckoutLinks::Keys address=#{address}>"
          alias_method :to_s, :inspect
        end

        # A new link, before it is published: its URL, its event, and its author's secret, which
        # answers the relays' authentication while the event is published, then is dropped: never
        # stored, returned to the caller nor logged.
        NewLink = Data.define(:url, :event, :secret_key) do
          include Redacted

          def inspect = "#<CheckoutLinks::NewLink event=#{event.id}>"
          alias_method :to_s, :inspect
        end

        # What a fragment names (SPEC.md §30, "Reading the fragment"): a link (its author, link key
        # and relays), a link of a newer format (the page asks to be updated), an invalid link, or
        # another link of the page.
        Fragment = Data.define(:status, :author, :link_key, :relays) do
          include Redacted

          def inspect = "#<CheckoutLinks::Fragment #{status}>"
          alias_method :to_s, :inspect
        end

        # A link's record, checked: what the page shows. `rest` is [rest author, rest key] of a
        # record of version 2 that carries them, else nil; `bitcoin_node` the merchant's Bitcoin node
        # the page reads the chain from, with its fallback (BitcoinNodes::RecordNode) of a record of
        # version 2 whose `bitcoinNode` is valid, else nil (mempool.space).
        Record = Data.define(:business_name, :invoice, :payment_hash, :verify_url, :onchain_address, :sats,
                             :created_at, :expires_at, :fiat, :note, :redirect_url, :redirect_shown, :rest,
                             :bitcoin_node)

        module_function

        # Whether `value` is a checkout origin: `https://`, a host as in a relay address, an
        # optional port, nothing else (SPEC.md §30, "The web app's origin").
        def origin?(value)
          !Urls.https_url(value).nil? && value.match?(%r{\Ahttps://[^/?#]*\z})
        end

        # The origin a channel's `checkout` field gives: nil when it gives none or an invalid one.
        def origin_of(checkout)
          checkout.is_a?(Hash) && origin?(checkout["origin"]) ? checkout["origin"] : nil
        end

        # What the page shows of a redirect URL ("Redirecting to …"): the host and port of an https
        # URL as written, the scheme and `://` of an app's link. Nil when `value` is not a redirect
        # URL (SPEC.md §30, "Redirect URLs"): nothing is repaired.
        def redirect_shown(value)
          unless Text.match?(value, Urls::URL_CHARACTERS) && value.length <= Protocol::MAX_REDIRECT_URL_LENGTH
            return nil
          end
          return Urls.https_url(value) ? HTTPS_AUTHORITY.match(value)[1] : nil if value.start_with?("https://")

          app = APP_URL.match(value)
          return nil unless app

          scheme = app[1]
          if scheme.length > Protocol::MAX_REDIRECT_SCHEME_LENGTH || scheme == "https" ||
             Protocol::REFUSED_REDIRECT_SCHEMES.include?(scheme)
            return nil
          end

          "#{scheme}://"
        end

        def keys(link_key)
          Keys.new(address: Text.hex(Derive.key(link_key, Protocol::CHECKOUT_SALT, Protocol::CHECKOUT_ADDRESS_INFO)),
                   encryption_key: Derive.key(link_key, Protocol::CHECKOUT_SALT, Protocol::CHECKOUT_ENCRYPTION_INFO))
        end

        # A link author's secret: 32 random bytes, drawn again until they are a secp256k1 secret key.
        def author_secret(random)
          loop do
            secret = random.call(Protocol::KEY_BYTES)
            return secret if Secp256k1.valid_secret?(secret)
          end
        end

        # The URL of a link: `<origin>/pay#c.<author>.<key>.<relays>`.
        def url(origin, author, link_key, relays)
          parts = [Protocol::CHECKOUT_MARKER, Base64.encode_url(Text.hex_bytes(author)), Base64.encode_url(link_key),
                   Relays.encode_list(relays)]
          "#{origin}#{Protocol::CHECKOUT_PATH}##{parts.join(".")}"
        end

        # What a link's record holds of an order's deposit address (version 2): the address, the
        # invoice's amount and dates, its rest author and rest key (Derive::RestKeys), and the node
        # its page reads (BitcoinNodes::RecordNode, nil: the field absent).
        Onchain = Data.define(:address, :sats, :created_at, :expires_at, :rest, :bitcoin_node)

        # What a link's record holds (SPEC.md §30, "The record"), as JSON: version 1 for an invoice
        # without an address (`onchain` nil), version 2 for one with an address (`onchain`, an
        # Onchain; its invoice and verify URL nil for an order paid on-chain only). `bitcoinNode` is
        # the node of BitcoinNodes.record_node_for (the channel's with `payers` true, its `url` and
        # `fallback`), absent without one: never in version 1.
        def value(business_name:, invoice:, verify_url:, fiat:, note:, redirect_url:, onchain:)
          if onchain.nil?
            return { "version" => Protocol::CHECKOUT_VERSION, "businessName" => business_name, "invoice" => invoice,
                     "verifyUrl" => verify_url, "fiat" => fiat, "note" => note, "redirectUrl" => redirect_url }
          end

          value = { "version" => Protocol::CHECKOUT_ONCHAIN_VERSION, "businessName" => business_name,
                    "invoice" => invoice, "verifyUrl" => verify_url, "onchainAddress" => onchain.address,
                    "sats" => onchain.sats, "createdAt" => onchain.created_at, "expiresAt" => onchain.expires_at,
                    "fiat" => fiat, "note" => note, "redirectUrl" => redirect_url }
          rest = onchain.rest
          value.merge!("restAuthor" => rest.author, "restKey" => Text.hex(rest.key)) if rest
          value["bitcoinNode"] = onchain.bitcoin_node.to_h if onchain.bitcoin_node
          value
        end

        # A new link to the invoice `value` holds, ending `expires_at` (Unix seconds): a fresh link
        # key and author, the record signed at `created_at`, dropped by the relays a week after the
        # invoice's end, and the URL on `origin` naming `relays` (where it is to be published).
        def new_link(origin:, relays:, value:, expires_at:, created_at:, random:)
          link_key = random.call(Protocol::KEY_BYTES)
          secret = author_secret(random)
          link_keys = keys(link_key)
          event = Records.seal(type: Protocol::CHECKOUT_RECORD_TYPE, value: value, signer: secret,
                               encryption_key: link_keys.encryption_key, address: link_keys.address,
                               created_at: created_at, random: random,
                               tags: [["expiration", (expires_at + Protocol::CHECKOUT_LIFE_SECONDS).to_s]])
          NewLink.new(url: url(origin, Events.public_key(secret), link_key, relays), event: event, secret_key: secret)
        end

        # The link a URL's fragment (with or without "#") names.
        def parse_fragment(fragment)
          text = Text.well_formed?(fragment) ? fragment.delete_prefix("#") : ""
          marker, author, key, relays, *rest = text.split(".", -1)
          marker ||= ""
          unless marker == Protocol::CHECKOUT_MARKER
            return fragment_of(marker.match?(MARKER) ? :newer : :other)
          end
          return fragment_of(:invalid) if author.nil? || key.nil? || relays.nil? || !rest.empty?

          author_bytes = Base64.decode_url(author)
          link_key = Base64.decode_url(key)
          list = Relays.decode_list(relays)
          unless author_bytes&.bytesize == Protocol::KEY_BYTES && link_key&.bytesize == Protocol::KEY_BYTES && list
            return fragment_of(:invalid)
          end

          author_hex = Text.hex(author_bytes)
          return fragment_of(:invalid) unless Events.public_key?(author_hex)

          Fragment.new(status: :link, author: author_hex, link_key: link_key, relays: list)
        end

        def fragment_of(status)
          Fragment.new(status: status, author: nil, link_key: nil, relays: nil)
        end

        # A price as a link's record has it: nil, or `{minor, digits, currency}` with `minor` from 1,
        # `digits` 0 to 8 and `currency` three letters other than SAT. ABSENT when invalid.
        def price_of(value)
          return nil if value.nil?
          return Order::ABSENT unless value.is_a?(Hash)

          minor, digits, currency = value.values_at("minor", "digits", "currency")
          return Order::ABSENT unless Json.safe_integer?(minor) && minor >= 1
          return Order::ABSENT unless Json.integer?(digits) && digits.between?(0, Protocol::MAX_DECLARED_DIGITS)
          return Order::ABSENT unless Text.match?(currency, /\A[A-Z]{3}\z/) && currency != Protocol::SATS_CURRENCY

          { "minor" => minor.to_i, "digits" => digits.to_i, "currency" => currency }
        end

        # A record's value, checked as the page reads it (SPEC.md §30, "The record"): version 1 or 2.
        # Nil when it is not valid; raises Records::Newer for a newer version.
        def parse_value(value)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Records::Newer if Json.number?(version) && version > Protocol::CHECKOUT_ONCHAIN_VERSION
          return nil unless [Protocol::CHECKOUT_VERSION, Protocol::CHECKOUT_ONCHAIN_VERSION].include?(version)
          return nil unless business_name?(value["businessName"])

          onchain = version == Protocol::CHECKOUT_ONCHAIN_VERSION
          invoice, verify_url = value.values_at("invoice", "verifyUrl")
          lightning = nil
          # Absent is not null: a record of an order paid on-chain only writes both as null.
          if !onchain || !Json.null_member?(value, "invoice") || !Json.null_member?(value, "verifyUrl")
            lightning = lightning_of(invoice, verify_url)
            return nil unless lightning
          end
          terms = lightning
          onchain_address = nil
          rest = nil
          bitcoin_node = nil
          if onchain
            terms = onchain_terms(value, lightning)
            return nil unless terms

            onchain_address = value["onchainAddress"]
            rest = value.key?("restAuthor") || value.key?("restKey") ? rest_of(value) : nil
            return nil if rest.equal?(Order::ABSENT)

            # Set aside when it is not valid, the record valid all the same; ignored in version 1.
            bitcoin_node = BitcoinNodes.record_node_of(value["bitcoinNode"])
          end
          # `fiat` and `redirectUrl` are null or valid: absent, the record is invalid.
          return nil unless value.key?("fiat") && value.key?("redirectUrl")

          fiat = price_of(value["fiat"])
          return nil if fiat.equal?(Order::ABSENT)

          note, redirect_url = value.values_at("note", "redirectUrl")
          return nil unless note?(note)

          shown = redirect_url.nil? ? nil : redirect_shown(redirect_url)
          return nil if !redirect_url.nil? && shown.nil?

          Record.new(business_name: value["businessName"], invoice: lightning ? invoice : nil,
                     payment_hash: lightning&.fetch(:payment_hash), verify_url: lightning ? verify_url : nil,
                     onchain_address: onchain_address, sats: terms[:sats], created_at: terms[:created_at],
                     expires_at: terms[:expires_at], fiat: fiat, note: note, redirect_url: redirect_url,
                     redirect_shown: shown, rest: rest, bitcoin_node: bitcoin_node)
        end

        def business_name?(name)
          Text.well_formed?(name) && !Text.trim_ascii(name).empty? &&
            Text.code_point_length(name) <= Protocol::MAX_BUSINESS_NAME_LENGTH
        end

        def note?(note)
          Text.well_formed?(note) && !Text.control_character?(note) &&
            Text.code_point_length(note).between?(1, Protocol::MAX_NOTE_LENGTH)
        end

        # The terms of a record's Lightning invoice: a string that decodes on network bc, with an
        # amount above 0 and a whole number of sats, and an https verify URL. Nil otherwise.
        def lightning_of(invoice, verify_url)
          decoded = Text.well_formed?(invoice) ? Bolt11.decode(invoice) : nil
          return nil unless decoded && decoded.network == "bc" && decoded.amount_msat
          return nil unless decoded.amount_msat.positive? && (decoded.amount_msat % 1000).zero?
          return nil unless Urls.https_url(verify_url)

          { payment_hash: decoded.payment_hash, sats: decoded.amount_msat / 1000, created_at: decoded.timestamp,
            expires_at: decoded.expires_at }
        end

        # The terms of a record of version 2: its address, sats and dates, which its invoice's (when
        # it has one) must equal. Nil when they are not valid.
        def onchain_terms(value, lightning)
          sats, created_at, expires_at = value.values_at("sats", "createdAt", "expiresAt")
          return nil unless Addresses.deposit?(value["onchainAddress"])
          return nil unless Json.safe_integer?(sats) && sats.to_i.between?(1, Protocol::MAX_SATS)
          return nil unless Json.safe_integer?(created_at) && Json.safe_integer?(expires_at) && created_at < expires_at

          terms = { sats: sats.to_i, created_at: created_at.to_i, expires_at: expires_at.to_i }
          if lightning && (lightning[:sats] != terms[:sats] || lightning[:created_at] != terms[:created_at] ||
                           lightning[:expires_at] != terms[:expires_at])
            return nil
          end

          terms
        end

        # The rest author and rest key of a record of version 2: both or neither (ABSENT otherwise).
        def rest_of(value)
          author, key = value.values_at("restAuthor", "restKey")
          return Order::ABSENT unless Events.public_key?(author) && Text.hex32?(key)

          [author, Text.hex_bytes(key)]
        end
      end
    end
  end
end
