# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The merchant's acceptance (SPEC.md §31, "The merchant's acceptance"): the merchant may
      # accept by hand, in its app, what an order underpaid on-chain received as paying it in full.
      # The app publishes a record of the team (the integration key opens it but cannot make one)
      # holding what the order had received then; a check judges the payment against that amount
      # when it is less than the least the order's tolerance accepts (Tolerance.due_onchain). The
      # majority of the merchant's relays holds the truth: a check reads it on every relay and
      # counts a record only when a majority of the relays sent it. A check never publishes one,
      # nor publishes one again: the pages of the order's checkout links learn of it only through
      # an acceptance record (Acceptances).
      module MerchantAcceptances
        # What a check opens the merchant's acceptance of an invoice with: the team's public key
        # (hex, its only author), the channel's encryption key (its NIP-44 conversation key) and its
        # `d` tag (Derive.merchant_acceptance_address). Secret but `team` and `address`.
        Keys = Data.define(:team, :encryption_key, :address) do
          include Redacted

          def inspect = "#<MerchantAcceptances::Keys team=#{team} address=#{address}>"
          alias_method :to_s, :inspect
        end

        # The invoice a merchant's acceptance is read for: its amount and its end.
        Terms = Data.define(:sats, :expires_at)

        # A merchant's acceptance a relay sent, opened (MerchantAcceptances.open): :ok, with what
        # the order had received when the merchant accepted it; :newer, of a newer format (logged;
        # the newest a majority sent, it leaves the order without one); :newer_set_aside, of a
        # newer format dated after the lease's end (set aside as any record dated so, logged).
        Opened = Data.define(:status, :event, :received)

        # The merchant's acceptance of an invoice, as a check counts it: the `received` of the one
        # that counts (nil without one), and whether a relay sent one of a newer format, whatever
        # its date and however many relays sent it.
        Acceptance = Data.define(:received, :newer)

        NONE = Acceptance.new(received: nil, newer: false)

        # What a check logs when a relay sent a merchant's acceptance of a newer format.
        NEWER_FORMAT = "sattleme-checkout: a merchant's acceptance of this order has a newer format than this " \
                       "version reads; update the gem"

        module_function

        # The keys of the merchant's acceptance of the invoice of the sale `sale_author` with the
        # deposit address `address` and the end `expires_at`, for the integration `integration_key`
        # of `team`.
        def keys(integration_key, team, sale_author, address, expires_at)
          Keys.new(team: team, encryption_key: Derive.channel_keys(integration_key)[1],
                   address: Derive.merchant_acceptance_address(integration_key, sale_author, address, expires_at))
        end

        # What a relay sent, read as the merchant's acceptance of the invoice of `terms` (SPEC.md
        # §31, "Reading it"): a record of type `integration-onchain-accepted`, author the team,
        # sealed with the channel's key, at the address of `keys`, that checks out (its id, its
        # signature); valid when its value is an object whose `version` is 1 and whose `received`
        # is a safe integer from 1, below the invoice's `sats` (more fields ignored), of a newer
        # format when its `version` is above 1 or its content of a newer NIP-44 version. Nil for
        # anything else, and for a record dated after the lease's end (`expires_at` + 120), which
        # is set aside whatever its format: one of a newer format is still told, for the warning
        # (:newer_set_aside). Its `created_at` is never compared with now.
        def open(value, keys, terms)
          opened = Internal::Records.open(value, type: Protocol::MERCHANT_ACCEPTANCE_RECORD_TYPE,
                                                 encryption_key: keys.encryption_key, address: keys.address,
                                                 author: keys.team) do |record, _|
            parse(record, terms.sats)
          end
          return nil unless opened

          # After the lease's end: set aside, of a newer format or not (SPEC.md §31, "Reading it").
          late = opened.event.created_at > terms.expires_at + Protocol::GRACE_SECONDS
          if opened.newer?
            return Opened.new(status: late ? :newer_set_aside : :newer, event: opened.event, received: nil)
          end

          late ? nil : Opened.new(status: :ok, event: opened.event, received: opened.value)
        end

        # The `received` of a merchant's acceptance's value for an invoice of `sats`, nil when it
        # is not valid; raises Records::Newer for a newer version.
        def parse(record, sats)
          return nil unless record.is_a?(Hash)

          version = record["version"]
          raise Internal::Records::Newer if Json.number?(version) && version > Protocol::MERCHANT_ACCEPTANCE_VERSION
          return nil unless version == Protocol::MERCHANT_ACCEPTANCE_VERSION

          received = record["received"]
          return nil unless Json.safe_integer?(received) && received >= 1

          received.to_i < sats ? received.to_i : nil
        end

        # The merchant's acceptance of the invoice of `terms` (SPEC.md §31, "Counting it"), from
        # what each relay of the merchant's list (`relay_count` relays) sent to its read on every
        # relay (`answers`: relay → values): every copy opened (MerchantAcceptances.open), once per
        # id and signature; a relay sent a record when it sent a copy of it that opens. Of the
        # records valid or of a newer format that a majority of the list sent, the newest (the
        # highest `created_at`, then the lowest id, as relays keep them) decides: a valid one is
        # the merchant's acceptance, one of a newer format leaves the order without one. One that
        # fewer than a majority sent never counts, whichever relays sent it.
        def of(answers, keys, terms, relay_count)
          # Each copy opened once, by id and signature, whatever relays send it.
          copies = {}
          open_copy = lambda do |value|
            fields = Events.fields(value)
            unless fields.is_a?(Hash) && fields["id"].is_a?(String) && fields["sig"].is_a?(String)
              next MerchantAcceptances.open(value, keys, terms)
            end

            copy = "#{fields["id"]}/#{fields["sig"]}"
            copies[copy] = MerchantAcceptances.open(value, keys, terms) unless copies.key?(copy)
            copies[copy]
          end
          # The records that count if enough relays sent them, by id, and how many relays sent each.
          records = {}
          sent_by = Hash.new(0)
          newer = false
          answers.each_value do |values|
            sent = {}
            values.each do |value|
              opened = open_copy.call(value)
              next if opened.nil?

              newer = true unless opened.status == :ok
              next if opened.status == :newer_set_aside

              id = opened.event.id
              # One relay counts once for a record, whatever copies of it it sent.
              next if sent.key?(id)

              sent[id] = true
              records[id] ||= opened
              sent_by[id] += 1
            end
          end
          needed = Relay.majority(relay_count)
          newest = nil
          records.each do |id, opened|
            next if sent_by[id] < needed

            newest = opened if newest.nil? || Internal::Records.replaces?(opened.event, newest.event)
          end
          Acceptance.new(received: newest&.status == :ok ? newest.received : nil, newer: newer)
        end

        # The merchant's acceptance of the invoice of `terms` (MerchantAcceptances.of), read on
        # every relay of the merchant's `relays` (SPEC.md §13: once every relay answered or failed,
        # or one timeout after a majority answered), not paged, with a key of this read alone.
        # NetworkError when fewer than a majority answered. Publishes nothing.
        def read(pool, keys, terms, relays, random:, stop:)
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [keys.team], "#d" => [keys.address] }
          keep = Internal::Records.that_open do |d, author|
            author == keys.team && d == keys.address ? keys.encryption_key : nil
          end
          result = pool.query_relays(relays, filter, random.call(32),
                                     paged: false, every_relay: true, stop: stop, keep: keep)
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          of(result.answers, keys, terms, relays.size)
        end
      end
    end
  end
end
