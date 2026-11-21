# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The invoices declared for a sale, read back from the merchant's registry (SPEC.md §21): its
      # declarations and its leases of deposit addresses. What create_invoice checks before a new
      # invoice, and find_invoices gives.
      module Sales
        # A declared invoice (a DeclaredInvoice), with its signed declaration (nil for an order paid
        # on-chain only) and its lease's event (nil without an address): published again when the
        # invoice may still be paid.
        Declared = Data.define(:invoice, :event, :lease)

        # What the registry holds of a sale: the order's invoices, oldest first; the rest invoices of
        # each invoice with an address, by rest_key_of of that invoice (its declarations with
        # `rest`, by date then payment hash); the declarations of rest invoices fewer than a majority
        # of the relays sent, by payment hash (published again on a majority before they are used);
        # the sale's leases still held (not withdrawn), by address; how many relays sent each event,
        # by id.
        SaleRecords = Data.define(:invoices, :rests, :unsure_rests, :leases, :sent_by)

        module_function

        # The invoices of `sale` on `relays`, oldest first (by date, then payment hash, then address):
        # read page after page as soon as a majority of the relays answered (each declaration and
        # lease is on a majority of them), or on every relay (`every_relay`: which relays hold a
        # record). One per payment hash, with the address of the sale's confirmed lease naming its
        # invoice; and one per confirmed lease of an order paid on-chain only (invoices_of). A
        # declaration with `rest` is no invoice of the order: one of the rest invoices of the invoice
        # it names. NetworkError when fewer than a majority answered.
        def read(pool, sale, relays, logger:, stop:, every_relay: false)
          needed = Relay.majority(relays.size)
          keep = Internal::Records.that_open do |d, author|
            author == sale.author && d ? Derive.outer_key(sale.registry.key, d, author) : nil
          end
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [sale.author] }
          result = pool.query_relays(relays, filter, sale.secret_key,
                                     paged: true, every_relay: every_relay, keep: keep, stop: stop)
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          declarations, records, sent_by, newer = open_answers(result.answers, sale)
          if newer
            logger.warn("sattleme-checkout: a declaration or a lease of this order has a newer format than this " \
                        "version reads; update the gem")
          end
          newest = newest_records(records)
          rests = Hash.new { |hash, key| hash[key] = [] }
          unsure = {}
          invoices = []
          declarations.each_value do |declaration|
            if declaration.rest.nil?
              invoices << declaration
              next
            end
            hash = declaration.decoded.payment_hash
            unsure[hash] = declaration.event if sent_by.fetch(declaration.event.id, 0) < needed
            rests[rest_key_of(declaration.rest.address, declaration.rest.expires_at)] << Rests.invoice_of(declaration)
          end
          rests.each_value { |list| list.sort_by! { |invoice| Rests.order_key(invoice) } }
          leases = newest.filter_map { |record| record[:lease] if record[:kind] == :lease }
          SaleRecords.new(invoices: invoices_of(sale.ref, invoices, newest), rests: rests.to_h, unsure_rests: unsure,
                          leases: leases.to_h { |lease| [lease.terms.address, lease] }, sent_by: sent_by)
        end

        # Each event the relays sent, opened once per id that checked out: the declarations (one per
        # payment hash), the sale's records at registry addresses, how many relays sent each event,
        # and whether one was of a newer format.
        def open_answers(answers, sale)
          declarations = {}
          records = []
          checked = {}
          sent_by = Hash.new(0)
          newer = false
          answers.each_value do |events|
            # A relay counts for an event when it sent a copy whose id is its hash: it holds that event.
            held = events.select { |value| Events.valid_id?(value) }.map { |value| value["id"] }
            held.uniq.each { |id| sent_by[id] += 1 }
            events.each do |value|
              next if value.is_a?(Hash) && value["id"].is_a?(String) && checked.key?(value["id"])

              declaration = nil
              lease = nil
              begin
                declaration = Declarations.open(value, sale)
                lease = Leases.open_sale_lease(value, sale) unless declaration
              rescue Internal::Records::Newer
                newer = true
                # Authentic (its signature checked before its format), at a registry address: the
                # newest there, it leaves no lease of the sale.
                d = Internal::Records.d_tag_of(value)
                unless d.nil?
                  event = Events.from(value)
                  checked[event.id] = true
                  records << { kind: :newer, event: event, d: d }
                end
                next
              end
              if declaration
                checked[declaration.event.id] = true
                declarations[declaration.decoded.payment_hash] ||= declaration
              elsif lease
                checked[event_of(lease).id] = true
                records << lease
              end
            end
          end
          [declarations, records, sent_by.to_h, newer]
        end

        def event_of(record)
          record[:kind] == :lease ? record[:lease].event : record[:event]
        end

        def d_of(record)
          record[:kind] == :lease ? record[:lease].d : record[:d]
        end

        # Of the sale's records at registry addresses, the newest at each (the highest `created_at`,
        # then the lowest id, as relays keep them): its lease there, or its withdrawal, which leaves
        # none.
        def newest_records(records)
          newest = {}
          records.each do |record|
            d = d_of(record)
            known = newest[d]
            newest[d] = record if known.nil? || Internal::Records.replaces?(event_of(record), event_of(known))
          end
          newest.values
        end

        # The sale's invoices, oldest first (by date, then payment hash, none first, then address),
        # from its declarations (one per payment hash; one with `rest` gives none) and its newest
        # record at each registry address. Only a confirmed lease gives an address: one that is not
        # was left by a create_invoice that failed before the address was the order's. One invoice
        # per declaration, with the address of the newest confirmed lease naming its invoice; and one
        # per confirmed lease of an order paid on-chain only. A lease naming an invoice without a
        # declaration is left out: that invoice was never shown.
        def invoices_of(ref, declarations, newest)
          confirmed = newest.filter_map do |record|
            record[:lease] if record[:kind] == :lease && record[:lease].terms.confirmed == true
          end
          found = declarations.reject(&:rest).map do |declaration|
            decoded = declaration.decoded
            invoice = Text.ascii_lower(declaration.invoice)
            naming = confirmed.select do |opened|
              opened.terms.invoice && Text.ascii_lower(opened.terms.invoice) == invoice
            end
            lease = naming.min { |a, b| Internal::Records.replaces?(a.event, b.event) ? -1 : 1 }
            sats = decoded.amount_msat / 1000
            address = lease&.terms&.address
            Declared.new(invoice: DeclaredInvoice.new(
              ref: ref, bolt11: declaration.invoice, payment_hash: decoded.payment_hash,
              verify_url: declaration.verify_url, onchain_address: address,
              payment_uri: Addresses.payment_uri(address, sats, declaration.invoice), sats: sats.to_s,
              fiat: fiat_of(declaration.price), note: declaration.note, created_at: decoded.timestamp,
              expires_at: decoded.expires_at, declared_at: declaration.declared_at
            ), event: declaration.event, lease: lease&.event)
          end
          confirmed.each do |lease|
            terms = lease.terms
            next unless terms.invoice.nil?

            found << Declared.new(invoice: DeclaredInvoice.new(
              ref: ref, bolt11: nil, payment_hash: nil, verify_url: nil, onchain_address: terms.address,
              payment_uri: Addresses.payment_uri(terms.address, terms.sats, nil), sats: terms.sats.to_s,
              fiat: fiat_of(terms.price), note: terms.note, created_at: terms.created_at,
              expires_at: terms.expires_at,
              # Its mark's date.
              declared_at: lease.event.created_at
            ), event: nil, lease: lease.event)
          end
          found.sort_by do |declared|
            invoice = declared.invoice
            [invoice.created_at, invoice.payment_hash || "", invoice.onchain_address || ""]
          end
        end

        # Step 1 of SPEC.md §21: the indices of the invoices (oldest first) that may still be paid at
        # `now`, until their end and its grace period.
        def may_still_be_paid(invoices, now)
          invoices.each_index.select { |index| now < invoices[index].expires_at + Protocol::GRACE_SECONDS }
        end

        # An invoice's last record: its declaration, or for an invoice paid on-chain only its
        # lease's event (its mark). The one shown has it on a majority of the relays.
        def last_record_of(declared)
          declared.event || declared.lease
        end

        # Of each invoice of `declared` (Declared), whether a majority of the `relays` relays of a
        # read on every relay sent its last record (`sent_by`: how many relays sent each id).
        def held(declared, sent_by, relays)
          declared.map { |invoice| sent_by.fetch(last_record_of(invoice).id, 0) >= Relay.majority(relays) }
        end

        # Of the invoices that may still be paid (oldest first, one or more), from the payment check
        # of each (Settled PaymentStatus) and, of several, whether a majority of the relays sent its
        # last record (`held`, read on every relay; nil when fewer than a majority answered that
        # read): the first paid gives [:paid, index], whatever the read (a payment proves itself);
        # else the first error [:failed, index] (that invoice may have been paid); else, when the
        # read was not answered by a majority, [:unread]. Else [:hand_out, index]: the only one; of
        # several, the only one held (the one shown), else the newest that received something
        # (unconfirmed, or open with received above 0), else the newest.
        def pending_outcome(statuses, held)
          paid = statuses.index { |status| status.ok? && status.value.paid? }
          return [:paid, paid] if paid

          failed = statuses.index { |status| !status.ok? }
          return [:failed, failed] if failed
          return [:hand_out, 0] if statuses.size == 1
          return [:unread] if held.nil?

          shown = held.each_index.select { |index| held[index] }
          return [:hand_out, shown[0]] if shown.size == 1

          received = statuses.rindex do |status|
            status.value.unconfirmed? || (status.value.open? && Integer(status.value.received || "0", 10).positive?)
          end
          [:hand_out, received || (statuses.size - 1)]
        end

        # The key, in SaleRecords#rests, of the invoice with `address` and the end `expires_at`.
        def rest_key_of(address, expires_at)
          "#{address}/#{expires_at}"
        end

        # The price of a declared sale as a Fiat: nil for a sale in sats.
        def fiat_of(price)
          return nil if price["currency"] == Protocol::SATS_CURRENCY

          Fiat.new(amount: Rates.format_decimal(Rates::Decimal.new(units: price["minor"], scale: price["digits"])),
                   currency: price["currency"], minor: price["minor"].to_s, digits: price["digits"])
        end
      end
    end
  end
end
