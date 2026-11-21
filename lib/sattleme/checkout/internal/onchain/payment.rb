# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The payment of an invoice (SPEC.md §31, "The on-chain payment"): its on-chain part, from the
      # explorer and the witnesses of its order, its rest part (the Lightning invoices of the rest
      # of an underpayment), and how they combine with its Lightning part.
      module Payments
        # The on-chain part of an invoice with an address: :underpaid (less than the amount came in
        # time; `final` once the lease ended and nothing is undecided), :unconfirmed (enough, not 3
        # confirmations deep yet on the explorer read), or :paid.
        OnchainPart = Data.define(:kind, :received, :final, :confirmations, :txids) do
          def self.underpaid(received, final)
            new(kind: :underpaid, received: received, final: final,
                confirmations: nil, txids: [].freeze)
          end

          def self.unconfirmed(received, confirmations, txids)
            new(kind: :unconfirmed, received: received, final: false,
                confirmations: confirmations, txids: txids)
          end

          def self.paid(received, txids)
            new(kind: :paid, received: received, final: true, confirmations: nil,
                txids: txids)
          end
        end

        # What the on-chain part of an invoice needs: its address, amount and end; the order's sale
        # (its author); the clock (`clock.call`: Unix seconds, read once the explorer answered); the
        # HTTP context (for BlockCypher); the explorer of the call (CallExplorer: mempool.space, or
        # the merchant's Bitcoin node with its fallback); and, as callables, the read of the order's witnesses
        # (`read_witnesses.call(every_relay)`), a witness address (`witness_address.call(txid, sale)`),
        # the publication of a witness on a majority (`publish.call(witness)`); the logger; what the
        # rest invoices paid and the order's tolerance, each a callable that gives it once known (read
        # at the same time); the read of the merchant's acceptance of the invoice
        # (`read_merchant_acceptance.call`: a MerchantAcceptances::Acceptance, read on every relay at
        # the same time as the witnesses, when some transaction pays the address; NetworkError when
        # fewer than a majority answered).
        Check = Data.define(:address, :sats, :expires_at, :sale, :clock, :http, :explorer, :read_witnesses,
                            :witness_address, :publish, :logger, :paid_by_rests, :tolerance,
                            :read_merchant_acceptance)

        # The rest part of an invoice: its rest invoices and the Lightning part of each (Settled), in
        # order; the error of the read of the sale's records (whether a rest invoice was paid cannot
        # be told), nil without one; the payment hashes of the rest invoices whose rest record is not
        # known on a majority of the relays (never the status's `bolt11`).
        RestPart = Data.define(:invoices, :results, :error, :unrecorded) do
          def self.of(invoices, results) = new(invoices: invoices, results: results, error: nil, unrecorded: {}.freeze)
          def self.failed(error) = new(invoices: [].freeze, results: [].freeze, error: error, unrecorded: {}.freeze)
        end

        # What the rest invoices paid (each payment hash once), their preimages in order, the hashes
        # paid, whether each is final, and the first error (nil without one).
        Summary = Data.define(:paid, :preimages, :hashes, :final, :error)

        # What an invoice is, for its status: its amount, its end, its address (nil without one).
        Terms = Data.define(:sats, :expires_at, :address)

        module_function

        # The on-chain part of an invoice, checked at `now`, the clock once the explorer answered:
        # each transaction paying its address in time (while the lease ran, as a witness of the sale
        # or BlockCypher's time says), a replacement of payments in time, late, or undecided; what
        # counts of them; and, once enough counts, the confirmations on the explorer read: paid at 3.
        # Publishes the witnesses it finds (of the sale on a majority, else NetworkError; of none for
        # the merchant's app only, a failure logged). What is due on-chain is the least the order's
        # tolerance accepts of the amount, or the `received` of the merchant's acceptance a majority
        # of the relays sent when less, less what its rest invoices paid, a sat at least
        # (Tolerance.due_onchain): when they pay the amount, the part is :paid without transactions.
        # A witness or a merchant's acceptance of a newer format is logged. NetworkError when the
        # explorer (with its fallback), BlockCypher or the relays fail.
        def check_onchain(check, stop)
          address = check.address
          ending = check.expires_at + Protocol::GRACE_SECONDS
          # One read, of one explorer: a transaction's confirmations compare its block's height with
          # that explorer's height. Either failing, both are asked of the next explorer (SPEC.md §31).
          txs, height = check.explorer.read(check.http) do |base, http|
            listing = Future.spawn { Explorer.address_transactions(base, address, http) }
            tip = Future.spawn { Explorer.chain_height(base, http) }
            Internal.all([listing, tip], http.stop)
          end
          # After the explorer's answer, never before: listed now, a transaction was broadcast by now.
          now = check.clock.call
          paying = []
          txs.each do |tx|
            pays = tx.pays_to(address)
            paying << [tx, pays] if pays.positive? && paying.none? { |other, _| other.txid == tx.txid }
          end
          # The witnesses, and the merchant's acceptance at the same time (on every relay), when some
          # transaction pays the address.
          accepting = Future.spawn { check.read_merchant_acceptance.call } unless paying.empty?
          witnesses = paying.empty? ? Witnesses::NONE : check.read_witnesses.call(false)
          accepted = accepting ? accepting.value(stop) : MerchantAcceptances::NONE
          check.logger.warn(MerchantAcceptances::NEWER_FORMAT) if accepted.newer
          listed = paying.to_h { |tx, _| [tx.txid, true] }
          parts = parts_of(witnesses, paying, listed)
          kinds, of_sale, of_none = judge(check, paying, witnesses, parts, ending, now)
          publish_witnesses(check, of_sale, of_none, stop)
          newer = !witnesses.newer.empty?
          # Its witnesses on a majority, read again on every relay: of two checks that publish
          # witnesses of one transaction at once, the later reader sees both, whatever one relay hides.
          unless of_sale.empty?
            again = check.read_witnesses.call(true)
            newer ||= !again.newer.empty?
            parts_again = parts_of(again, paying, listed)
            paying.map(&:first).each { |tx| kinds[tx.txid] = :anothers if anothers?(again, parts_again, tx.txid) }
          end
          if newer
            check.logger.warn("sattleme-checkout: a witness of this address has a newer format than this version " \
                              "reads; update the gem")
          end
          count(check, paying, witnesses, parts, kinds, listed, height, ending, now, accepted)
        end

        # The parts of the transactions paying the address (Replacements.parts), from the witnesses of
        # this invoice and of other invoices (in the order they were seen), then the transactions no
        # such witness names (their order unknown): a replacement of another invoice's payment stands
        # for it.
        def parts_of(witnesses, paying, listed)
          known = witnesses.sale.merge(witnesses.others) { |_, mine, _| mine }
          entries = witnesses.sale.to_a + witnesses.others.to_a
          from_witnesses = entries.map do |txid, witness|
            Replacements::PaymentTx.new(txid: txid, sats: witness.sats, inputs: witness.inputs, order: witness.seen_at,
                                        listed: listed.key?(txid))
          end
          unnamed = paying.reject { |tx, _| known.key?(tx.txid) }.map do |tx, pays|
            Replacements::PaymentTx.new(txid: tx.txid, sats: pays, inputs: tx.coins, order: nil, listed: true)
          end
          Replacements.parts(from_witnesses + unnamed)
        end

        # Another invoice's: a witness of another invoice names it, or the root of one of its parts.
        def anothers?(witnesses, parts, txid)
          witnesses.others.key?(txid) || parts.fetch(txid).any? { |part| witnesses.others.key?(part.root) }
        end

        # Step 3 of SPEC.md §31, "The on-chain payment": the kind of each transaction paying the
        # address (:in_time, :replacement, :late, :undecided or :anothers), and the witnesses to
        # publish, of the sale and of none.
        def judge(check, paying, witnesses, parts, ending, now)
          sale = check.sale
          newer_names = ->(txid, of) { witnesses.newer.key?(check.witness_address.call(txid, of)) }
          # A witness of a newer format that names no transaction listed may be of a payment replaced.
          newer_elsewhere = witnesses.newer.keys.any? do |d|
            paying.none? do |tx, _|
              d == check.witness_address.call(tx.txid, sale) || d == check.witness_address.call(tx.txid, nil)
            end
          end
          kinds = {}
          of_sale = []
          of_none = []
          witness_of = lambda do |tx, pays, for_sale, replacement|
            Witnesses::Witness.new(address: check.address, txid: tx.txid, sale: for_sale ? sale : nil, sats: pays,
                                   inputs: tx.coins.first(Protocol::MAX_WITNESS_INPUTS), replacement: replacement,
                                   expires_at: for_sale ? check.expires_at : nil)
          end
          paying.each do |tx, pays|
            txid = tx.txid
            # Another invoice's: a transaction counts for one invoice at most.
            if anothers?(witnesses, parts, txid)
              kinds[txid] = :anothers
              next
            end
            witness = witnesses.sale[txid]
            if witness && !witness.replacement
              kinds[txid] = :in_time
              next
            end
            if newer_names.call(txid, sale)
              kinds[txid] = :undecided
              next
            end
            if now <= ending
              # Listed now, it was broadcast by now: while the lease runs.
              kinds[txid] = :in_time
              of_sale << witness_of.call(tx, pays, true, false)
              next
            end
            if witness
              # An earlier check found it a replacement, and BlockCypher's time of it late.
              kinds[txid] = :replacement
              next
            end
            # No check saw it in time.
            own = parts.fetch(txid)
            replaces = own.any? { |part| part.root != txid }
            if own.any? { |part| part.root == txid }
              time = Explorer.received_at(txid, check.http)
              if time && time <= ending * 1000
                kinds[txid] = :in_time
                of_sale << witness_of.call(tx, pays, true, false)
                next
              end
            end
            if newer_elsewhere
              kinds[txid] = :undecided
            elsif replaces
              kinds[txid] = :replacement
              of_sale << witness_of.call(tx, pays, true, true)
            else
              # Its payment reaches the merchant's wallet, but no order. A witness none names it
              # already, or one of a newer format holds that witness's address: never written over.
              kinds[txid] = :late
              unless witnesses.none.key?(txid) || newer_names.call(txid, nil)
                of_none << witness_of.call(tx, pays, false, false)
              end
            end
          end
          [kinds, of_sale, of_none]
        end

        # Publishes the witnesses of the sale (on a majority, else NetworkError) and of none (a
        # failure logged), all at once.
        def publish_witnesses(check, of_sale, of_none, stop)
          futures = of_sale.map { |witness| Future.spawn("sattleme-checkout witness") { check.publish.call(witness) } }
          futures += of_none.map do |witness|
            Future.spawn("sattleme-checkout witness") do
              check.publish.call(witness)
            rescue NetworkError => e
              check.logger.warn("sattleme-checkout: the witness of a late payment was not published: #{e.message}")
            end
          end
          Internal.all(futures, stop)
        end

        # Step 4 of SPEC.md §31, "The on-chain payment": what counts, what is due, and the part.
        def count(check, paying, witnesses, parts, kinds, listed, height, ending, now, accepted)
          in_time = lambda do |root|
            listed.key?(root) ? kinds[root] == :in_time : witnesses.sale[root]&.replacement == false
          end
          counted = {}
          paying.map(&:first).each do |tx|
            next if %i[undecided anothers].include?(kinds[tx.txid])

            sum = parts.fetch(tx.txid).select { |part| in_time.call(part.root) }.sum(&:sats)
            counted[tx.txid] = sum if sum.positive?
          end
          received = counted.values.sum
          # Nothing due when the rest invoices paid it all; else the least the order's tolerance
          # accepts, or what the merchant accepted when less, less what they paid, at least a sat.
          due = Tolerance.due_onchain(check.sats, check.tolerance.call, check.paid_by_rests.call, accepted.received)
          return OnchainPart.paid(received, []) if due.zero?
          return OnchainPart.underpaid(received, now > ending && !kinds.value?(:undecided)) if received < due

          order = paying.filter_map { |tx, _| tx if counted.key?(tx.txid) }
          txids = order.map(&:txid)
          confirmations = order.map { |tx| tx.confirmations(height) }.min
          # 3 confirmations on the explorer read: what it alone shows makes the payment count as made.
          return OnchainPart.paid(received, txids) if confirmations >= Protocol::CONFIRMATIONS

          OnchainPart.unconfirmed(received, confirmations, txids)
        end

        # What the rest invoices of `rests` paid (each payment hash once; one that failed counts as
        # not paid), their preimages in order, whether each is final, and the first error.
        def rest_summary(rests)
          paid = 0
          preimages = []
          hashes = {}
          final = true
          error = nil
          if rests&.error
            final = false
            error = rests.error
          end
          # In the order of the rest invoices (by date, then payment hash), whatever the order given.
          order = (rests&.invoices || []).each_with_index.map { |invoice, index| [invoice, rests.results[index]] }
          order = order.sort_by { |invoice, _| Rests.order_key(invoice) }
          order.each do |invoice, result|
            unless result.ok?
              final = false
              error ||= result.error
              next
            end
            if result.value.paid?
              next if hashes.key?(invoice.payment_hash)

              hashes[invoice.payment_hash] = true
              paid += invoice.sats
              preimages << result.value.preimage
            elsif result.value.open?
              final = false
            end
          end
          Summary.new(paid: paid, preimages: preimages, hashes: hashes, final: final, error: error)
        end

        # The status of an invoice from its parts (SPEC.md §31): paid in Lightning, else paid by its
        # rest invoices alone, else paid on-chain (mixed when rest invoices paid part of it), else
        # unconfirmed on-chain, else an error of a part (the Lightning part's first, then the rest
        # part's, then the on-chain part's, raised), else expired once every part is final, else
        # open, with its rest. A part is nil when the invoice has none (no Lightning invoice, no
        # address); `lightning` and `onchain` are Settled. `received` counts what the rest invoices
        # paid.
        def combine(terms, now, lightning, onchain, rests = nil)
          return PaymentStatus.paid_lightning(lightning.value.preimage) if lightning&.ok? && lightning.value.paid?

          summary = rest_summary(rests)
          onchain_value = onchain&.ok? ? onchain.value : nil
          if summary.paid >= terms.sats
            # What came on-chain in time counts too (0 when the on-chain part failed).
            received = (onchain_value&.received || 0) + summary.paid
            return PaymentStatus.paid_mixed(received: received.to_s, txids: [], preimages: summary.preimages)
          end
          if onchain_value&.kind == :paid
            received = (onchain_value.received + summary.paid).to_s
            if summary.paid.positive?
              return PaymentStatus.paid_mixed(received: received, txids: onchain_value.txids,
                                              preimages: summary.preimages)
            end

            return PaymentStatus.paid_onchain(received: received, txids: onchain_value.txids)
          end
          if onchain_value&.kind == :unconfirmed
            return PaymentStatus.unconfirmed(received: (onchain_value.received + summary.paid).to_s,
                                             confirmations: onchain_value.confirmations, txids: onchain_value.txids)
          end
          raise lightning.error if lightning && !lightning.ok?
          raise summary.error if summary.error
          raise onchain.error if onchain && !onchain.ok?

          underpaid = onchain_value&.kind == :underpaid ? onchain_value : nil
          received = (underpaid&.received || 0) + summary.paid
          lightning_final = lightning.nil? || lightning.value.expired?
          onchain_final = onchain.nil? || underpaid&.final == true
          return PaymentStatus.expired(received: received.to_s) if lightning_final && onchain_final && summary.final

          PaymentStatus.open(expires_at: terms.expires_at, received: received.to_s,
                             rest: open_rest(terms, now, received, rests, summary))
        end

        def open_rest(terms, now, received, rests, summary)
          return nil if terms.address.nil?

          unrecorded = rests&.unrecorded || {}
          recorded = (rests&.invoices || []).reject { |invoice| unrecorded.key?(invoice.payment_hash) }
          Rests.rest_of(sats: terms.sats, expires_at: terms.expires_at, address: terms.address, received: received,
                        now: now, rests: recorded, paid: summary.hashes)
        end
      end
    end
  end
end
