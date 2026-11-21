# frozen_string_literal: true

module Sattleme
  module Checkout
    # What the gem gives and takes (SPEC.md §3). Each is an immutable value whose JSON is exactly
    # the specification's, whatever the language: an invoice stored by one implementation is
    # checked by another. Every amount is a string of digits (sats, minor units), never a float;
    # every date an Integer of Unix seconds; an absent value nil (JSON null). Readers are Ruby's
    # names (`payment_hash`); `to_h`, `as_json` and `to_json` give the JSON's (`paymentHash`).
    module Model
      # The JSON names of a model's members, in the specification's order.
      def self.json_names(members)
        members.to_h { |member| [member, member.to_s.gsub(/_([a-z0-9])/) { Regexp.last_match(1).upcase }] }
      end

      # What every model gives: its JSON (a Hash with the specification's names, JSON text).
      module Json
        def to_h
          self.class::JSON_NAMES.to_h do |member, name|
            value = public_send(member)
            [name, value.respond_to?(:as_json) && !value.is_a?(Array) ? value.as_json : value]
          end
        end

        def as_json(*)
          to_h
        end

        def to_json(*)
          Internal::Json.generate(to_h)
        end
      end

      # What every model reads: a Hash of its JSON (String or Symbol names), or JSON text. Every
      # member is there, null or not (SPEC.md §2: an absent member is never null): ArgumentError
      # names one that is not.
      module Reader
        def from_json(text)
          from_h(Internal::Json.parse(text))
        rescue Internal::Json::Invalid
          raise ArgumentError, "Not JSON"
        end

        def from_h(hash)
          new(**Model.members(hash, self::JSON_NAMES))
        end
      end

      # The members of `hash` named `names` (member → JSON name), each by its JSON name as a String
      # or a Symbol (Model.member). ArgumentError when `hash` is no Hash, or lacks one of them but
      # those of `optional`, which read as nil when absent.
      def self.members(hash, names, optional = [])
        raise ArgumentError, "Expected a Hash" unless hash.is_a?(Hash)

        names.to_h do |member, name|
          unless hash.key?(name) || hash.key?(name.to_sym) || optional.include?(member)
            raise ArgumentError, "No #{name}: a member is null only when it is there (SPEC.md §2)"
          end

          [member, member(hash, name)]
        end
      end

      # A member of a Hash by its JSON name, as a String or a Symbol (nil when absent). A JSON
      # number of an integer, which JSON text reads as a Float, is the Integer it writes: every
      # number of a model is one (dates, digits, confirmations).
      def self.member(hash, name)
        value = hash.key?(name) ? hash[name] : hash[name.to_sym]
        value.is_a?(Float) && Internal::Json.safe_integer?(value) ? value.to_i : value
      end

      # A model class: its members' JSON names, its JSON, its reading.
      def self.define(*members, &)
        Data.define(*members) do
          const_set(:JSON_NAMES, Model.json_names(members).freeze)
          include Model::Json
          extend Model::Reader

          class_eval(&) if block_given?
        end
      end
    end

    # A price in a currency: `minor` units with `digits` decimals ("2450", 2, "CHF" is 24.50 CHF).
    # `amount` is written with exactly `digits` decimals.
    Fiat = Model.define(:amount, :currency, :minor, :digits)

    # The rate an amount in a currency was converted at: its source ("coingecko", "mempool",
    # "opennode", "coinbase", "kraken" or "custom"), the price of one bitcoin (an exact decimal
    # string), when the gem read it, and when the source says it was set (nil when it does not).
    RateInfo = Model.define(:source, :currency, :price, :fetched_at, :time)

    # The invoice of an order (create_invoice): store it with the order. The shop's page needs
    # `payment_uri` (or `bolt11` and `onchain_address`) and `expires_at` only; with a checkout
    # link, the shop sends its customer to `checkout_url` instead. At least one of `bolt11` and
    # `onchain_address` is not nil. Read back (from_json, from_h), every member is there but
    # `onchainAddress`, which an invoice stored without an address may leave out (SPEC.md §22).
    Invoice = Model.define(:ref, :bolt11, :payment_hash, :verify_url, :onchain_address, :payment_uri,
                           :sats, :fiat, :rate, :note, :created_at, :expires_at, :checkout_url,
                           :redirect_url) do
      def self.from_h(hash)
        fields = Model.members(hash, self::JSON_NAMES, %i[onchain_address])
        fields[:fiat] = Fiat.from_h(fields[:fiat]) if fields[:fiat].is_a?(Hash)
        fields[:rate] = RateInfo.from_h(fields[:rate]) if fields[:rate].is_a?(Hash)
        new(**fields)
      end
    end

    # An invoice declared for an order, as the merchant's registry holds it (find_invoices,
    # InvoicePendingError, OrderPaidError): the members of an Invoice but `rate`, `checkout_url` and
    # `redirect_url`, which only the shop keeps, and `declared_at`: the date of its declaration
    # (without `bolt11`, of its lease's mark). Read back, every member is there but
    # `onchainAddress`, as an Invoice's.
    DeclaredInvoice = Model.define(:ref, :bolt11, :payment_hash, :verify_url, :onchain_address,
                                   :payment_uri, :sats, :fiat, :note, :created_at, :expires_at,
                                   :declared_at) do
      def self.from_h(hash)
        fields = Model.members(hash, self::JSON_NAMES, %i[onchain_address])
        fields[:fiat] = Fiat.from_h(fields[:fiat]) if fields[:fiat].is_a?(Hash)
        new(**fields)
      end
    end

    # What is left to pay of an invoice underpaid on-chain (PaymentStatus `open`): `sats`, a
    # Lightning invoice of exactly that, declared for the order (nil while there is none), and what
    # to show as one QR code (`bitcoin:…` from 1 000 sats, `lightning:…` below; nil with neither).
    Rest = Model.define(:sats, :bolt11, :payment_uri)

    # Where the payment of an invoice is (SPEC.md §3): `state` "open", "unconfirmed", "paid" or
    # "expired", and the members of that state (the others nil). `payment_method` is the JSON's
    # `method`: "lightning", "onchain" or "mixed", of a paid invoice.
    #
    # - open: not paid yet; it may still be, until `expires_at`, and is reported up to 120 s later.
    #   `received` above "0": an on-chain underpayment, whose `rest` is still payable.
    # - unconfirmed: enough was received in time (the amount, or less within the merchant's
    #   tolerance or down to what the merchant accepted), on-chain by `txids`, not 3 confirmations
    #   deep yet: not paid yet.
    # - paid in Lightning: `preimage`, the proof of payment, to keep with the order; on-chain:
    #   `received` and `txids`; mixed: `received`, `txids` and the `preimages` of the invoices of
    #   the rest.
    # - expired: never paid, for good. `received` above "0": the merchant received that much, less
    #   than the amount (settle it with the customer).
    class PaymentStatus < Data.define(:state, :payment_method, :expires_at, :received, :rest,
                                      :confirmations, :txids, :preimage, :preimages)
      STATES = %w[open unconfirmed paid expired].freeze
      METHODS = %w[lightning onchain mixed].freeze

      # The JSON members of each state, in the specification's order.
      MEMBERS = {
        "open" => %i[state expires_at received rest],
        "unconfirmed" => %i[state received confirmations txids],
        "lightning" => %i[state payment_method preimage],
        "onchain" => %i[state payment_method received txids],
        "mixed" => %i[state payment_method received txids preimages],
        "expired" => %i[state received]
      }.freeze
      JSON_NAMES = { state: "state", payment_method: "method", expires_at: "expiresAt",
                     received: "received", rest: "rest", confirmations: "confirmations",
                     txids: "txids", preimage: "preimage", preimages: "preimages" }.freeze

      def self.open(expires_at:, received:, rest:)
        new(state: "open", expires_at: expires_at, received: received, rest: rest)
      end

      def self.unconfirmed(received:, confirmations:, txids:)
        new(state: "unconfirmed", received: received, confirmations: confirmations, txids: txids)
      end

      def self.paid_lightning(preimage)
        new(state: "paid", payment_method: "lightning", preimage: preimage)
      end

      def self.paid_onchain(received:, txids:)
        new(state: "paid", payment_method: "onchain", received: received, txids: txids)
      end

      def self.paid_mixed(received:, txids:, preimages:)
        new(state: "paid", payment_method: "mixed", received: received, txids: txids, preimages: preimages)
      end

      def self.expired(received:)
        new(state: "expired", received: received)
      end

      # The status a Hash of its JSON gives: the members of its state, each there (SPEC.md §2).
      def self.from_h(hash)
        raise ArgumentError, "Expected a Hash" unless hash.is_a?(Hash)

        state = Model.member(hash, "state")
        method = Model.member(hash, "method")
        members = if state == "paid"
                    MEMBERS[method] if METHODS.include?(method)
                  elsif STATES.include?(state)
                    MEMBERS[state]
                  end
        raise ArgumentError, "Not a PaymentStatus: no state of SPEC.md §3, or no method of a paid one" unless members

        fields = Model.members(hash, JSON_NAMES.slice(*members))
        fields[:rest] = Rest.from_h(fields[:rest]) if fields[:rest].is_a?(Hash)
        new(**fields)
      end

      def self.from_json(text)
        from_h(Internal::Json.parse(text))
      rescue Internal::Json::Invalid
        raise ArgumentError, "Not JSON"
      end

      def initialize(state:, payment_method: nil, expires_at: nil, received: nil, rest: nil, confirmations: nil,
                     txids: nil, preimage: nil, preimages: nil)
        super(state: state, payment_method: payment_method, expires_at: expires_at, received: received,
              rest: rest, confirmations: confirmations, txids: txids&.dup&.freeze, preimage: preimage,
              preimages: preimages&.dup&.freeze)
      end

      def open? = state == "open"
      def unconfirmed? = state == "unconfirmed"
      def paid? = state == "paid"
      def expired? = state == "expired"

      # Whether it is final: paid or expired.
      def final? = paid? || expired?

      # The JSON of this state's members.
      def to_h
        MEMBERS.fetch(paid? ? payment_method : state).to_h do |member|
          value = public_send(member)
          [JSON_NAMES.fetch(member), value.is_a?(Rest) ? value.to_h : value]
        end
      end

      def as_json(*)
        to_h
      end

      def to_json(*)
        Internal::Json.generate(to_h)
      end
    end

    # The merchant, as the integration's channel, Lightning address and lot give it: its business's
    # name, the bounds of its Lightning address in sats, and how many deposit addresses the
    # integration's lot holds, leased or not (0: no on-chain payment yet). Never its Lightning
    # address.
    Merchant = Model.define(:business_name, :min_sats, :max_sats, :onchain_addresses)
  end
end
