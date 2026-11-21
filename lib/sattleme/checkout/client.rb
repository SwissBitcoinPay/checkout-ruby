# frozen_string_literal: true

require "securerandom"

module Sattleme
  module Checkout
    # A shop's server for one sattle.me integration (SPEC.md §4): makes the invoice of each order (a
    # Lightning invoice, a deposit address of the merchant's wallet, or both), declares it in the
    # merchant's registry, checks its payment. Made for a server that may live for one call: nothing
    # is kept between calls, each call reads the merchant (a removal stops the next invoice) and
    # closes its connections; there is nothing to close. Thread-safe: share one client between
    # threads.
    #
    #   client = Sattleme::Checkout::Client.new(key: ENV.fetch("SATTLEME_INTEGRATION_KEY"))
    #   invoice = client.create_invoice(ref: "order-1042", fiat: { amount: "24.50", currency: "CHF" })
    #   status = client.get_status(invoice)
    class Client
      include Internal::Redacted

      # The merchant, as the integration's channel gives it: never given to the integrator (its
      # Lightning address, its registry key, its tolerance, its Bitcoin node); and the explorer of
      # the call (Internal::CallExplorer: mempool.space, or the merchant's Bitcoin node with its
      # fallback).
      MerchantChannel = Data.define(:business_name, :lightning_address, :registry, :relays, :checkout_origin,
                                    :tolerance, :bitcoin_node, :explorer) do
        include Internal::Redacted

        def inspect = "#<MerchantChannel>"
        alias_method :to_s, :inspect
      end

      # The last result of each part of an invoice: its Lightning part and its on-chain part
      # (Settled, nil when it has none), its rest part (Payments::RestPart, nil without an address).
      Parts = Data.define(:lightning, :onchain, :rests)

      # A deposit address leased for an order, with its lease's event (its mark).
      Leased = Data.define(:address, :event)

      # What the reads of the explorer of one call share (SPEC.md §31, "in the same call"): when the
      # merchant's Bitcoin node failed (Internal::NodeFailures), and, for wait_for_payment, what
      # hears which node each check's channel names (`on_node.call(node)`, nil: mempool.space).
      ExplorerCall = Data.define(:failures, :on_node)

      # Where warnings go by default: standard error, a line each (written as it is, whatever Ruby's
      # own warnings are set to). Never given a secret.
      class StandardErrorLogger
        def warn(message)
          $stderr.write("#{message}\n")
          nil
        end
      end

      # Builds a client. `key` is the integration's secret key ("Integrations" in the merchant's
      # app), from the environment or a vault: InvalidKeyError unless it is one. The others are
      # optional (SPEC.md §4), each checked here, before any request (InvalidOptionError naming it):
      #
      # - `rate_source:` where invoices priced in a currency get their rate: "coingecko", "mempool",
      #   "opennode", "coinbase", "kraken" (Strings or Symbols), a callable of yours (`currency` →
      #   a decimal String, or `{ price:, time: }`; with two parameters, the call's Cancellation as
      #   the second), or a list of them asked in order. The default list by default.
      # - `coingecko_api_key:` CoinGecko's Demo API key, sent to CoinGecko only.
      # - `relay_timeout_ms:` per relay request, connection included, and `http_timeout_ms:` per HTTP
      #   request, body included: 100 to 60 000, 10 000 by default.
      # - `http_client:` (HttpClient by default), `websocket_client:` (WebSocketClient by
      #   default): for proxies and tests. They get `http://` and `ws://` URLs only for the merchant's
      #   Bitcoin node on a local network (SPEC.md §31): in clear, or a failure, and its fallback.
      # - `logger:` anything with `warn(message)` (a Logger): standard error by default.
      # - `now:` a callable giving the time in Unix seconds, `random:` a callable giving that many
      #   random bytes: for tests only (the system's clock and SecureRandom by default).
      def initialize(key: nil, rate_source: Internal::Order::ABSENT, coingecko_api_key: nil, http_client: nil,
                     websocket_client: nil, relay_timeout_ms: nil, http_timeout_ms: nil, logger: nil, now: nil,
                     random: nil, **unknown)
        unless unknown.empty?
          raise InvalidOptionError.new("options", "unknown option #{unknown.keys.map(&:inspect).join(", ")}")
        end

        @key = Internal::IntegrationKey.parse(key)
        @rate_sources = if rate_source.equal?(Internal::Order::ABSENT)
                          Internal::Rates::DEFAULT_SOURCES
                        else
                          Internal::Rates.source_list(rate_source)
                        end
        raise InvalidOptionError.new("rate_source", Internal::Order::RATE_SOURCE_RULE) unless @rate_sources

        @coingecko_api_key = coingecko_key_of(coingecko_api_key)
        @http_client = object_with(http_client, :get, "http_client", "an object with get(url, headers:, timeout:, " \
                                                                     "cancellation:)") || HttpClient.new
        @relay_timeout_ms = milliseconds(relay_timeout_ms, "relay_timeout_ms")
        @http_timeout_ms = milliseconds(http_timeout_ms, "http_timeout_ms")
        @websocket_client = object_with(websocket_client, :connect, "websocket_client",
                                        "an object with connect(url, timeout:, headers:, cancellation:)") ||
                            WebSocketClient.new
        @logger = object_with(logger, :warn, "logger", "an object with warn(message)") || StandardErrorLogger.new
        @now = object_with(now, :call, "now", "a callable giving Unix seconds") ||
               -> { Process.clock_gettime(Process::CLOCK_REALTIME) }
        @random = object_with(random, :call, "random", "a callable giving that many random bytes") ||
                  SecureRandom.method(:random_bytes)
        # One invoice at a time per order, and one invoice of the rest at a time per invoice, in
        # this process.
        @orders = Internal::KeyedLocks.new
        @rest_asks = Internal::KeyedLocks.new
      end

      # The integration key's public parts: its team and its relays, never the key.
      def to_h
        @key.to_h
      end

      # Its JSON, as ActiveSupport and the json gem ask it of any object: its public parts alone.
      def as_json(*)
        to_h
      end

      def to_json(*)
        Internal::Json.generate(to_h)
      end

      def inspect
        "#<#{self.class.name} team=#{@key.team_public_key}>"
      end
      alias to_s inspect

      # The merchant: its business's name, the bounds of its Lightning address in sats, and how
      # many deposit addresses the integration's lot holds. RevokedError when the merchant removed
      # the integration. Never its Lightning address.
      def merchant(cancellation: nil)
        call(cancellation) do |stop|
          with_relays(stop) do |pool|
            channel = channel(pool, stop)
            branches = stop.child
            begin
              pay = Internal::Future.spawn { Internal::Lnurl.pay_request(channel.lightning_address, http(branches)) }
              lot = lot(pool, channel, stop)
              min, max = pay.value(stop).sendable_sats
              Merchant.new(business_name: channel.business_name, min_sats: min.to_s, max_sats: max.to_s,
                           onchain_addresses: lot.size)
            ensure
              branches.stop
            end
          end
        end
      end

      # The invoice of an order (SPEC.md §17): a Lightning invoice asked to the merchant's Lightning
      # address and checked, when its amount is within the address's bounds; a deposit address of
      # the merchant's wallet leased from the integration's lot, from 1 000 sats (or both). Then the
      # invoice is declared in the merchant's registry on a majority of its relays. Only then may it
      # be shown. Store the result with the order (Invoice#to_json).
      #
      # The order: `ref:` (1 to 64 characters A–Z a–z 0–9 . _ : -: one order, one sale), `sats:` (an
      # Integer or a String of digits) or `fiat:` ({ amount: "24.50", currency: "CHF" }), and
      # optionally `rate_source:` (with `fiat:`), `duration_seconds:` (60 to 3600, 900 by default),
      # `note:` (100 characters at most; the reference by default), `checkout:` (true for a checkout
      # link) and `redirect_url:` (with `checkout: true`).
      #
      # One order, one invoice at a time: InvoicePendingError (with that invoice) while an earlier
      # invoice of the same `ref` may still be paid (or its on-chain payment is being confirmed),
      # OrderPaidError when one was paid. OnchainUnavailableError when the order can only be paid
      # on-chain and no address could be leased; CheckoutUnavailableError when `checkout: true` and
      # the merchant's app gives no web app for it.
      def create_invoice(cancellation: nil, **order)
        checked = Internal::Order.check(order, @rate_sources)
        call(cancellation) do |stop|
          # One at a time per order in this process: two calls for one `ref` would both pass the
          # check of its earlier invoices.
          @orders.synchronize(checked.ref, stop) { make_invoice(checked, stop) }
        end
      end

      # Where the payment of an invoice is (SPEC.md §22), checked: its Lightning part from the
      # merchant's Lightning address (LUD-21), its on-chain part from the explorer and the
      # witnesses of its order, and the Lightning invoices of the rest of an on-chain underpayment,
      # all at once. `invoice`: an Invoice, a DeclaredInvoice, its JSON or the Hash of its JSON.
      # Underpaid on-chain, it asks the merchant's Lightning address for an invoice of the rest,
      # declares it and publishes it for the order's checkout links (a failure is logged, the next
      # check asks again). Never opens the explorer's WebSocket. NetworkError (retry) when a service
      # does not answer, InvalidInvoiceError when an answer is not about this invoice or its
      # preimage is wrong, InvalidOrderError (`invoice`) when it is no invoice of create_invoice.
      def get_status(invoice, cancellation: nil)
        stored = Internal::Order.check_stored_invoice(invoice)
        call(cancellation) do |stop|
          status_of(stored, check(stored, stop, nil, @logger), seconds)
        end
      end

      # Checks the payment until it is `paid` or `expired` (SPEC.md §23): its Lightning part, and the
      # invoices of the rest of an on-chain underpayment, every `interval_ms` (250 to 60 000, 2000 by
      # default); its on-chain part (with an address) each time the explorer's WebSocket says
      # something changed for the address, every 60 s at least, and at once when an invoice of the
      # rest is paid. Each status goes to the block (or `on_status:`). Network errors are retried
      # (one that each check meets again logged once, and again only after it stopped); any other
      # error ends it. An on-chain payment takes about 30 minutes to be `paid` once `unconfirmed`:
      # a server that cannot wait that long checks again later with get_status.
      def wait_for_payment(invoice, interval_ms: nil, on_status: nil, cancellation: nil, &block)
        interval = Internal::Order.check_milliseconds(interval_ms, Internal::Protocol::DEFAULT_INTERVAL_MS,
                                                      Internal::Protocol::MIN_INTERVAL_MS,
                                                      Internal::Protocol::MAX_INTERVAL_MS, "interval_ms")
        listener = listener_of(on_status, block)
        stored = Internal::Order.check_stored_invoice(invoice)
        call(cancellation) do |stop|
          warnings = OnceWarnings.new(@logger)
          if stored.onchain_address
            wait_with_address(stored, interval, listener, warnings, stop)
          else
            wait_lightning(stored, interval, listener, warnings, stop)
          end
        end
      end

      # The invoices declared for the order `ref` in the merchant's registry (SPEC.md §24), oldest
      # first (DeclaredInvoice): to find an order's invoice again after a failure. Publishes
      # nothing: to show an order's invoice again, call create_invoice, whose InvoicePendingError
      # carries the pending invoice.
      def find_invoices(ref, cancellation: nil)
        checked = Internal::Order.check_ref(ref)
        call(cancellation) do |stop|
          with_relays(stop) do |pool|
            channel = channel(pool, stop)
            sale = Internal::Derive.sale(@key.key, channel.registry, checked)
            declared(pool, sale, channel, stop).invoices.map(&:invoice)
          end
        end
      end

      private

      def coingecko_key_of(value)
        return nil if value.nil?

        text = Internal::Text.caller_text(value)
        # Visible ASCII: its HTTP header carries it as it is.
        unless text&.match?(/\A[\x21-\x7e]+\z/)
          raise InvalidOptionError.new("coingecko_api_key",
                                       "1 or more visible ASCII characters")
        end

        text
      end

      def object_with(value, method, name, rule)
        return nil if value.nil?
        raise InvalidOptionError.new(name, rule) unless value.respond_to?(method)

        value
      end

      def milliseconds(value, name)
        Internal::Order.check_milliseconds(value, Internal::Protocol::DEFAULT_TIMEOUT_MS, Internal::Protocol::MIN_TIMEOUT_MS,
                                           Internal::Protocol::MAX_TIMEOUT_MS, name)
      end

      def listener_of(on_status, block)
        raise InvalidOptionError.new("on_status", "a block or on_status:, not both") if on_status && block
        raise InvalidOptionError.new("on_status", "a callable") if on_status && !on_status.respond_to?(:call)

        on_status || block
      end

      # Runs one call: its stop, from the caller's cancellation (Cancellation::NONE when nil).
      def call(cancellation)
        cancellation ||= Cancellation::NONE
        unless cancellation.is_a?(Cancellation)
          raise InvalidOptionError.new("cancellation",
                                       "a Sattleme::Checkout::Cancellation")
        end

        cancellation.raise_if_cancelled
        stop = Internal::Stop.new(cancellation)
        threads = Internal::CallThreads.new
        begin
          result = Internal::CallThreads.within(threads) { yield stop }
        rescue Cancelled
          raise
        rescue StandardError => e
          # Cancelled while a step that does not stop at once ran (a clock, a logger, a listener
          # of the caller's): the call fails with the cancellation all the same, never an error.
          raise Cancelled.new(cancellation.reason), cause: e if cancellation.cancelled?

          raise
        ensure
          # Once it returns, nothing it started runs on (SPEC.md §4, §13): what still runs (a read
          # or a check it no longer needs, after an error) is stopped, then waited for until it
          # ended. A publication's relays past its majority alone go on (Relay::Pool).
          stop.stop
          threads.wait
        end
        # Cancelled before it ended: a cancelled call fails (SPEC.md §4).
        cancellation.raise_if_cancelled
        result
      end

      # Runs the block with the relays of one call: one connection per relay, closed once the call
      # is done (a write still running past the quorum first ends, bounded by its timeout).
      def with_relays(stop)
        pool = Internal::Relay::Pool.new(websocket: @websocket_client, timeout_ms: @relay_timeout_ms, stop: stop,
                                         random: @random, now: -> { seconds })
        begin
          yield pool
        ensure
          pool.release
        end
      end

      def http(stop)
        Internal::Http::Context.new(client: @http_client, timeout_ms: @http_timeout_ms, stop: stop)
      end

      # "Now": the clock in Unix seconds, rounded down.
      def seconds
        time = @now.call
        time.is_a?(Integer) ? time : time.to_f.floor
      end

      # The integration's channel, read on the connections of `pool`, with the explorer of the call:
      # its node's failures those of `call` (an ExplorerCall; a new call's own by default), which
      # hears the node the channel names.
      def channel(pool, stop, logger = @logger, call = nil)
        found = Internal::Channels.read(pool, @key, random: @random, logger: logger, stop: stop).channel
        node = found.bitcoin_node
        call&.on_node&.call(node)
        explorer = Internal::CallExplorer.new(node, call&.failures || Internal::NodeFailures.new, @now)
        MerchantChannel.new(business_name: found.business_name, lightning_address: found.lightning_address,
                            registry: Internal::Derive.registry(found.registry_key, found.registry_reader),
                            relays: Internal::Channels.merchant_relays(found, @key),
                            checkout_origin: found.checkout_origin, tolerance: found.tolerance,
                            bitcoin_node: node, explorer: explorer)
      end

      # The integration's lot of deposit addresses, read on the merchant's relays.
      def lot(pool, merchant, stop)
        Internal::Lot.read(pool, @key, merchant.relays, random: @random, logger: @logger, stop: stop)
      end

      def declared(pool, sale, merchant, stop, every_relay: false, logger: @logger)
        Internal::Sales.read(pool, sale, merchant.relays, logger: logger, stop: stop, every_relay: every_relay)
      end

      # The steps of SPEC.md §17, from the checked order.
      def make_invoice(order, stop)
        with_relays(stop) do |pool|
          merchant = channel(pool, stop)
          raise CheckoutUnavailableError if order.checkout && merchant.checkout_origin.nil?

          sale = Internal::Derive.sale(@key.key, merchant.registry, order.ref)
          pay, sats, rate = pay_request_and_amount(pool, sale, merchant, order, stop)
          make_with(pool, sale, merchant, order, pay, sats, rate, stop)
        end
      end

      # Step 3 and 4: the earlier invoices checked while the pay request and the rate are asked (an
      # error of the earlier invoices' check wins over the other two), then the amount.
      def pay_request_and_amount(pool, sale, merchant, order, stop)
        branches = stop.child
        begin
          context = http(branches)
          pay = Internal::Future.spawn { Internal::Lnurl.pay_request(merchant.lightning_address, context) }
          rates = Internal::Rates::Context.new(http: context, coingecko_api_key: @coingecko_api_key)
          quote = if order.fiat
                    Internal::Future.spawn do
                      Internal::Rates.fetch_first_rate(order.rate_sources, order.fiat.currency, rates, -> { seconds },
                                                       @logger)
                    end
                  end
          check_earlier_invoices(pool, sale, merchant, order, stop)
          pay_request = pay.value(stop)
          return [pay_request, order.sats, nil] unless order.fiat

          price, rate = quote.value(stop)
          sats = Internal::Rates.minor_to_sats(Integer(order.fiat.minor, 10), order.fiat.digits, price)
          if sats > Internal::Protocol::MAX_SATS
            raise InvalidOrderError.new("fiat", "#{sats} sats is more than 21 million bitcoins")
          end

          [pay_request, sats, rate]
        ensure
          branches.stop
        end
      end

      # Steps 4 to 10 of SPEC.md §17, once the amount is known.
      def make_with(pool, sale, merchant, order, pay, sats, rate, stop)
        methods = Internal::Methods.of(sats, pay.sendable_sats, order.fiat ? "fiat" : "sats")
        answer = nil
        decoded = nil
        if methods.lightning
          answer = Internal::Lnurl.request_invoice(pay, sats: sats, expiry_seconds: order.duration_seconds,
                                                        comment: order.label, http: http(stop))
          decoded = Internal::Lnurl.check_invoice(answer, pay: pay, sats: sats,
                                                          duration_seconds: order.duration_seconds, now: seconds)
        end
        leased_at = seconds
        created_at = decoded ? decoded.timestamp : leased_at
        expires_at = decoded ? decoded.expires_at : leased_at + order.duration_seconds
        price = Internal::Declarations.price_of(order.fiat, sats)
        event = (declaration_event(sale, answer, decoded, price, order.label, nil) if answer)

        # The address before the link and the declaration: when the lease fails, nothing is
        # published.
        lease = nil
        if methods.onchain
          terms = Internal::Leases::Terms.new(address: nil, sats: sats, invoice: answer&.pr, verify_url: answer&.verify,
                                              created_at: created_at, expires_at: expires_at, price: price,
                                              note: order.label,
                                              # The order's for good: every check judges its payment with it.
                                              tolerance: merchant.tolerance, confirmed: nil)
          check_lease_size(sale, terms, leased_at)
          # Without an invoice, the lease's date is the Invoice's.
          outcome = lease_address(pool, merchant, sale, terms, decoded ? nil : leased_at, stop)
          Internal::Methods.with(methods, outcome.is_a?(Leased) ? :leased : outcome)
          lease = outcome if outcome.is_a?(Leased)
          if outcome.is_a?(Error)
            @logger.warn("sattleme-checkout: no deposit address leased, the explorer did not answer " \
                         "(#{outcome.message}): Lightning only")
          end
        end
        address = lease&.address

        # On a failure below, the lease stays: it holds its address until its end, and was
        # confirmed: §21 may hand it out. The link before the declaration: when the link fails,
        # nothing is declared and the order gets a new invoice at once; when the declaration fails,
        # the link's URL was never given and its keys are gone, so nobody can open it.
        checkout_url = nil
        if order.checkout
          value = Internal::CheckoutLinks.value(
            business_name: merchant.business_name, invoice: answer&.pr, verify_url: answer&.verify,
            fiat: order.fiat ? price : nil, note: order.label, redirect_url: order.redirect_url,
            onchain: address && link_onchain(merchant, order.ref, address, sats, created_at, expires_at)
          )
          checkout_url = publish_checkout(pool, merchant, value, expires_at, stop)
        end
        declare(pool, event, sale, merchant, stop) if event

        Invoice.new(ref: order.ref, bolt11: answer&.pr, payment_hash: decoded&.payment_hash,
                    verify_url: answer&.verify, onchain_address: address,
                    payment_uri: Internal::Addresses.payment_uri(address, sats, answer&.pr), sats: sats.to_s,
                    fiat: order.fiat, rate: rate, note: order.label, created_at: created_at, expires_at: expires_at,
                    checkout_url: checkout_url, redirect_url: order.checkout ? order.redirect_url : nil)
      end

      # The declaration of an invoice the Lightning address answered, dated `created_at` (now by
      # default); InvalidInvoiceError when it does not fit a NIP-44 plaintext (65 535 bytes).
      def declaration_event(sale, answer, decoded, price, note, rest, created_at = seconds)
        Internal::Declarations.event(sale: sale, invoice: answer.pr, verify_url: answer.verify,
                                     payment_hash: decoded.payment_hash, price: price, note: note,
                                     created_at: created_at, random: @random, rest: rest)
      rescue Internal::Nip44::TooLong
        raise InvalidInvoiceError, "The invoice is too large to be declared"
      end

      # A text of a deposit address's length (`bc1p` and 58 more): a lease's size before its address.
      SIZED_ADDRESS = "bc1p#{"q" * (Internal::Addresses::LENGTH - 4)}".freeze
      private_constant :SIZED_ADDRESS

      # InvalidInvoiceError when the lease of an address cannot hold the order's `terms` (SPEC.md §17,
      # step 6): it holds the invoice too, sealed twice as the declaration, with some 150 bytes more,
      # and must fit a NIP-44 plaintext. Checked before anything is published, on a lease that
      # differs from the real one by its address alone (every deposit address has one length), never
      # published: its random bytes are zeros, the client's are left alone.
      def check_lease_size(sale, terms, created_at)
        Internal::Leases.event(sale: sale, terms: terms.with(address: SIZED_ADDRESS, confirmed: false),
                               created_at: created_at, random: ->(length) { "\x00".b * length })
        nil
      rescue Internal::Nip44::TooLong
        raise InvalidInvoiceError, "The invoice is too large for the lease of an address"
      end

      # Leases a deposit address of the integration's lot for `sale` (SPEC.md §31, "Leasing an
      # address"): the lot and its leases read; of its free addresses, in a random order, at most 3
      # tried, one at a time: one the explorer shows paid already is skipped (its witness none
      # published, so that the merchant's app takes it out of the lot), the explorer read with its
      # fallback (SPEC.md §31: with "none" and the node down, no address); else the lease is published
      # on a majority, the address's leases read again on every relay, and the lease confirmed then
      # marked, or withdrawn when the read is not complete or another author's leases it too (the
      # later of two servers sees both). A lease once confirmed is never withdrawn. `leased_at`: the
      # lease's date when it is the Invoice's (an order paid on-chain only). A Leased, :none, or the
      # explorer's NetworkError; raises NetworkError when the relays fail.
      def lease_address(pool, merchant, sale, terms, leased_at, stop)
        lot = lot(pool, merchant, stop)
        return :none if lot.empty?

        relays = merchant.relays
        # The leases, complete or not (the confirmation decides), and the addresses a witness names.
        leases_future = Internal::Future.spawn do
          Internal::Leases.read(pool, merchant.registry.key, lot, relays, now: seconds, random: @random, stop: stop)
        end
        named_future = Internal::Future.spawn do
          Internal::Witnesses.read_named_addresses(pool, Internal::Derive.seen_keys(@key.key), lot, relays,
                                                   random: @random, stop: stop)
        end
        leases, named = Internal.all([leases_future, named_future], stop)
        raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless leases.answered

        # Its signature checked: a lease of a newer format holds its address (SPEC.md §12).
        if leases.records.each_value.any? { |records| records.any? { |record| newer_lease?(record) } }
          @logger.warn("sattleme-checkout: a lease of the integration's addresses has a newer format than this " \
                       "version reads; update the gem")
        end
        now = seconds
        # Not where the read shows a record of the sale (its signature checked): an earlier call of
        # the order tried it, and a new lease could be of the second of its withdrawal, and either
        # replace the other.
        free = lot.select do |address|
          records = leases.records.fetch(address)
          !named.key?(address) && !Internal::Leases.leased?(records, now) &&
            records.none? { |record| record.event.pubkey == sale.author && record.signed? }
        end
        in_random_order(free).first(Internal::Protocol::MAX_ADDRESS_TRIES).each do |address|
          outcome = try_address(pool, merchant, sale, terms.with(address: address), leased_at, stop)
          return outcome unless outcome == :next
        end
        :none
      end

      # Whether `record`, at a lease's address, is of a newer format, its signature checked.
      def newer_lease?(record)
        record.hold == :newer && record.signed?
      end

      # Steps 3.1 to 3.5 of SPEC.md §31, "Leasing an address", for one free address: a Leased, the
      # explorer's NetworkError, or :next.
      def try_address(pool, merchant, sale, terms, leased_at, stop)
        address = terms.address
        relays = merchant.relays
        begin
          txs = merchant.explorer.read(http(stop)) do |base, context|
            Internal::Explorer.address_transactions(base, address, context)
          end
        rescue NetworkError => e
          return e
        end
        paid = txs.select { |tx| tx.pays_to(address).positive? }
        unless paid.empty?
          # Paid on-chain already: of no order, for good.
          publish_witnesses_of_none(pool, merchant, address, paid, stop)
          return :next
        end
        # Published unconfirmed: it holds the address, never gives the invoice one.
        event = Internal::Leases.event(sale: sale, terms: terms.with(confirmed: false),
                                       created_at: leased_at || seconds, random: @random)
        again = begin
          publish_lease_record(pool, relays, event, sale, stop)
          # On every relay, each until its timeout: a relay that hides a lease cannot hide it while
          # one that holds it answers in time (SPEC.md §13, §27).
          Internal::Leases.read(pool, merchant.registry.key, [address], relays, now: seconds, random: @random,
                                                                                stop: stop, every_relay: true)
        rescue StandardError, Cancelled
          # On some relays only (or the call cancelled): withdrawn, never the order's.
          withdraw(pool, relays, sale, address, event, stop)
          raise
        end
        records = again.records.fetch(address)
        own = Internal::Leases::LeaseEvent.new(id: event.id, pubkey: event.pubkey, created_at: event.created_at,
                                               sig: event.sig)
        confirmed = again.answered && again.complete && Internal::Leases.confirmed?(records, own, seconds)
        unless confirmed
          # Another server leased it at once (the later reader sees both), the read could not be
          # complete, or fewer than a majority answered: withdrawn (safe on some relays only: the
          # address was never the order's), unless the read shows another record of the sale there
          # whose signature checks out, even from fewer than a majority: another call of the order
          # made it at once (its lock failed, SPEC.md §17), and it is not this call's to end.
          another = records.any? do |record|
            record.event.pubkey == sale.author && record.event.id != event.id && record.signed?
          end
          withdraw(pool, relays, sale, address, event, stop) unless another
          raise NetworkError, "Fewer than a majority of the merchant's relays answered" unless again.answered

          return :next
        end
        # Confirmed: never withdrawn from now on, whatever fails (a withdrawal on some relays only
        # would leave them disagreeing on an address that may be the order's). Marked confirmed:
        # from now on the address is the order's, its invoice's in §21 too.
        marked = Internal::Leases.event(sale: sale, terms: terms.with(confirmed: true),
                                        created_at: [seconds, event.created_at + 1].max, random: @random)
        publish_lease_record(pool, relays, marked, sale, stop)
        Leased.new(address: address, event: marked)
      end

      # Withdraws `lease`, the lease of `address` by `sale` that was not confirmed: its withdrawal, a
      # second after it (so that it replaces the lease, and no later record of the sale), published
      # on the merchant's `relays`; a failure only logged (the lease then holds its address until
      # its end, and never gives its invoice one).
      def withdraw(pool, relays, sale, address, lease, stop)
        return if stop.cancelled?

        event = Internal::Leases.withdrawal_event(sale: sale, address: address, created_at: lease.created_at + 1,
                                                  random: @random)
        pool.publish_to_quorum(relays, event, sale.secret_key, Internal::Relay.majority(relays.size), stop: stop)
      rescue Internal::Relay::Failure, Cancelled
        return if stop.cancelled?

        @logger.warn("sattleme-checkout: a lease that was not confirmed could not be withdrawn; it holds its " \
                     "deposit address until its end")
      end

      # Publishes a lease record on a majority of the merchant's `relays`, else NetworkError.
      def publish_lease_record(pool, relays, event, sale, stop)
        pool.publish_to_quorum(relays, event, sale.secret_key, Internal::Relay.majority(relays.size), stop: stop)
      rescue Internal::Relay::Failure
        raise NetworkError,
              "Fewer than a majority of the merchant's relays took the lease of a deposit address: try again"
      end

      # Publishes a witness none of each transaction of `txs` paying `address`, failures logged.
      def publish_witnesses_of_none(pool, merchant, address, txs, stop)
        seen = Internal::Derive.seen_keys(@key.key)
        futures = txs.map do |tx|
          witness = Internal::Witnesses::Witness.new(
            address: address, txid: tx.txid, sale: nil, sats: tx.pays_to(address),
            inputs: tx.coins.first(Internal::Protocol::MAX_WITNESS_INPUTS), replacement: false, expires_at: nil
          )
          Internal::Future.spawn("sattleme-checkout witness") do
            Internal::Witnesses.publish(pool, seen, witness, merchant.relays, created_at: seconds, random: @random,
                                                                              stop: stop)
          rescue NetworkError => e
            @logger.warn("sattleme-checkout: the witness of a paid address was not published: #{e.message}")
          end
        end
        Internal.all(futures, stop)
      end

      # Publishes a new checkout link holding `value` on a majority of the merchant's relays, and
      # gives its URL. The author's secret answers the relays' authentication, then is dropped with
      # the link: nobody can change it afterwards. NetworkError when fewer than a majority took it.
      def publish_checkout(pool, merchant, value, expires_at, stop)
        link = begin
          Internal::CheckoutLinks.new_link(origin: merchant.checkout_origin, relays: merchant.relays, value: value,
                                           expires_at: expires_at, created_at: seconds, random: @random)
        rescue Internal::Nip44::TooLong
          raise InvalidInvoiceError, "The invoice is too large for a checkout link"
        end
        begin
          pool.publish_to_quorum(merchant.relays, link.event, link.secret_key,
                                 Internal::Relay.majority(merchant.relays.size), stop: stop)
        rescue Internal::Relay::Failure
          raise NetworkError, "Fewer than a majority of the merchant's relays took the checkout link: try again"
        end
        link.url
      end

      # Publishes a declaration on a majority of the merchant's relays, else NetworkError.
      def declare(pool, event, sale, merchant, stop)
        pool.publish_to_quorum(merchant.relays, event, sale.secret_key, Internal::Relay.majority(merchant.relays.size),
                               stop: stop)
      rescue Internal::Relay::Failure
        raise NetworkError, "Fewer than a majority of the merchant's relays took the invoice's declaration: do not " \
                            "show this invoice, try again"
      end

      # Publishes a lease again on a majority of the merchant's relays, else NetworkError.
      def publish_lease(pool, event, sale, merchant, stop)
        pool.publish_to_quorum(merchant.relays, event, sale.secret_key, Internal::Relay.majority(merchant.relays.size),
                               stop: stop)
      rescue Internal::Relay::Failure
        raise NetworkError, "Fewer than a majority of the merchant's relays took the invoice's lease: do not show " \
                            "this invoice, try again"
      end

      # Refuses a new invoice for the sale while an earlier one may still be paid (until its end
      # plus 120 s, or while its on-chain payment is being confirmed or undecided), or when one was
      # paid (SPEC.md §21): read in the registry, so that it holds even when the shop lost what it
      # stored.
      def check_earlier_invoices(pool, sale, merchant, order, stop)
        records = declared(pool, sale, merchant, stop)
        earlier = records.invoices
        may_be_paid = Internal::Sales.may_still_be_paid(earlier.map(&:invoice), seconds).map { |index| earlier[index] }
        unless may_be_paid.empty?
          hand_out_pending(pool, sale, merchant, order, records, may_be_paid, stop)
          return
        end
        statuses = check_each(pool, merchant, records, earlier, stop)
        statuses.each_with_index do |status, index|
          raise OrderPaidError.new(earlier[index].invoice, status.value) if status.ok? && status.value.paid?
        end
        # An on-chain payment being confirmed, or a transaction undecided: its time to be paid is
        # over, nothing is published again, and no new link (the shop keeps the one it got, whose
        # page goes on following the payment).
        pending = statuses.index { |status| status.ok? && (status.value.unconfirmed? || status.value.open?) }
        raise InvoicePendingError.new(earlier[pending].invoice, nil) if pending

        failed = statuses.find { |status| !status.ok? }
        raise failed.error if failed
      end

      # Step 1 of SPEC.md §21: the invoices that may still be paid, their payments checked (even of
      # one alone: an invoice already paid is never handed out again), and of several, the sale's
      # records read on every relay at the same time: the one shown is the one a majority holds.
      # Raises OrderPaidError, an error of a check, NetworkError, or InvoicePendingError.
      def hand_out_pending(pool, sale, merchant, order, records, may_be_paid, stop)
        everywhere = if may_be_paid.size > 1
                       Internal.settled { declared(pool, sale, merchant, stop, every_relay: true) }
                     end
        statuses = check_each(pool, merchant, records, may_be_paid, stop)
        everywhere = everywhere&.value(stop)
        held = (Internal::Sales.held(may_be_paid, everywhere.value.sent_by, merchant.relays.size) if everywhere&.ok?)
        kind, index = Internal::Sales.pending_outcome(statuses, held)
        raise OrderPaidError.new(may_be_paid[index].invoice, statuses[index].value) if kind == :paid
        raise statuses[index].error if kind == :failed

        # Fewer than a majority answered the read again: after a payment and an error.
        if kind == :unread
          raise everywhere.error if everywhere && !everywhere.ok?

          raise NetworkError, "Fewer than a majority of the merchant's relays answered"
        end

        open = may_be_paid[index]
        # Its create_invoice may have failed with fewer than a majority of the relays holding its
        # declaration or its lease ("do not show this invoice"): published again before it is
        # handed out. Its lease, with an address, was confirmed: the address is the order's.
        declare(pool, open.event, sale, merchant, stop) if open.event
        publish_lease(pool, open.lease, sale, merchant, stop) if open.lease
        invoice = open.invoice
        # A new link to it, for a shop that lost the one it stored (or never got it): links only show
        # the invoice, several of them change nothing.
        checkout_url = nil
        if order.checkout
          link = pending_link_value(invoice, merchant, order)
          checkout_url = publish_checkout(pool, merchant, link, invoice.expires_at, stop)
        end
        raise InvoicePendingError.new(invoice, checkout_url)
      end

      # A checkout link's record of a DeclaredInvoice, with this order's redirect URL.
      def pending_link_value(invoice, merchant, order)
        fiat = invoice.fiat
        price = fiat && Internal::Declarations.price(minor: Integer(fiat.minor, 10), digits: fiat.digits,
                                                     currency: fiat.currency)
        address = invoice.onchain_address
        Internal::CheckoutLinks.value(
          business_name: merchant.business_name, invoice: invoice.bolt11, verify_url: invoice.verify_url,
          fiat: price, note: invoice.note, redirect_url: order.redirect_url,
          onchain: address && link_onchain(merchant, order.ref, address, Integer(invoice.sats, 10),
                                           invoice.created_at, invoice.expires_at)
        )
      end

      # What a checkout link's record holds of the address of the order `ref` (version 2): its
      # amount and dates, its rest keys, and the node its page reads (the channel's, with `payers`
      # true: SPEC.md §30).
      def link_onchain(merchant, ref, address, sats, created_at, expires_at)
        Internal::CheckoutLinks::Onchain.new(
          address: address, sats: sats, created_at: created_at, expires_at: expires_at,
          rest: Internal::Derive.rest_keys(@key.key, ref, address, expires_at),
          bitcoin_node: Internal::BitcoinNodes.record_node_for(merchant.bitcoin_node)
        )
      end

      # The payment check of each of `invoices` (Sales::Declared), MAX_PARALLEL_PAYMENT_CHECKS at a
      # time: their Settled statuses, in order. A paid invoice wins over a service that did not answer
      # about another one.
      def check_each(pool, merchant, records, invoices, stop)
        outcomes = Internal.settle_each(invoices, Internal::Protocol::MAX_PARALLEL_PAYMENT_CHECKS, stop) do |declared|
          stored = stored_of(declared.invoice)
          status_of(stored, check(stored, stop, [pool, merchant, records], @logger), seconds)
        end
        outcomes.map do |state, result|
          raise result if result.is_a?(Cancelled) || result.is_a?(Internal::Stopped)

          state == :ok ? Internal::Settled.ok(result) : Internal::Settled.failed(result)
        end
      end

      # What a payment check asks of a declared invoice.
      def stored_of(invoice)
        lightning = unless invoice.bolt11.nil?
                      Internal::Lnurl::LightningInvoice.new(bolt11: invoice.bolt11, payment_hash: invoice.payment_hash,
                                                            verify_url: invoice.verify_url,
                                                            expires_at: invoice.expires_at)
                    end
        Internal::Order::Stored.new(ref: invoice.ref, lightning: lightning, onchain_address: invoice.onchain_address,
                                    sats: Integer(invoice.sats, 10), expires_at: invoice.expires_at)
      end

      # The status of `stored` from its parts, at `now`; raises a part's error.
      def status_of(stored, parts, now)
        terms = Internal::Payments::Terms.new(sats: stored.sats, expires_at: stored.expires_at,
                                              address: stored.onchain_address)
        Internal::Payments.combine(terms, now, parts.lightning, parts.onchain, parts.rests)
      end

      # Every part of `stored` checked at once (SPEC.md §31, "The on-chain payment"): its Lightning
      # part, and with an address its on-chain part and its rest part, read on the merchant's relays
      # (over `scope`, [pool, merchant, records], when given; else over the connections of a call of
      # its own, whose channel's explorer shares the node's failures of `call`, an ExplorerCall); an
      # invoice of the rest asked when the status calls for one. A part that fails is its error,
      # never raised; a cancellation is.
      def check(stored, stop, scope, logger, call = nil)
        lightning = if stored.lightning
                      Internal.settled { Internal::Lnurl.verify_payment(stored.lightning, http(stop), seconds) }
                    end
        return Parts.new(lightning: lightning&.value(stop), onchain: nil, rests: nil) unless stored.onchain_address

        begin
          if scope
            pool, merchant, records = scope
            address_parts(stored, pool, merchant, records, lightning, stop, logger)
          else
            with_relays(stop) do |pool|
              address_parts(stored, pool, channel(pool, stop, logger, call), nil, lightning, stop, logger)
            end
          end
        rescue Cancelled, Internal::Stopped
          raise
        rescue StandardError => e
          # The relays or the channel failed: the address's parts cannot be told.
          Parts.new(lightning: lightning&.value(stop), onchain: Internal::Settled.failed(e), rests: nil)
        end
      end

      # What the checks of the parts of one invoice with an address work with: the stored invoice,
      # the call's relays (its pool) and channel (the merchant), the order's sale, the call's stop,
      # where warnings go.
      AddressCheck = Data.define(:stored, :pool, :merchant, :sale, :stop, :logger)
      private_constant :AddressCheck

      # The on-chain part and the rest part of `stored` (it has an address and a reference), at
      # once: the sale's records (its rest invoices, its lease) read while the explorer is asked;
      # then with_rest. `records`: the sale's records when the call read them already.
      def address_parts(stored, pool, merchant, records, lightning_check, stop, logger)
        sale = Internal::Derive.sale(@key.key, merchant.registry, stored.ref)
        scope = AddressCheck.new(stored: stored, pool: pool, merchant: merchant, sale: sale, stop: stop, logger: logger)
        read = if records
                 Internal::Future.resolved(records)
               else
                 Internal::Future.spawn { declared(pool, sale, merchant, stop, logger: logger) }
               end
        rest_check = Internal.settled { rest_part(scope, read.value(stop)) }
        tolerance = -> { tolerance_of(scope, read) }
        # A rest invoice that failed counts as not paid: the on-chain part then needs more.
        paid_by_rests = lambda do
          rest = rest_check.value(stop)
          rest.ok? ? Internal::Payments.rest_summary(rest.value).paid : 0
        end
        onchain_check = Internal.settled { check_onchain(scope, paid_by_rests, tolerance) }
        lightning = lightning_check&.value(stop)
        onchain = onchain_check.value(stop)
        rest_result = rest_check.value(stop)
        unless rest_result.ok?
          # The sale's records unread: whether a rest invoice was paid cannot be told.
          return Parts.new(lightning: lightning, onchain: onchain,
                           rests: Internal::Payments::RestPart.failed(rest_result.error))
        end

        parts = Parts.new(lightning: lightning, onchain: onchain, rests: rest_result.value)
        parts = with_rest(scope, read.value(stop), parts, tolerance)
        publish_acceptance(scope, parts)
        parts
      end

      # The rest part of the invoice of `scope`, from the sale's records `found`: its rest invoices,
      # each checked as a Lightning part. One whose declaration fewer than a majority of the relays
      # sent (its publication failed) is published again on a majority first: else the rest part
      # fails (network).
      def rest_part(scope, found)
        stored = scope.stored
        context = http(scope.stop)
        # This invoice's own: another invoice of the order may have leased the address before.
        invoices = found.rests.fetch(Internal::Sales.rest_key_of(stored.onchain_address, stored.expires_at), [])
        invoices.each do |invoice|
          event = found.unsure_rests[invoice.payment_hash]
          declare(scope.pool, event, scope.sale, scope.merchant, scope.stop) if event
        end
        checks = invoices.map do |invoice|
          Internal.settled { Internal::Lnurl.verify_payment(invoice.lightning, context, seconds) }
        end
        Internal::Payments::RestPart.of(invoices, Internal.all(checks, scope.stop))
      end

      # The order's tolerance, its lease's (the invoice's own terms), once the sale's records `read`
      # are: without them, or with another lease of the address, none.
      def tolerance_of(scope, read)
        stored = scope.stored
        terms = read.value(scope.stop).leases[stored.onchain_address]&.terms
        terms && terms.sats == stored.sats && terms.expires_at == stored.expires_at ? terms.tolerance : 0
      rescue Cancelled, Internal::Stopped
        raise
      rescue StandardError
        0
      end

      # The parts of the invoice of `scope` once each answered (`found`: the sale's records): when
      # the status is open with a rest and no invoice of it, one asked (ask_rest; one another check
      # asked and that is paid already has the on-chain part checked again); then, before the end of
      # the grace period, the records of its rest invoices published again where fewer than a
      # majority hold them.
      def with_rest(scope, found, parts, tolerance)
        stored = scope.stored
        rests = parts.rests
        onchain = parts.onchain
        lease = found.leases[stored.onchain_address]&.terms
        # The rest invoices whose rest record a majority took in this check.
        recorded = {}
        asked = ask_rest(scope, parts, lease) if lease && rest_wanted?(stored, parts, lease)
        if asked
          invoice, result, taken = asked
          recorded[invoice.payment_hash] = true if taken
          rests = Internal::Payments::RestPart.of(rests.invoices + [invoice], rests.results + [result])
          # Asked meanwhile by another check and paid already: less is due on-chain.
          if result.ok? && result.value.paid?
            paid = Internal::Payments.rest_summary(rests).paid
            onchain = Internal.settled { check_onchain(scope, -> { paid }, tolerance) }.value(scope.stop)
          end
        end
        now = seconds
        if !rests.invoices.empty? && now < stored.expires_at + Internal::Protocol::GRACE_SECONDS
          rests = rests.with(unrecorded: publish_missing_rests(scope, rests.invoices, recorded, now))
        end
        Parts.new(lightning: parts.lightning, onchain: onchain, rests: rests)
      end

      # The status of `parts` at `now`, nil when a part failed (the status is its error).
      def status_or_nil(stored, parts, now)
        status_of(stored, parts, now)
      rescue Cancelled, Internal::Stopped
        raise
      rescue StandardError
        nil
      end

      # Whether an invoice of the rest of `parts` would be asked now, with the sale's `lease` of the
      # address (Rests.to_ask): worth the order's critical section, where ask_rest decides again.
      def rest_wanted?(stored, parts, lease)
        now = seconds
        status = status_or_nil(stored, parts, now)
        return false unless status&.open?

        ask = Internal::Rests.to_ask(rest: status.rest, sats: stored.sats, expires_at: stored.expires_at, now: now,
                                     lease: lease)
        !ask.nil?
      end

      # The on-chain part of the invoice of `scope`, with what its rest invoices paid and the order's
      # tolerance as they come (callables), and the merchant's acceptance of the invoice (the
      # team's record, read on every relay).
      def check_onchain(scope, paid_by_rests, tolerance)
        stored = scope.stored
        address = stored.onchain_address
        author = scope.sale.author
        relays = scope.merchant.relays
        seen = Internal::Derive.seen_keys(@key.key)
        accepted = Internal::MerchantAcceptances.keys(@key.key, @key.team_public_key, author, address,
                                                      stored.expires_at)
        terms = Internal::MerchantAcceptances::Terms.new(sats: stored.sats, expires_at: stored.expires_at)
        check = Internal::Payments::Check.new(
          address: address, sats: stored.sats, expires_at: stored.expires_at, sale: author,
          # Read once the explorer answered.
          clock: -> { seconds }, http: http(scope.stop), explorer: scope.merchant.explorer,
          read_witnesses: lambda do |every_relay|
            Internal::Witnesses.read_of_order(scope.pool, seen, address, author, stored.expires_at, relays,
                                              random: @random, stop: scope.stop, every_relay: every_relay)
          end,
          witness_address: ->(txid, of) { Internal::Witnesses.witness_address(seen.address_key, address, txid, of) },
          publish: lambda do |witness|
            Internal::Witnesses.publish(scope.pool, seen, witness, relays,
                                        created_at: seconds, random: @random, stop: scope.stop)
          end,
          logger: scope.logger, paid_by_rests: paid_by_rests, tolerance: tolerance,
          read_merchant_acceptance: lambda do
            Internal::MerchantAcceptances.read(scope.pool, accepted, terms, relays, random: @random, stop: scope.stop)
          end
        )
        Internal::Payments.check_onchain(check, scope.stop)
      end

      # When the order's tolerance or the merchant's acceptance accepted less than its amount (the
      # status `parts` give is being confirmed, or paid on-chain), has the pages of its checkout
      # links know it (SPEC.md §31, "Acceptance records"): unless a majority of the merchant's relays
      # hold what it received, or less, publishes an acceptance record of it. A failure is logged,
      # never the check's: the next check publishes it again. Never the tolerance itself.
      def publish_acceptance(scope, parts)
        stored = scope.stored
        now = seconds
        # A part failed: nothing is accepted.
        status = status_or_nil(stored, parts, now)
        return if status.nil?

        keys = -> { Internal::Derive.rest_keys(@key.key, stored.ref, stored.onchain_address, stored.expires_at) }
        Internal::Acceptances.publish(scope.pool, status, sats: stored.sats, expires_at: stored.expires_at, now: now,
                                                          keys: keys, relays: scope.merchant.relays,
                                                          clock: -> { seconds }, random: @random,
                                                          logger: scope.logger, stop: scope.stop)
      rescue NetworkError => e
        scope.logger.warn("sattleme-checkout: the acceptance record of a payment was not published (#{e.message}); " \
                          "published again at the next check")
      end

      # Asks the merchant's Lightning address for an invoice of the rest of the invoice of `scope`,
      # declares it with `rest` (the price and note of the sale's `lease` of the address) on a
      # majority of the merchant's relays, then publishes its rest record (SPEC.md §31, "Asking for
      # a rest invoice"). One at a time per invoice in this process, each deciding (ask_rest_now)
      # inside that critical section; another check's invoice of the same rest, declared meanwhile,
      # is taken instead. [invoice, result (Settled), whether a majority took its rest record], or
      # nil when none is asked or none could be made: outside the address's sendable sats, or a
      # failure, logged as a warning (the next check asks again).
      def ask_rest(scope, parts, lease)
        @rest_asks.synchronize("#{scope.sale.ref}/#{scope.stored.onchain_address}", scope.stop) do
          scope.stop.check!
          ask_rest_now(scope, parts, lease)
        rescue Error => e
          scope.logger.warn("sattleme-checkout: no Lightning invoice of the rest of an underpayment (#{e.message}); " \
                            "asked again at the next check")
          nil
        end
      end

      # ask_rest's steps, in the critical section: the rest invoices read again, then the clock,
      # which the decision to ask, the invoice's expiry, its checks and its records all use.
      def ask_rest_now(scope, parts, lease)
        stored = scope.stored
        # Another check may have asked for it meanwhile.
        again = declared(scope.pool, scope.sale, scope.merchant, scope.stop)
        now = seconds
        status = status_or_nil(stored, parts, now)
        ask = if status&.open?
                Internal::Rests.to_ask(rest: status.rest, sats: stored.sats, expires_at: stored.expires_at, now: now,
                                       lease: lease)
              end
        return nil unless ask

        taken_meanwhile(scope, again, parts.rests.invoices, ask, now) || new_rest(scope, ask, lease, now)
      end

      # A rest invoice of exactly `ask`'s sats that another check declared meanwhile (`again`: the
      # sale's records read again; `known`: the rest invoices this check read) and not ended at
      # `now`, checked as any rest invoice (it may have been paid already): [invoice, result, false],
      # else nil.
      def taken_meanwhile(scope, again, known, ask, now)
        stored = scope.stored
        before = known.to_h { |invoice| [invoice.payment_hash, true] }
        candidates = again.rests.fetch(Internal::Sales.rest_key_of(stored.onchain_address, stored.expires_at), [])
        meanwhile = candidates.find do |invoice|
          !before.key?(invoice.payment_hash) && invoice.sats == ask.sats && now < invoice.expires_at
        end
        return nil unless meanwhile

        # On a majority, as any rest invoice found.
        event = again.unsure_rests[meanwhile.payment_hash]
        declare(scope.pool, event, scope.sale, scope.merchant, scope.stop) if event
        context = http(scope.stop)
        result = Internal.settled { Internal::Lnurl.verify_payment(meanwhile.lightning, context, now) }
        [meanwhile, result.value(scope.stop), false]
      end

      # A new invoice of the rest `ask` gives, asked at `now` of the merchant's Lightning address (nil
      # outside its sendable sats), checked, declared with the price and note of the sale's `lease`
      # (dated `now`), its rest record published (dated `now`): [invoice, result, whether a majority
      # took its rest record].
      def new_rest(scope, ask, lease, now)
        stored = scope.stored
        context = http(scope.stop)
        pay = Internal::Lnurl.pay_request(scope.merchant.lightning_address, context)
        return nil unless Internal::Rests.sendable?(ask.sats, pay.sendable_sats)

        expiry = ask.expiry_seconds
        answer = Internal::Lnurl.request_invoice(pay, sats: ask.sats, expiry_seconds: expiry, comment: lease.note,
                                                      http: context)
        decoded = Internal::Lnurl.check_invoice(answer, pay: pay, sats: ask.sats, duration_seconds: expiry, now: now)
        rest_of = Internal::Declarations::RestOf.new(address: stored.onchain_address, expires_at: stored.expires_at)
        event = declaration_event(scope.sale, answer, decoded, lease.price, lease.note, rest_of, now)
        declare(scope.pool, event, scope.sale, scope.merchant, scope.stop)
        invoice = Internal::Rests::Invoice.new(bolt11: answer.pr, payment_hash: decoded.payment_hash,
                                               verify_url: answer.verify, sats: ask.sats, created_at: decoded.timestamp,
                                               expires_at: decoded.expires_at)
        # Declared: it may be shown. Its record, for the checkout links' pages.
        [invoice, Internal::Settled.ok(Internal::Lnurl::Part.open), publish_rest(scope, invoice, now)]
      end

      # Publishes the rest record of `invoice`, dated `created_at`, on a majority: whether a majority
      # took it (a failure only logged).
      def publish_rest(scope, invoice, created_at)
        stored = scope.stored
        keys = Internal::Derive.rest_keys(@key.key, stored.ref, stored.onchain_address, stored.expires_at)
        event = Internal::Rests.record_event(keys: keys, invoice: invoice, expires_at: stored.expires_at,
                                             created_at: created_at, random: @random)
        Internal::Rests.publish_record(scope.pool, event, keys, scope.merchant.relays, stop: scope.stop)
        true
      rescue NetworkError => e
        scope.logger.warn("sattleme-checkout: the record of an invoice of the rest was not published (#{e.message}); " \
                          "published again at the next check")
        false
      end

      # Publishes again, dated `now`, the rest records of `invoices` that fewer than a majority of the
      # relays sent (their first publication may have failed), so that the checkout links' pages see
      # each of them; never over a record of a newer format at its address (logged: update the gem),
      # which holds it. Gives the payment hashes of those still not known on a majority: neither sent
      # by a majority, held by a newer record, nor taken by one in this check (`recorded`, or
      # published again here); when fewer than a majority answered, all of them but `recorded`.
      # Those are never the status's `bolt11`: the next check tries again.
      def publish_missing_rests(scope, invoices, recorded, now)
        stored = scope.stored
        keys = Internal::Derive.rest_keys(@key.key, stored.ref, stored.onchain_address, stored.expires_at)
        terms = Internal::Rests::LinkTerms.new(sats: stored.sats, created_at: -Internal::Json::MAX_SAFE_INTEGER,
                                               expires_at: stored.expires_at)
        read = Internal::Rests.read_records(scope.pool, keys, terms, scope.merchant.relays,
                                            random: @random, stop: scope.stop)
        unknown = invoices.reject { |invoice| recorded.key?(invoice.payment_hash) }
        # Not read: whether the page can see the others is not known.
        return unknown.to_h { |invoice| [invoice.payment_hash, true] } if read.nil?

        unless read.newer.empty?
          scope.logger.warn("sattleme-checkout: a record of an invoice of the rest has a newer format than this " \
                            "version reads; update the gem")
        end
        unrecorded = {}
        unknown.each do |invoice|
          next if read.held.key?(invoice.payment_hash)
          # A record of a newer format at its address: never written over (SPEC.md §12).
          next if read.newer.key?(Internal::Derive.rest_record_address(keys.key, invoice.payment_hash))

          unrecorded[invoice.payment_hash] = true unless publish_rest(scope, invoice, now)
        end
        unrecorded
      end

      # wait_for_payment of an invoice without an address: a check every `interval`.
      def wait_lightning(stored, interval, listener, warnings, stop)
        loop do
          stop.check!
          begin
            status = status_of(stored, check(stored, stop, nil, warnings), seconds)
            listener&.call(status)
            return status if status.final?
          rescue NetworkError => e
            warnings.failed(e)
          end
          warnings.checked
          stop.cancellation.wait(interval / 1000.0)
        end
      end

      # wait_for_payment of an invoice with an address: each status combines the last result of each
      # part. A full check (every part, an invoice of the rest asked when needed) at each change the
      # explorer's WebSocket pushes and every 60 s; between them, the Lightning invoice and the rest
      # invoices the last full check found, every `interval`.
      def wait_with_address(stored, interval, listener, warnings, stop)
        waiter = AddressWait.new(self, stored, interval, listener, warnings, stop)
        waiter.run
      end

      # The parts of one wait_for_payment of an invoice with an address, driven from the calling
      # thread: the checks run in threads of their own and hand their results to it.
      class AddressWait
        def initialize(client, stored, interval, listener, warnings, stop)
          @client = client
          @stored = stored
          @interval = interval / 1000.0
          @listener = listener
          @warnings = warnings
          @stop = stop
          @inbox = Internal::Inbox.new
          @checks = stop.child
          # The checks it started, each until it ended.
          @running = []
          # The last result of each part; :unknown until it was checked once.
          @lightning = stored.lightning ? :unknown : nil
          @onchain = :unknown
          @rests = nil
          @checking = false
          @again = false
          @lightning_checking = false
          # Full checks started, the last one that ended, and the first one a status must wait for.
          @started = 0
          @ended = 0
          @wait_for = 0
          @lightning_at = nil
          @onchain_at = nil
          # The explorer's WebSocket: of the node the last channel read names (SPEC.md §31), with its
          # fallback, opened once a check read the channel (before, whether mempool.space may be
          # asked is not known), and opened again when the channel names another node. The node's
          # failures are the call's, shared by its checks and its WebSocket.
          @call = ExplorerCall.new(failures: Internal::NodeFailures.new, on_node: ->(node) { @inbox << [:node, node] })
          @watcher = nil
          @watched = nil
        end

        def run
          check_onchain
          loop do
            deadline = [@lightning_at, @onchain_at].compact.min
            message = @inbox.pop(@stop, deadline)
            outcome = handle(message)
            return outcome if outcome
          end
        ensure
          @watcher&.close
          # Nothing it started runs on once it returns (SPEC.md §23): each check is stopped, then
          # waited for until it ended.
          @checks.stop
          @running.each { |check| check.wait(nil) }
        end

        private

        # Handles one message: the final status once there is one.
        def handle(message)
          now = Internal::Clock.now
          if message.equal?(Internal::Inbox::TIMEOUT)
            if @onchain_at && now >= @onchain_at
              @onchain_at = nil
              check_onchain
            end
            if @lightning_at && now >= @lightning_at
              @lightning_at = nil
              check_lightning
            end
            return nil
          end
          case message
          in :change
            check_onchain
            nil
          in [:node, node] then watch(node)
          in [:full, mine, parts] then full_ended(mine, parts)
          in [:full_failed, error] then raise error
          in [:lightning, own, results, known] then lightning_ended(own, results, known)
          end
        end

        # A check read the channel, which names `node` (nil: mempool.space): the WebSocket watched is
        # that explorer's, with its fallback.
        def watch(node)
          key = node ? "#{node.fallback} #{node.url}" : "mempool"
          return nil if key == @watched

          @watcher&.close
          @watched = key
          explorer = Internal::CallExplorer.new(node, @call.failures, @client.send(:clock))
          @watcher = Internal::Watch.new(@client.send(:websocket_client), explorer, @stored.onchain_address,
                                         @client.send(:relay_timeout)) { @inbox << :change }
          nil
        end

        def full_ended(mine, parts)
          @checking = false
          @ended = mine
          @onchain = parts.onchain
          @rests = parts.rests
          @lightning = parts.lightning unless parts.lightning.nil?
          status = report
          return status if status

          # A full check ended: what it, and the checks of the Lightning invoices since the last one,
          # no longer met has stopped.
          @warnings.checked
          schedule_lightning
          if @again
            @again = false
            check_onchain
          end
          nil
        end

        def lightning_ended(own, results, known)
          @lightning_checking = false
          @lightning = own unless own == :unknown
          paid = false
          # A full check may have found other rest invoices meanwhile: its results stand.
          if known && @rests.equal?(known)
            paid = results.each_with_index.any? { |result, index| paid?(result) && !paid?(known.results[index]) }
            @rests = known.with(results: results)
          end
          if paid
            # Paid by a rest invoice: what is due on-chain changed, a full check tells the status.
            @wait_for = @started + 1
            check_onchain
          else
            status = report
            return status if status
          end
          schedule_lightning
          nil
        end

        # The status of the last results, given to the listener: itself once final, else nil.
        def report
          return nil if @lightning == :unknown || @onchain == :unknown
          # A rest invoice was paid after the last full check began: its on-chain part was judged
          # against what was due then, never combined with it (it might read underpaid for good).
          return nil if @ended < @wait_for

          parts = Parts.new(lightning: @lightning, onchain: @onchain, rests: @rests)
          begin
            status = @client.send(:status_of, @stored, parts, @client.send(:seconds))
          rescue NetworkError => e
            @warnings.failed(e)
            return nil
          end
          @listener&.call(status)
          status.final? ? status : nil
        end

        def paid?(result)
          result.ok? && result.value.paid?
        end

        def final?(result)
          result.ok? && !result.value.open?
        end

        # Whether a Lightning invoice (the order's, or one of the rest) may still change.
        def lightning_pending?
          own = @lightning == :unknown || (!@lightning.nil? && !final?(@lightning))
          own || (@rests&.results&.any? { |result| !final?(result) } || false)
        end

        def schedule_lightning
          return if !@lightning_at.nil? || @lightning_checking || !lightning_pending?

          @lightning_at = Internal::Clock.now + @interval
        end

        def check_lightning
          @lightning_checking = true
          known = @rests
          lightning = @lightning
          stored = @stored
          client = @client
          checks = @checks
          started = Internal::Future.spawn("sattleme-checkout wait") do
            context = client.send(:http, checks)
            own = if stored.lightning && (lightning == :unknown || (!lightning.nil? && !final?(lightning)))
                    Internal.settled do
                      Internal::Lnurl.verify_payment(stored.lightning, context, client.send(:seconds))
                    end.value(checks)
                  else
                    lightning
                  end
            results = (known&.invoices || []).each_with_index.map do |invoice, index|
              result = known.results[index]
              next Internal::Future.resolved(result) if final?(result)

              Internal.settled { Internal::Lnurl.verify_payment(invoice.lightning, context, client.send(:seconds)) }
            end
            @inbox << [:lightning, own, Internal.all(results, checks), known]
          rescue Internal::Stopped, Cancelled
            nil
          end
          track(started)
        end

        # Keeps `check` until it ended, and forgets those that did.
        def track(check)
          @running.reject!(&:settled?)
          @running << check
        end

        def check_onchain
          if @checking
            @again = true
            return
          end
          @checking = true
          @started += 1
          mine = @started
          # Every 60 s at least: a socket may go quiet without closing.
          @onchain_at = Internal::Clock.now + (Internal::Protocol::ONCHAIN_CHECK_INTERVAL_MS / 1000.0)
          client = @client
          stored = @stored
          checks = @checks
          warnings = @warnings
          started = Internal::Future.spawn("sattleme-checkout wait") do
            parts = client.send(:check, stored, checks, nil, warnings, @call)
            @inbox << [:full, mine, parts]
          rescue Internal::Stopped, Cancelled
            nil
          rescue StandardError => e
            @inbox << [:full_failed, e]
          end
          track(started)
        end
      end
      private_constant :AddressWait

      attr_reader :websocket_client

      # The client's clock (Unix seconds), as given.
      def clock = @now

      def relay_timeout = @relay_timeout_ms / 1000.0

      # The warnings of the checks of one wait_for_payment (SPEC.md §23): a warning each check meets
      # again (an explorer or a Lightning address that does not answer, a rest invoice that cannot
      # be asked, a witness that cannot be published) is logged once, and again only once a check
      # went without it. A logger itself (`warn`), for the checks.
      class OnceWarnings
        def initialize(logger)
          @logger = logger
          @mutex = Mutex.new
          @before = {}
          @now = {}
        end

        def warn(message)
          fresh = @mutex.synchronize do
            seen = @before.key?(message) || @now.key?(message)
            @now[message] = true
            !seen
          end
          @logger.warn(message) if fresh
        end

        # Warns of a check that failed (NetworkError): it is checked again.
        def failed(error)
          warn("sattleme-checkout: the payment check failed (#{error.message}); checked again")
        end

        # A check ended: a warning it did not meet stopped.
        def checked
          @mutex.synchronize do
            @before = @now
            @now = {}
          end
        end
      end
      private_constant :OnceWarnings

      # `items` in a random order, from the CSPRNG (so that two servers rarely try the same address
      # first): Fisher–Yates, each draw without bias.
      def in_random_order(items)
        shuffled = items.dup
        (shuffled.size - 1).downto(1) do |i|
          bound = i + 1
          # The largest multiple of `bound` within 2^32: draws at or above it are drawn again.
          limit = (2**32) - ((2**32) % bound)
          draw = nil
          loop do
            draw = @random.call(4).unpack1("N")
            break if draw < limit
          end
          j = draw % bound
          shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        end
        shuffled
      end
    end
  end
end
