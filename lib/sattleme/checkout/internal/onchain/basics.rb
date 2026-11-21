# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The merchant's tolerance of on-chain underpayments (SPEC.md §31, "The merchant's
      # tolerance"): the share of an order's amount its payment in time may miss and still pay it,
      # in basis points. The channel gives it, an order's lease keeps the one of its creation: every
      # check of the order judges its payment with that one, as the merchant's app does. It is never
      # written where the shop's page or the customer reads (the Invoice, the PaymentStatus, a
      # checkout link's record, an error, a log): a customer who knew it could pay that much less.
      module Tolerance
        module_function

        # A tolerance as a channel or a lease writes it: an integer from 0 to MAX_TOLERANCE, else 0.
        def of(value)
          Json.integer?(value) && value.between?(0, Protocol::MAX_TOLERANCE) ? value.to_i : 0
        end

        # The least accepted of `sats` with `tolerance` (basis points): `sats` less the share the
        # tolerance allows, rounded down to the whole sat. On integers.
        def least_accepted(sats, tolerance)
          sats - ((sats * of(tolerance)) / Protocol::TOLERANCE_SCALE)
        end

        # What is due on-chain of an invoice of `sats` with `tolerance`, its rest invoices having paid
        # `paid_by_rests`, with the `received` of the merchant's acceptance that counts,
        # `merchant_accepted` (nil without one: MerchantAcceptances) (SPEC.md §31, "The on-chain
        # payment", step 4): nothing (0) when they paid `sats` or more; else max(1, min(L, M) − R),
        # L the least accepted, M the merchant's acceptance's `received` (`sats` without one), R
        # what they paid. R is taken once from the lesser: M counts the rest invoices paid when the
        # merchant accepted, as L counts every payment. At least 1 sat: something must count
        # on-chain for the tolerance or the merchant's acceptance to apply.
        def due_onchain(sats, tolerance, paid_by_rests, merchant_accepted = nil)
          return 0 if paid_by_rests >= sats

          least = least_accepted(sats, tolerance)
          accepted = merchant_accepted && merchant_accepted < least ? merchant_accepted : least
          due = accepted - paid_by_rests
          due.positive? ? due : 1
        end
      end

      # The methods of an order by its amount (SPEC.md §31, "Methods by amount"): Lightning when the
      # amount is within the Lightning address's sendable sats, on-chain from 1 000 sats when an
      # address can be leased. Nothing is repaired: an amount is never split between the two, nor
      # moved into the sendable sats.
      module Methods
        Chosen = Data.define(:lightning, :onchain)

        module_function

        # The methods `sats` may be paid with, before an address is leased. InvalidOrderError
        # (`param`: "sats" or "fiat") below 1 000 sats and outside the sendable sats ([min, max]).
        def of(sats, sendable, param)
          min, max = sendable
          lightning = sats.between?(min, max)
          onchain = sats >= Protocol::ONCHAIN_FLOOR_SATS
          unless lightning || onchain
            raise InvalidOrderError.new(param, "#{sats} sats is outside the merchant's bounds (#{min} to #{max} sats)")
          end

          Chosen.new(lightning: lightning, onchain: onchain)
        end

        # The methods once leasing an address gave `outcome` (:leased, :none, or the explorer's
        # NetworkError): without an address, Lightning only; an order that can only be paid on-chain
        # then fails with OnchainUnavailableError, or the explorer's NetworkError.
        def with(methods, outcome)
          return methods if !methods.onchain || outcome == :leased
          raise(outcome.is_a?(Error) ? outcome : OnchainUnavailableError.new) unless methods.lightning

          Chosen.new(lightning: true, onchain: false)
        end
      end

      # The integration's lot (SPEC.md §31, "The lot"): deposit addresses of the merchant's wallet,
      # which the merchant's app gives the integration and fills again whenever the merchant opens
      # it. One record signed by the team, sealed with the channel's key, at an address the
      # integration key derives. The gem only reads it: it never makes an address, nor writes a lot.
      module Lot
        module_function

        # A lot's value: version 1, `updatedAt` its event's `created_at`, 0 to 100 deposit
        # addresses, none twice. Nil when it is not valid; raises Records::Newer for a newer version.
        def parse(value, created_at)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Records::Newer if Json.number?(version) && version > Protocol::LOT_VERSION
          return nil unless version == Protocol::LOT_VERSION && value["updatedAt"] == created_at

          addresses = value["addresses"]
          return nil unless addresses.is_a?(Array) && addresses.size <= Protocol::MAX_LOT_ADDRESSES

          lot = []
          addresses.each do |address|
            return nil unless Addresses.deposit?(address) && !lot.include?(address)

            lot << address
          end
          lot
        end

        # The addresses of the integration's lot, read on the merchant's `relays` as soon as a
        # majority answered: the newest valid copy. Empty when there is none, or when a copy of a
        # newer format is newer than it (logged: update the gem). The order means nothing.
        # NetworkError when fewer than a majority answered.
        def read(pool, key, relays, random:, logger:, stop:)
          address = Derive.lot_address(key.key)
          encryption_key = Derive.channel_keys(key.key)[1]
          team = key.team_public_key
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [team], "#d" => [address] }
          keep = Records.that_open { |_, author| author == team ? encryption_key : nil }
          # A relay that asks to authenticate (NIP-42) gets a key of this read alone.
          result = pool.query_relays(relays, filter, random.call(32), paged: false, stop: stop, keep: keep)
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          found = Records.newest(result.answers) do |value|
            Records.open(value, type: Protocol::LOT_RECORD_TYPE, encryption_key: encryption_key, address: address,
                                author: team) { |lot, event| parse(lot, event.created_at) }
          end
          if found.newest_unreadable && found.newest_unreadable >= (found.event&.created_at || -1)
            logger.warn("sattleme-checkout: the integration's lot of addresses has a newer format than this " \
                        "version reads; update the gem (no on-chain payment until then)")
            return []
          end

          found.value || []
        end
      end

      # Replacements (SPEC.md §31, "Replacements"): a payer whose transaction is slow to confirm may
      # broadcast another one in its place (RBF), which spends a coin of the same. A replacement
      # keeps the time of the payment it replaces, for at most what that payment paid the address:
      # what it pays more counts at its own time, as any other payment would.
      module Replacements
        # A transaction paying the address, as the parts are made of it: what it pays the address,
        # the coins it spends (or those recorded of it), when it was seen (a witness's `created_at`;
        # nil: unknown, after every known one), whether the explorer lists it now.
        PaymentTx = Data.define(:txid, :sats, :inputs, :order, :listed)

        # A part of a listed transaction: sats it pays as its `root` (itself, for a part of its own).
        Part = Data.define(:sats, :root)

        module_function

        # The parts of each listed transaction, by txid: a txid given twice is taken once (its first
        # entry); the transactions in order (unknown last, then by txid); the roots of each are those
        # before it that spend one of its coins (their roots, put together), else itself; each root
        # gives at most its sats, in that order, then what a transaction still pays is a part of its
        # own.
        def parts(txs)
          unique = {}
          txs.each { |tx| unique[tx.txid] ||= tx }
          sorted = unique.values.sort_by { |tx| [tx.order.nil? ? 1 : 0, tx.order || 0, tx.txid] }
          position = sorted.each_with_index.to_h { |tx, index| [tx.txid, index] }
          roots = {}
          sorted.each_with_index do |tx, index|
            coins = tx.inputs.to_h { |coin| [coin, true] }
            before = sorted.first(index).select { |other| other.inputs.any? { |coin| coins.key?(coin) } }
            roots[tx.txid] = if before.empty?
                               [tx.txid]
                             else
                               before.flat_map { |other| roots[other.txid] }.uniq.sort_by { |root| position[root] }
                             end
          end
          to_give = sorted.to_h { |tx| [tx.txid, tx.sats] }
          result = {}
          sorted.each do |tx|
            next unless tx.listed

            own = roots[tx.txid]
            owed = tx.sats
            list = []
            if own == [tx.txid]
              # A payment of its own: all its sats, which it no longer has to give.
              to_give[tx.txid] = 0
            else
              own.each do |root|
                left = to_give[root]
                take = [owed, left].min
                next unless take.positive?

                list << Part.new(sats: take, root: root)
                to_give[root] = left - take
                owed -= take
              end
            end
            list << Part.new(sats: owed, root: tx.txid) if owed.positive?
            result[tx.txid] = list
          end
          result
        end
      end

      # What the blockchain shows (SPEC.md §31, "Explorers"): one explorer of the Esplora API, the
      # explorer, asked over HTTP; and BlockCypher, for when a transaction was received, asked only
      # about a transaction no check saw while its lease ran. Third parties: they see the server's
      # IP address and what it asks about, never a key. Their answers are checked as strictly as a
      # relay's: anything else is a failure (NetworkError). A payment counts as made on what the
      # explorer read alone shows.
      module Explorer
        # A transaction, as an explorer gives it, checked: the coins it spends (`<txid>:<vout>`,
        # coinbase inputs left out, in their order), its outputs ([sats, address or nil]), the
        # height of its block (nil while it is not confirmed).
        Tx = Data.define(:txid, :coins, :outputs, :block_height) do
          # What it pays `address`: the sum of its outputs to it.
          def pays_to(address)
            outputs.sum { |sats, to| to == address ? sats : 0 }
          end

          # Its confirmations at the chain's `height`: 0 unconfirmed, else height − its block's + 1,
          # 1 at least.
          def confirmations(height)
            block_height.nil? ? 0 : [1, height - block_height + 1].max
          end
        end

        MAX_VOUT = 4_294_967_295
        BLOCKCYPHER_TIME = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?Z\z/
        MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze

        module_function

        def natural?(value)
          Json.safe_integer?(value) && value >= 0
        end

        # An Esplora transaction, checked; nil when it is not one.
        def parse_transaction(value)
          return nil unless value.is_a?(Hash) && Text.hex32?(value["txid"])

          vin, vout, status = value.values_at("vin", "vout", "status")
          return nil unless vin.is_a?(Array) && vout.is_a?(Array) && status.is_a?(Hash)

          coins = []
          vin.each do |input|
            return nil unless input.is_a?(Hash)
            next if input["is_coinbase"] == true

            txid, index = input.values_at("txid", "vout")
            return nil unless Text.hex32?(txid) && natural?(index) && index <= MAX_VOUT

            coins << "#{txid}:#{index.to_i}"
          end
          outputs = []
          vout.each do |output|
            return nil unless output.is_a?(Hash) && natural?(output["value"])

            # A string when it is there (`null` is no string); absent, the output pays no address.
            address = output["scriptpubkey_address"]
            return nil if output.key?("scriptpubkey_address") && !address.is_a?(String)

            outputs << [output["value"].to_i, address]
          end
          # More than every bitcoin there will ever be (SPEC.md §31, Explorers): no transaction,
          # whatever an explorer says.
          return nil if outputs.sum(&:first) > Protocol::MAX_SATS

          confirmed = status["confirmed"]
          return nil unless [true, false].include?(confirmed)

          height = nil
          if confirmed
            return nil unless natural?(status["block_height"])

            height = status["block_height"].to_i
          end
          Tx.new(txid: value["txid"], coins: coins, outputs: outputs, block_height: height)
        end

        # The transactions of `address` on the explorer at `base`: its first answer (a deposit
        # address is paid a few times at most), in the explorer's order.
        def address_transactions(base, address, http)
          url = "#{base}/address/#{address}/txs"
          answer = Http.get_json(url, http)
          raise NetworkError, "#{Urls.host_of(url)} answered HTTP #{answer.status}" unless answer.ok?
          raise NetworkError, "#{Urls.host_of(url)} gave no transactions" unless answer.body.is_a?(Array)

          answer.body.map do |value|
            parse_transaction(value) ||
              raise(NetworkError, "#{Urls.host_of(url)} gave a transaction that is not one")
          end
        end

        # The chain's height on the explorer at `base`: a body of 1 to 9 digits (plain text).
        def chain_height(base, http)
          url = "#{base}/blocks/tip/height"
          answer = Http.get_text(url, http)
          raise NetworkError, "#{Urls.host_of(url)} answered HTTP #{answer.status}" unless answer.ok?
          raise NetworkError, "#{Urls.host_of(url)} gave no height" unless Text.match?(answer.text, /\A[0-9]{1,9}\z/)

          Integer(answer.text, 10)
        end

        # Unix milliseconds of a time as BlockCypher writes it (UTC, a fraction of 1 to 9 digits or
        # none, `Z`), the fraction past milliseconds dropped (never rounded); nil when it is not
        # one, or not a real date and time (no leap second). Another spelling of RFC 3339 is not
        # BlockCypher's.
        def blockcypher_milliseconds(text)
          match = Text.well_formed?(text) && BLOCKCYPHER_TIME.match(text)
          return nil unless match

          year, month, day, hour, minute, second = match.captures.first(6).map { |part| Integer(part, 10) }
          return nil unless month.between?(1, 12) && hour <= 23 && minute <= 59 && second <= 59
          return nil unless day.between?(1, days_in_month(year, month))

          milliseconds = Integer((match[7] || "")[0, 3].ljust(3, "0"), 10)
          seconds = (days_from_civil(year, month, day) * 86_400) + (hour * 3600) + (minute * 60) + second
          (seconds * 1000) + milliseconds
        end

        def days_in_month(year, month)
          leap = (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
          month == 2 && leap ? 29 : MONTH_DAYS[month - 1]
        end

        # Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
        def days_from_civil(year, month, day)
          year -= 1 if month <= 2
          era = year.div(400)
          year_of_era = year - (era * 400)
          day_of_year = (((153 * ((month + 9) % 12)) + 2) / 5) + day - 1
          day_of_era = (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
          (era * 146_097) + day_of_era - 719_468
        end

        # When BlockCypher first received `txid`, in Unix milliseconds (it never changes); nil when
        # it does not know it yet (HTTP 404: it receives it later). Without a token, BlockCypher
        # takes 100 requests an hour from an IP address: it is asked only about a transaction no
        # check saw in time.
        def received_at(txid, http)
          url = "#{Protocol::BLOCKCYPHER_URL}/txs/#{txid}?limit=1&includeHex=false"
          answer = Http.get_json(url, http)
          return nil if answer.status == 404
          raise NetworkError, "#{Urls.host_of(url)} answered HTTP #{answer.status}" unless answer.ok?

          body = answer.body
          unless body.is_a?(Hash) && body["hash"] == txid && body["received"].is_a?(String)
            raise NetworkError, "#{Urls.host_of(url)} gave no time for the transaction"
          end

          time = blockcypher_milliseconds(body["received"])
          raise NetworkError, "#{Urls.host_of(url)} gave no time for the transaction" unless time&.positive?

          time
        end
      end
    end
  end
end
