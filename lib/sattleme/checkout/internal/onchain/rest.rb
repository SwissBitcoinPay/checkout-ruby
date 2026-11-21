# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The rest of an on-chain underpayment (SPEC.md §31, "The rest of an underpayment"): when less
      # than the amount came on-chain in time, a payment check asks the merchant's Lightning address
      # for an invoice of the rest, declares it for the order's sale with `rest` (the address), and
      # publishes a rest record, which the pages of the order's checkout links read (they cannot read
      # the registry). From ONCHAIN_FLOOR_SATS, the rest is payable on-chain to the same address
      # too; below, in Lightning only.
      module Rests
        # A rest invoice: a declaration of the sale with `rest`, its invoice decoded: its amount, its
        # BOLT11 timestamp and that + its expiry (Unix seconds).
        Invoice = Data.define(:bolt11, :payment_hash, :verify_url, :sats, :created_at, :expires_at) do
          # What the Lightning part of a payment check needs of it.
          def lightning
            Lnurl::LightningInvoice.new(bolt11: bolt11, payment_hash: payment_hash, verify_url: verify_url,
                                        expires_at: expires_at)
          end
        end

        # What a check asks for: an invoice of `sats`, lasting `expiry_seconds`.
        Ask = Data.define(:sats, :expiry_seconds)

        # The invoice of the order a rest record belongs to: its amount and dates, as its link holds
        # them.
        LinkTerms = Data.define(:sats, :created_at, :expires_at)

        # A rest record, opened as the page reads it: its invoice, decoded.
        OpenedRest = Data.define(:invoice, :event)

        # What a read of the rest records of an invoice tells: the payment hashes of the rest invoices
        # whose record a majority of the relays sent, and the addresses (`d` tags) of the records of a
        # newer format any relay sent: such a record holds its address, never written over.
        RecordsRead = Data.define(:held, :newer)

        module_function

        # The rest invoice of a declaration with `rest` (opened: its invoice decodes, in whole sats).
        def invoice_of(declaration)
          decoded = declaration.decoded
          Invoice.new(bolt11: declaration.invoice, payment_hash: decoded.payment_hash,
                      verify_url: declaration.verify_url, sats: decoded.amount_msat / 1000,
                      created_at: decoded.timestamp, expires_at: decoded.expires_at)
        end

        # The order of the rest invoices: by date, then payment hash.
        def order_key(invoice)
          [invoice.created_at, invoice.payment_hash]
        end

        # The `rest` of an open status (SPEC.md §31, "The status's rest"): nil unless `received` is
        # above 0 before the invoice's end; else what is left, the latest rest invoice of exactly that
        # amount neither paid nor ended (`paid`: the payment hashes paid), and its QR code: on-chain
        # to `address` too from ONCHAIN_FLOOR_SATS, in Lightning only below.
        def rest_of(sats:, expires_at:, address:, received:, now:, rests:, paid:)
          return nil if received <= 0 || received >= sats || now >= expires_at

          rest = sats - received
          invoice = rests.sort_by { |candidate| order_key(candidate) }.reverse.find do |candidate|
            candidate.sats == rest && !paid.key?(candidate.payment_hash) && now < candidate.expires_at
          end
          bolt11 = invoice&.bolt11
          uri = if rest >= Protocol::ONCHAIN_FLOOR_SATS
                  Addresses.payment_uri(address, rest, bolt11)
                elsif bolt11
                  "lightning:#{bolt11}"
                end
          Rest.new(sats: rest.to_s, bolt11: bolt11, payment_uri: uri)
        end

        # Whether a check whose status gave `rest` asks for an invoice of it (SPEC.md §31, "Asking
        # for a rest invoice"), and which: none when it has one, with less than MIN_REST_SECONDS
        # left, or when the sale's lease of the address is not the invoice's (`lease`: its terms, nil
        # without one). The Lightning address's sendable sats are checked after: its pay request is
        # asked only then.
        def to_ask(rest:, sats:, expires_at:, now:, lease:)
          return nil if rest.nil? || !rest.bolt11.nil?
          return nil if now + Protocol::MIN_REST_SECONDS > expires_at
          return nil if lease.nil? || lease.sats != sats || lease.expires_at != expires_at

          Ask.new(sats: Integer(rest.sats, 10), expiry_seconds: expires_at - now)
        end

        # Whether `sats` is within the Lightning address's sendable sats ([min, max]).
        def sendable?(sats, bounds)
          sats.between?(bounds[0], bounds[1])
        end

        # The rest record of `invoice` (SPEC.md §31, "Rest records"): its invoice and verify URL,
        # sealed with the rest encryption key at the rest record address of its payment hash, signed
        # by the rest secret at `created_at`, dropped by the relays a week after the end of the
        # order's invoice (`expires_at`), as its checkout links.
        def record_event(keys:, invoice:, expires_at:, created_at:, random:)
          Internal::Records.seal(
            type: Protocol::REST_RECORD_TYPE,
            value: { "version" => Protocol::REST_VERSION, "invoice" => invoice.bolt11,
                     "verifyUrl" => invoice.verify_url },
            signer: keys.secret_key, encryption_key: keys.encryption_key,
            address: Derive.rest_record_address(keys.key, invoice.payment_hash), created_at: created_at, random: random,
            tags: [["expiration", (expires_at + Protocol::CHECKOUT_LIFE_SECONDS).to_s]]
          )
        end

        # What a relay sent, if it is a rest record of the rest author and rest key of a checkout link
        # of an invoice `terms` describes (SPEC.md §31, "Reading a rest record"): nil when it is not
        # one; :newer for one of a newer format, which the page leaves aside. An event at the link's
        # acceptance record address (same author) is no rest record, of a newer format or not.
        def open_record(value, keys, terms)
          d = Internal::Records.d_tag_of(value)
          return nil if d.nil? || d == Derive.acceptance_record_address(keys.key)

          opened = Internal::Records.open(value, type: Protocol::REST_RECORD_TYPE, encryption_key: keys.encryption_key,
                                                 address: d, author: keys.author) do |record, _|
            parse_record(record, keys, terms, d)
          end
          return nil unless opened
          return :newer if opened.newer?

          OpenedRest.new(invoice: opened.value, event: opened.event)
        end

        def parse_record(value, keys, terms, d)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Internal::Records::Newer if Json.number?(version) && version > Protocol::REST_VERSION
          return nil unless version == Protocol::REST_VERSION && Text.well_formed?(value["invoice"])
          return nil unless Urls.https_url(value["verifyUrl"])

          decoded = Bolt11.decode(value["invoice"])
          return nil unless decoded && decoded.network == "bc" && decoded.amount_msat
          return nil unless decoded.amount_msat.positive? && (decoded.amount_msat % 1000).zero?

          sats = decoded.amount_msat / 1000
          if sats >= terms.sats || decoded.timestamp < terms.created_at - Protocol::CLOCK_TOLERANCE_SECONDS ||
             decoded.expires_at > terms.expires_at + Protocol::CLOCK_TOLERANCE_SECONDS
            return nil
          end
          return nil unless d == Derive.rest_record_address(keys.key, decoded.payment_hash)

          Invoice.new(bolt11: value["invoice"], payment_hash: decoded.payment_hash, verify_url: value["verifyUrl"],
                      sats: sats, created_at: decoded.timestamp, expires_at: decoded.expires_at)
        end

        # What a read of the records of `keys` (their rest author) keeps: those that open with their
        # encryption key (Records.that_open).
        def keep_of(keys)
          Internal::Records.that_open { |_, author| author == keys.author ? keys.encryption_key : nil }
        end

        # The rest records of `keys` on the merchant's `relays`, as the page would read them
        # (RecordsRead): the payment hashes of those a majority sent (a page reading a majority meets
        # each of them), and the addresses of those of a newer format; nil when fewer than a majority
        # answered. Read with a key of this read alone, not paged (a rest record per rest invoice: a
        # few).
        def read_records(pool, keys, terms, relays, random:, stop:)
          needed = Relay.majority(relays.size)
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [keys.author] }
          result = pool.query_relays(relays, filter, random.call(32),
                                     paged: false, stop: stop, keep: Rests.keep_of(keys))
          return nil unless result.answered

          # How many relays sent a valid record of each payment hash.
          sent_by = Hash.new(0)
          newer = {}
          result.answers.each_value do |events|
            hashes = events.filter_map do |value|
              opened = open_record(value, keys, terms)
              newer[Internal::Records.d_tag_of(value)] = true if opened == :newer
              opened.invoice.payment_hash if opened.is_a?(OpenedRest)
            end
            hashes.uniq.each { |hash| sent_by[hash] += 1 }
          end
          RecordsRead.new(held: sent_by.select { |_, count| count >= needed }.to_h { |hash, _| [hash, true] },
                          newer: newer)
        end

        # Publishes a rest record on the merchant's `relays`, signed and authenticated with the rest
        # secret: once a majority took it, else NetworkError.
        def publish_record(pool, event, keys, relays, stop:)
          pool.publish_to_quorum(relays, event, keys.secret_key, Relay.majority(relays.size), stop: stop)
        rescue Relay::Failure
          raise NetworkError, "Fewer than a majority of the merchant's relays took the record of an invoice of the rest"
        end
      end

      # Acceptance records (SPEC.md §31, "Acceptance records"): the page of a checkout link cannot
      # know the merchant's tolerance nor read the merchant's acceptance (MerchantAcceptances), so
      # an order either accepted would read underpaid there, its customer asked for the rest and
      # never sent back to the shop. A check whose status is paid (or being confirmed) with less
      # than the amount publishes what it received then, signed by the rest secret, for the pages
      # of the order's checkout links: they count the payment as enough from that on. Never the
      # tolerance itself.
      module Acceptances
        # An acceptance record, opened as the page reads it.
        Opened = Data.define(:received, :event)

        module_function

        # What a check whose status is `status` must have the pages of the order's checkout links
        # know (SPEC.md §31, "Publishing it"): the status's `received`, when the order's tolerance
        # or the merchant's acceptance accepted less than its amount (`unconfirmed`, or `paid` with
        # transactions) before the links' life ends; nil otherwise.
        def to_publish(status, sats, expires_at, now)
          return nil if now >= expires_at + Protocol::CHECKOUT_LIFE_SECONDS

          accepted = status.unconfirmed? ||
                     (status.paid? && status.payment_method != "lightning" && !status.txids.empty?)
          return nil unless accepted

          received = Integer(status.received, 10)
          received < sats ? received : nil
        end

        # The acceptance record of the invoice of `keys` (its rest keys): `received`, sealed with the
        # rest encryption key at its acceptance record address, signed by the rest secret at
        # `created_at`, dropped by the relays a week after the invoice's end, as its checkout links.
        def record_event(keys:, received:, expires_at:, created_at:, random:)
          Internal::Records.seal(
            type: Protocol::ACCEPTANCE_RECORD_TYPE,
            value: { "version" => Protocol::ACCEPTANCE_VERSION, "received" => received },
            signer: keys.secret_key, encryption_key: keys.encryption_key,
            address: Derive.acceptance_record_address(keys.key), created_at: created_at, random: random,
            tags: [["expiration", (expires_at + Protocol::CHECKOUT_LIFE_SECONDS).to_s]]
          )
        end

        # `value` opened as an acceptance record of `keys` for an invoice of `sats` (a
        # Records::Opened of its `received`), else nil.
        def open_opened(value, keys, sats)
          address = Derive.acceptance_record_address(keys.key)
          return nil unless Internal::Records.d_tag_of(value) == address

          Internal::Records.open(value, type: Protocol::ACCEPTANCE_RECORD_TYPE, encryption_key: keys.encryption_key,
                                        address: address, author: keys.author) do |record, _|
            next nil unless record.is_a?(Hash)

            version = record["version"]
            raise Internal::Records::Newer if Json.number?(version) && version > Protocol::ACCEPTANCE_VERSION
            next nil unless version == Protocol::ACCEPTANCE_VERSION

            received = record["received"]
            next nil unless Json.safe_integer?(received) && received >= 1

            received.to_i < sats ? received.to_i : nil
          end
        end

        # What a relay sent, if it is an acceptance record of the rest author and rest key of a
        # checkout link of an invoice of `sats` (SPEC.md §31, "Reading an acceptance record"): its
        # `received`, from 1, below `sats`; nil when it is not one; :newer for one of a newer format,
        # left aside.
        def open_record(value, keys, sats)
          opened = open_opened(value, keys, sats)
          return nil unless opened
          return :newer if opened.newer?

          Opened.new(received: opened.value, event: opened.event)
        end

        # Whether the pages already know `received` (SPEC.md §31, "Publishing it"): a majority of the
        # merchant's `relays` each sent a valid acceptance record of the invoice of `keys` (of `sats`)
        # whose `received`, the newest it sent, is at most `received`. Read with a key of this read
        # alone, not paged (one record per invoice). True when a relay sent one of a newer format,
        # never written over (logged: update the gem). NetworkError when fewer than a majority
        # answered: nothing is published, the next check reads again.
        def known?(pool, keys, sats, received, relays, random:, logger:, stop:)
          needed = Relay.majority(relays.size)
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [keys.author],
                     "#d" => [Derive.acceptance_record_address(keys.key)] }
          result = pool.query_relays(relays, filter, random.call(32),
                                     paged: false, stop: stop, keep: Rests.keep_of(keys))
          holders = 0
          result.answers.each do |relay, events|
            found = Internal::Records.newest({ relay => events }) { |value| open_opened(value, keys, sats) }
            unless found.newest_unreadable.nil?
              logger.warn("sattleme-checkout: an acceptance record of this order has a newer format than this " \
                          "version reads; update the gem")
              return true
            end

            holders += 1 if !found.value.nil? && found.value <= received
          end
          # Fewer than a majority answered: what the others hold (of a newer format, perhaps) cannot
          # be told, so nothing is written over it; the next check reads again (SPEC.md §13, §12).
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          holders >= needed
        end

        # Lets the pages of the order's checkout links know what its tolerance or the merchant's
        # acceptance accepted (SPEC.md §31, "Acceptance records"), from `status`, the status a check
        # gave at `now` of the invoice of `sats` and `expires_at`: when to_publish gives what it
        # received, publishes an acceptance record of it with the rest keys `keys` gives (asked only
        # then), dated `clock.call`, unless a majority of the merchant's `relays` hold one of it or
        # less (known?). What it published (its `received`), or nil. NetworkError when fewer than a
        # majority answered the read, or took the record.
        def publish(pool, status, sats:, expires_at:, now:, keys:, relays:, clock:, random:, logger:, stop:)
          received = to_publish(status, sats, expires_at, now)
          return nil if received.nil?

          rest = keys.call
          return nil if known?(pool, rest, sats, received, relays, random: random, logger: logger, stop: stop)

          event = record_event(keys: rest, received: received, expires_at: expires_at, created_at: clock.call,
                               random: random)
          publish_record(pool, event, rest, relays, stop: stop)
          received
        end

        # Publishes an acceptance record on the merchant's `relays`, signed and authenticated with the
        # rest secret: once a majority took it, else NetworkError.
        def publish_record(pool, event, keys, relays, stop:)
          pool.publish_to_quorum(relays, event, keys.secret_key, Relay.majority(relays.size), stop: stop)
        rescue Relay::Failure
          raise NetworkError, "Fewer than a majority of the merchant's relays took the acceptance record of a payment"
        end
      end
    end
  end
end
