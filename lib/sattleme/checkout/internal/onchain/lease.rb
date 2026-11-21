# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Leases (SPEC.md §31, "Leases"): an order holds a deposit address of the lot for the time of
      # its invoice with a record in the merchant's registry, signed by the order's sale, at the
      # address's registry address. Outside, what anyone holding the registry key reads (when the
      # lease ends, or its withdrawal); inside, sealed to the merchant's reading key as a
      # declaration's, the order's terms. Like a declaration, a lease stays: a payment of its address
      # in its time is the order's for good.
      module Leases
        # What a lease holds of its order (the lease's JSON, inside): the order's Lightning invoice
        # and its verify URL (nil for an order paid on-chain only), the Invoice's dates, the price as
        # declared, the label, the order's tolerance (0: none, absent from the lease), and whether
        # it is marked confirmed (nil when absent, which is not confirmed either).
        Terms = Data.define(:address, :sats, :invoice, :verify_url, :created_at, :expires_at, :price, :note,
                            :tolerance, :confirmed) do
          def confirmed? = confirmed == true
        end

        # A lease of the sale, opened by the sale (or the merchant): its event, its `d` tag, its
        # terms, and the lease's JSON as it was sealed.
        Opened = Data.define(:event, :d, :terms, :inside)

        # What a read of leases keeps of a record's event, its id checked: what the walk of its
        # address and a lease's confirmation need, and its signature (SPEC.md §13, Limits).
        LeaseEvent = Data.define(:id, :pubkey, :created_at, :sig)

        # A record of the registry at a deposit address's registry address `d`, by any author: its id
        # checked, its signature not yet (SPEC.md §31, "Opening a lease"); `hold` is :withdrawn,
        # :newer, or the lease's `end` (an Integer). #signed? checks the signature once, with the
        # copies other relays sent (#add_copy): a relay's copy with a damaged signature never hides
        # the valid one another relay sent.
        class Record
          attr_reader :event, :d, :hold

          def initialize(event, d, hold)
            @event = event
            @d = d
            @hold = hold
            @signatures = [event.sig]
            @signed = nil
          end

          def signed?
            @signed = @signatures.any? { |sig| signature_checks?(sig) } if @signed.nil?
            @signed
          end

          # The same event (its id is its hash) with another signature: one more to try.
          def add_copy(sig)
            return if @signatures.include?(sig)

            @signatures << sig
            @signed = nil if @signed == false
          end

          # Whether it holds its address at `t`: a lease whose end is at most the clock tolerance
          # before `t` (another server's clock may be behind), or of a newer format.
          def holds?(time)
            hold == :newer || (hold.is_a?(Integer) && hold >= time - Protocol::CLOCK_TOLERANCE_SECONDS)
          end

          private

          def signature_checks?(sig)
            Text.hex64?(sig) && Secp256k1.verify(Text.hex_bytes(sig), Text.hex_bytes(event.id),
                                                 Text.hex_bytes(event.pubkey))
          end
        end

        # The records of the registry at the registry addresses of deposit addresses, by address;
        # whether a majority of the relays answered (else the read is no answer); whether a majority
        # read them completely.
        Read = Data.define(:records, :answered, :complete)

        module_function

        # The lease of `terms.address` for `sale`, signed at `created_at`; it ends at expiresAt + 120.
        # Its tolerance follows `taker` when it is above 0, and is absent otherwise.
        def event(sale:, terms:, created_at:, random:)
          inside = { "version" => Protocol::LEASE_VERSION, "address" => terms.address, "sats" => terms.sats,
                     "invoice" => terms.invoice, "verifyUrl" => terms.verify_url, "createdAt" => terms.created_at,
                     "expiresAt" => terms.expires_at,
                     "sale" => { "key" => Text.hex(sale.key), "fiat" => terms.price, "note" => terms.note },
                     "taker" => sale.taker }
          inside["tolerance"] = terms.tolerance if terms.tolerance.positive?
          inside["confirmed"] = terms.confirmed unless terms.confirmed.nil?
          seal(sale, terms.address, { "version" => Protocol::LEASE_VERSION,
                                      "end" => terms.expires_at + Protocol::GRACE_SECONDS,
                                      "sealed" => Nip44.encrypt(Json.generate(inside), sale.inner_key, random) },
               created_at, random)
        end

        # The withdrawal of `sale`'s lease of `address`, which replaces it (same author and `d` tag):
        # its `created_at` is strictly after the lease's.
        def withdrawal_event(sale:, address:, created_at:, random:)
          seal(sale, address, { "version" => Protocol::LEASE_VERSION, "withdrawn" => true }, created_at, random)
        end

        def seal(sale, address, value, created_at, random)
          d = Addresses.lease_address(sale.registry.key, address)
          Internal::Records.seal(type: Protocol::LEASE_RECORD_TYPE, value: value, signer: sale.secret_key,
                                 encryption_key: Derive.outer_key(sale.registry.key, d, sale.author), address: d,
                                 created_at: created_at, random: random)
        end

        # A record's outside, as anyone holding the registry key reads it: [:lease, end, sealed],
        # [:withdrawn], or nil; raises Records::Newer for a newer version.
        def parse_outside(value)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Internal::Records::Newer if Json.number?(version) && version > Protocol::LEASE_VERSION
          return nil unless version == Protocol::LEASE_VERSION
          return [:withdrawn] if value["withdrawn"] == true

          ending, sealed = value.values_at("end", "sealed")
          return nil unless Json.safe_integer?(ending) && sealed.is_a?(String)

          [:lease, ending.to_i, sealed]
        end

        # What a relay sent, opened as a record of type `registry-onchain` at the registry address
        # `d`, with the outer key of `d` and of the event's own author (SPEC.md §31, "Opening a
        # lease"): its id first; a content of a newer NIP-44 version is no record here (anybody can
        # write one at `d`); its signature is left to leased?, which checks it only where it
        # decides. Nil when it is not one.
        def open_record(value, registry_key, d)
          opened = open_outside(value, registry_key, d)
          return nil unless opened

          event, outside = opened
          Record.new(event, d, outside[0] == :lease ? outside[1] : outside[0])
        end

        # open_record's opening, with the whole outside: [LeaseEvent, outside] ([:newer] for a newer
        # format), or nil.
        def open_outside(value, registry_key, d)
          return nil unless value.is_a?(Hash) && value["kind"] == Protocol::RECORD_KIND && Text.hex32?(value["pubkey"])
          return nil unless Internal::Records.d_tag_of(value) == d

          # The content before the id, the cheap check first (SPEC.md §12): what anybody writes at
          # `d` is dropped before its id is computed, which costs time in its content's size, and
          # escapes cost the most there. Both are checked, in either order: what opens is the same.
          begin
            plaintext = Nip44.decrypt(value["content"], Derive.outer_key(registry_key, d, value["pubkey"]))
          rescue Nip44::Invalid, Nip44::UnknownVersion
            # A content of a newer NIP-44 version included: only the outer key seals a newer lease.
            return nil
          end
          return nil unless Events.valid_id?(value)

          envelope = Json.parse_or(plaintext)
          return nil unless envelope.is_a?(Hash) && envelope.key?("v") && envelope["t"] == Protocol::LEASE_RECORD_TYPE

          outside = begin
            parse_outside(envelope["v"])
          rescue Internal::Records::Newer
            [:newer]
          end
          return nil unless outside

          [LeaseEvent.new(id: value["id"], pubkey: value["pubkey"], created_at: value["created_at"].to_i,
                          sig: value["sig"]), outside]
        end

        # Whether the records of one address lease it at `t` (SPEC.md §31, "Leases"): of each author,
        # its records from the newest (a withdrawal replaces its author's lease): one that holds the
        # address leases it; one that holds nothing ends the author's records, unless an older one
        # of them holds and its signature does not check out. A record that holds is never checked
        # for its signature: only a holder of the registry key seals one, and it may lease. Every
        # author is walked (the vectors count the signatures checked).
        def leased?(records, time)
          leased = false
          records.group_by { |record| record.event.pubkey }.each_value do |list|
            walk = list.sort { |a, b| Internal::Records.replaces?(a.event, b.event) ? -1 : 1 }
            walk.each_with_index do |record, index|
              if record.holds?(time)
                leased = true
                break
              end
              break unless walk[(index + 1)..].any? { |older| older.holds?(time) }
              break if record.signed?
            end
          end
          leased
        end

        # Whether the lease `own` (an event of the sale) is confirmed by `records`, a complete read of
        # its address's records (SPEC.md §31, "Leasing an address", step 3.3): it is among them, no
        # record of another author holds the address at `t`, and `own` is the newest record of its
        # author there.
        def confirmed?(records, own, time)
          return false unless records.any? { |record| record.event.id == own.id }
          return false if leased?(records.reject { |record| record.event.pubkey == own.pubkey }, time)

          records.none? do |record|
            record.event.pubkey == own.pubkey && record.event.id != own.id &&
              Internal::Records.replaces?(record.event, own)
          end
        end

        # The records of the registry at the registry addresses of `addresses`, by address: a complete
        # read on the merchant's `relays`, since LEASE_LOOKBACK before `now` (older leases have
        # ended), with a key of this read alone (leases are signed by sales the integration does not
        # know). Each relay's first copy of an event counts, its signature tried with the other
        # relays' (Record#add_copy).
        def read(pool, registry_key, addresses, relays, now:, random:, stop:, every_relay: false)
          by_d = addresses.to_h { |address| [Addresses.lease_address(registry_key, address), address] }
          found = addresses.to_h { |address| [address, []] }
          return Read.new(records: found, answered: true, complete: true) if addresses.empty?

          # At a lease's address, by any author: the record each event opens to, as it comes.
          keep = lambda do |value|
            d = Internal::Records.d_tag_of(value)
            d && by_d.key?(d) ? open_record(value, registry_key, d) : nil
          end
          filter = { "kinds" => [Protocol::RECORD_KIND], "#d" => by_d.keys,
                     "since" => now - Protocol::LEASE_LOOKBACK_SECONDS }
          result = pool.query_complete(relays, filter, random.call(32), keep: keep, every_relay: every_relay,
                                                                        stop: stop)
          # Ids that checked out: another copy of one is the same event, its signature one more to try.
          checked = {}
          result.answers.each_value do |records|
            # A relay's first copy of each id: at most one signature per relay to try.
            of_relay = {}
            records.each do |record|
              id = record.event.id
              next if of_relay.key?(id)

              of_relay[id] = true
              known = checked[id]
              if known
                known.add_copy(record.event.sig)
                next
              end
              checked[id] = record
              found[by_d[record.d]] << record
            end
          end
          Read.new(records: found, answered: result.answered, complete: result.complete)
        end

        # The inside of a lease's outside (its `sealed`), opened with the sale's inner key (SPEC.md
        # §31, "Opening it as the sale"): [terms, inside], nil when they are not valid (its tolerance
        # read as 0 when it is absent or not one). Raises Records::Newer for a newer version.
        def open_inside(ending, sealed, d, sale)
          inside = begin
            Json.parse_or(Nip44.decrypt(sealed, sale.inner_key))
          rescue Nip44::Invalid, Nip44::UnknownVersion
            nil
          end
          return nil unless inside.is_a?(Hash)

          version = inside["version"]
          raise Internal::Records::Newer if Json.number?(version) && version > Protocol::LEASE_VERSION
          return nil unless version == Protocol::LEASE_VERSION

          terms = terms_of(inside, ending, d, sale)
          terms && [terms, inside]
        end

        def terms_of(inside, ending, d, sale)
          address, sats, invoice, verify_url, created_at, expires_at =
            inside.values_at("address", "sats", "invoice", "verifyUrl", "createdAt", "expiresAt")
          return nil unless Addresses.deposit?(address) && Addresses.lease_address(sale.registry.key, address) == d
          return nil unless Json.safe_integer?(sats) && sats.to_i.between?(1, Protocol::MAX_SATS)
          return nil unless Json.safe_integer?(created_at) && Json.safe_integer?(expires_at) && created_at < expires_at
          return nil unless ending == expires_at + Protocol::GRACE_SECONDS
          return nil unless lightning_valid?(inside, sats.to_i, created_at, expires_at)

          sale_value = inside["sale"]
          return nil unless sale_value.is_a?(Hash) && sale_value["key"] == Text.hex(sale.key)
          return nil unless sale_value["note"].is_a?(String)

          price = Declarations.parse_price(sale_value["fiat"])
          return nil unless price

          Terms.new(address: address, sats: sats.to_i, invoice: invoice, verify_url: verify_url,
                    created_at: created_at.to_i, expires_at: expires_at.to_i, price: price, note: sale_value["note"],
                    # Absent (a lease without tolerance) or invalid: none.
                    tolerance: Tolerance.of(inside["tolerance"]),
                    # Absent, or anything but true: not confirmed.
                    confirmed: inside.key?("confirmed") ? inside["confirmed"] == true : nil)
        end

        # A lease's invoice and verify URL: both null (absent is neither), or a mainnet invoice of
        # exactly `sats`, its timestamp `created_at` and its end `expires_at`, and an https verify
        # URL.
        def lightning_valid?(inside, sats, created_at, expires_at)
          return Json.null_member?(inside, "verifyUrl") if Json.null_member?(inside, "invoice")

          invoice, verify_url = inside.values_at("invoice", "verifyUrl")
          return false unless Text.well_formed?(invoice) && Urls.https_url(verify_url)

          decoded = Bolt11.decode(invoice)
          !decoded.nil? && decoded.network == "bc" && decoded.amount_msat == sats * 1000 &&
            decoded.timestamp == created_at && decoded.expires_at == expires_at
        end

        # What a relay sent, if it is a lease (or a withdrawal) of `sale`: at a registry address (its
        # `d` tag, hex32), signed by the sale, with valid terms inside. A Hash ({kind: :lease, lease:}
        # or {kind: :withdrawn, event:, d:}), nil otherwise; raises Records::Newer for one of a newer
        # format.
        def open_sale_lease(value, sale)
          d = Internal::Records.d_tag_of(value)
          return nil if d.nil? || !value.is_a?(Hash) || value["pubkey"] != sale.author

          key = Derive.outer_key(sale.registry.key, d, sale.author)
          opened = Internal::Records.open(value, type: Protocol::LEASE_RECORD_TYPE, encryption_key: key, address: d,
                                                 author: sale.author) { |outside, _| parse_outside(outside) }
          return nil unless opened
          raise Internal::Records::Newer if opened.newer?

          kind, ending, sealed = opened.value
          return { kind: :withdrawn, event: opened.event, d: d } if kind == :withdrawn

          inside = open_inside(ending, sealed, d, sale)
          inside && { kind: :lease, lease: Opened.new(event: opened.event, d: d, terms: inside[0], inside: inside[1]) }
        end
      end
    end
  end
end
