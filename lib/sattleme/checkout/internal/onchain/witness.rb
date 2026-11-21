# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Witnesses (SPEC.md §31, "Witnesses"): the integration records each transaction it sees
      # paying an address of its lot, and when: during the lease of an order (that order's sale), or
      # at no lease's time (`none`). So that every reader, the merchant's app included, tells the
      # same order paid. Only the integration writes them (signed by its seen secret, sealed with
      # its channel's key); the merchant's app reads them to attribute deposits and to take paid
      # addresses out of the lot.
      module Witnesses
        COIN = /\A[0-9a-f]{64}:(?:0|[1-9][0-9]{0,9})\z/

        # What a witness says: the sale author (hex), or nil (none); what `txid` pays `address`; the
        # coins `txid` spends (its first 100, in their order); whether it holds `txid` for the sale
        # only as a replacement of payments in time; the `expires_at` of the invoice whose lease it
        # came in (or stands for), nil for none.
        Witness = Data.define(:address, :txid, :sale, :sats, :inputs, :replacement, :expires_at)

        # A witness a relay sent, opened: :ok with its witness, or :newer (authentic, of a newer
        # format: what it names cannot be read, its `d` tag can).
        Opened = Data.define(:status, :event, :witness, :d)

        # A witness of the order's sale, as a check uses it: `seen_at` its `created_at`.
        SaleWitness = Data.define(:sats, :inputs, :replacement, :seen_at)

        # The witnesses of an invoice: of this invoice (its sale and its `expires_at`), by txid; of
        # other invoices (another sale, or another `expires_at` of its sale), by txid: what they name
        # counts for nothing here; the txids a witness none names; the witness addresses (`d` tags)
        # of the witnesses of a newer format.
        OfOrder = Data.define(:sale, :others, :none, :newer)

        NONE = OfOrder.new(sale: {}.freeze, others: {}.freeze, none: {}.freeze, newer: {}.freeze)

        module_function

        def mac(key, text)
          Text.hex(Crypto.hmac(key, text.b))
        end

        # Where the witness of `txid` paying `address` for `sale` (a sale author, or nil: none) is.
        def witness_address(address_key, address, txid, sale)
          mac(address_key, "#{address}/#{txid}/#{sale || Protocol::NO_SALE}")
        end

        # The `o` tag of the witnesses of `address` for `sale` (nil: none): how a check reads them.
        def order_tag(address_key, address, sale)
          mac(address_key, "order/#{address}/#{sale || Protocol::NO_SALE}")
        end

        # The address tag of `address`: a witness's second `o` tag, which finds every witness of the
        # address, whatever its sale.
        def address_tag(address_key, address)
          mac(address_key, "address/#{address}")
        end

        # A coin, as a witness writes it: `<txid>:<vout>`, the vout a u32 in decimal without leading
        # zeros.
        def coin?(value)
          Text.match?(value, COIN) && Integer(value[65..], 10) <= Explorer::MAX_VOUT
        end

        # The signed event of a witness, `created_at` when it was seen.
        def event(seen, witness, created_at, random)
          Internal::Records.seal(
            type: Protocol::WITNESS_RECORD_TYPE,
            value: { "version" => Protocol::WITNESS_VERSION, "address" => witness.address, "txid" => witness.txid,
                     "sale" => witness.sale, "sats" => witness.sats,
                     "inputs" => witness.inputs.first(Protocol::MAX_WITNESS_INPUTS),
                     "replacement" => witness.replacement,
                     "expiresAt" => witness.sale.nil? ? nil : witness.expires_at },
            signer: seen.secret_key, encryption_key: seen.encryption_key,
            address: witness_address(seen.address_key, witness.address, witness.txid, witness.sale),
            created_at: created_at, random: random,
            tags: [[Protocol::ORDER_TAG, order_tag(seen.address_key, witness.address, witness.sale)],
                   [Protocol::ORDER_TAG, address_tag(seen.address_key, witness.address)]]
          )
        end

        # A witness's value, checked against its event's tags: its `d` tag is the witness address of
        # what it names, an `o` tag its order tag and an `o` tag its address's tag. Nil when it is not
        # valid; raises Records::Newer for a newer version.
        def parse(value, event, address_key)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Internal::Records::Newer if Json.number?(version) && version > Protocol::WITNESS_VERSION
          return nil unless version == Protocol::WITNESS_VERSION

          address, txid, sale, sats, inputs, replacement = value.values_at("address", "txid", "sale", "sats", "inputs",
                                                                           "replacement")
          # `sale` null for none (absent is neither), else hex32.
          return nil unless value.key?("sale") && (sale.nil? || Text.hex32?(sale))
          return nil unless Addresses.deposit?(address) && Text.hex32?(txid)
          return nil unless Json.safe_integer?(sats) && sats.to_i.between?(1, Protocol::MAX_SATS)
          return nil unless inputs?(inputs)
          return nil unless [true, false].include?(replacement) && !(sale.nil? && replacement)

          # Null for none, the invoice's end for a sale; absent, it is no witness.
          expires_at = value.key?("expiresAt") ? value["expiresAt"] : Order::ABSENT
          return nil unless sale.nil? ? expires_at.nil? : Json.safe_integer?(expires_at)
          return nil unless tagged?(event, address_key, address, txid, sale)

          Witness.new(address: address, txid: txid, sale: sale, sats: sats.to_i, inputs: inputs.dup,
                      replacement: replacement, expires_at: sale.nil? ? nil : expires_at.to_i)
        end

        def inputs?(inputs)
          inputs.is_a?(Array) && inputs.size <= Protocol::MAX_WITNESS_INPUTS && inputs.all? { |coin| coin?(coin) } &&
            inputs.uniq.size == inputs.size
        end

        def tagged?(event, address_key, address, txid, sale)
          d = event.tags.find { |tag| tag[0] == "d" }&.[](1)
          o_tags = event.tags.filter_map { |tag| tag[1] if tag[0] == Protocol::ORDER_TAG }
          d == witness_address(address_key, address, txid, sale) &&
            o_tags.include?(order_tag(address_key, address, sale)) && o_tags.include?(address_tag(address_key, address))
        end

        # What a relay sent, if it is a witness of this integration; nil otherwise.
        def open(value, seen)
          d = Internal::Records.d_tag_of(value)
          return nil if d.nil?

          opened = Internal::Records.open(value, type: Protocol::WITNESS_RECORD_TYPE,
                                                 encryption_key: seen.encryption_key, address: d,
                                                 author: seen.author) do |witness, event|
            parse(witness, event, seen.address_key)
          end
          return nil unless opened
          return Opened.new(status: :newer, event: opened.event, witness: nil, d: d) if opened.newer?

          Opened.new(status: :ok, event: opened.event, witness: opened.value, d: d)
        end

        # The `o` tags of the read of an invoice's witnesses: of the sale, of none, of the address.
        def read_tags(seen, address, sale_author)
          [order_tag(seen.address_key, address, sale_author), order_tag(seen.address_key, address, nil),
           address_tag(seen.address_key, address)]
        end

        # The witnesses of the invoice with the address `address` and the end `expires_at`, for the
        # sale `sale_author`: read on the merchant's `relays` by their order tags (of the sale and of
        # none) and the address tag (every sale's), as soon as a majority answered (or on every
        # relay), with a key of this read alone. NetworkError when fewer than a majority answered.
        def read_of_order(pool, seen, address, sale_author, expires_at, relays, random:, stop:, every_relay: false)
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [seen.author],
                     "#o" => read_tags(seen, address, sale_author) }
          keep = Internal::Records.that_open { |_, author| author == seen.author ? seen.encryption_key : nil }
          result = pool.query_relays(relays, filter, random.call(32),
                                     paged: false, every_relay: every_relay, stop: stop, keep: keep)
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          of_order(result.answers.values.flatten(1), seen, address, sale_author, expires_at)
        end

        # The witnesses of the invoice with the address `address` and the end `expires_at`, for the
        # sale `sale_author`, from what the relays sent to its read: of each witness address, the
        # newest event that opens (one of a newer format, its event checked, is kept as such). A
        # witness that holds none of the read's `o` tags, or whose `address` is not `address`, is of
        # no invoice of this read and is ignored, of a newer format or not.
        def of_order(events, seen, address, sale_author, expires_at)
          tags = read_tags(seen, address, sale_author)
          newest = {}
          checked = {}
          events.each do |value|
            next if value.is_a?(Hash) && value["id"].is_a?(String) && checked.key?(value["id"])

            opened = Witnesses.open(value, seen)
            next unless opened

            checked[opened.event.id] = true
            next unless opened.event.tags.any? { |tag| tag[0] == Protocol::ORDER_TAG && tags.include?(tag[1]) }
            next if opened.status == :ok && opened.witness.address != address

            known = newest[opened.d]
            newest[opened.d] = opened if known.nil? || Internal::Records.replaces?(opened.event, known.event)
          end
          witnesses = OfOrder.new(sale: {}, others: {}, none: {}, newer: {})
          newest.each do |d, opened|
            if opened.status == :newer
              witnesses.newer[d] = true
              next
            end
            witness = opened.witness
            of = SaleWitness.new(sats: witness.sats, inputs: witness.inputs, replacement: witness.replacement,
                                 seen_at: opened.event.created_at)
            if witness.sale.nil?
              witnesses.none[witness.txid] = true
            elsif witness.sale == sale_author && witness.expires_at == expires_at
              witnesses.sale[witness.txid] = of
            else
              witnesses.others[witness.txid] = of
            end
          end
          witnesses
        end

        # The addresses of `by_tag` (an address tag → its address) that `value`, an event a relay
        # sent, names (SPEC.md §31, "Leasing an address", step 3): when it is of the seen author and
        # checks out (`checks_out`: its id and signature, §11), each address whose address tag it
        # holds as an `o` tag, whatever its content (one that does not open as a witness, or of a
        # newer format, names it all the same); none otherwise.
        def names(value, seen, by_tag, checks_out: ->(event) { Events.valid?(event) })
          return [] unless value.is_a?(Hash) && value["pubkey"] == seen.author && value["tags"].is_a?(Array)

          named = value["tags"].filter_map do |tag|
            by_tag[tag[1]] if tag.is_a?(Array) && tag[0] == Protocol::ORDER_TAG && by_tag.key?(tag[1])
          end
          named.empty? || !checks_out.call(value) ? [] : named.uniq
        end

        # The addresses of `addresses` an event of the seen author names (names; SPEC.md §31,
        # "Leasing an address", steps 2 and 3): read on the merchant's `relays` by their address
        # tags, not paged, as soon as a majority answered, with a key of this read alone; of each
        # event, the read keeps only the addresses it names. NetworkError when fewer than a majority
        # answered.
        def read_named_addresses(pool, seen, addresses, relays, random:, stop:)
          return {} if addresses.empty?

          by_tag = addresses.to_h { |address| [address_tag(seen.address_key, address), address] }
          # Whether each event checks out: its id of each copy, its signature once per id and
          # signature, whatever relays send copies.
          signatures = {}
          mutex = Mutex.new
          checks_out = lambda do |value|
            next false unless Events.valid_id?(value)

            copy = "#{value["id"]}/#{value["sig"]}"
            valid = mutex.synchronize { signatures[copy] }
            if valid.nil?
              valid = Events.signature_checks?(value)
              mutex.synchronize { signatures[copy] = valid }
            end
            valid
          end
          keep = lambda do |value|
            named = names(value, seen, by_tag, checks_out: checks_out)
            named.empty? ? nil : named
          end
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [seen.author], "#o" => by_tag.keys }
          result = pool.query_relays(relays, filter, random.call(32), paged: false, keep: keep, stop: stop)
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless result.answered

          result.answers.values.flatten.to_h { |address| [address, true] }
        end

        # Publishes a witness on the merchant's `relays`, signed and authenticated with the seen
        # secret: once a majority took it, else NetworkError.
        def publish(pool, seen, witness, relays, created_at:, random:, stop:)
          event = event(seen, witness, created_at, random)
          pool.publish_to_quorum(relays, event, seen.secret_key, Relay.majority(relays.size), stop: stop)
        rescue Relay::Failure
          raise NetworkError, "Fewer than a majority of the merchant's relays took the witness of a payment"
        end
      end
    end
  end
end
