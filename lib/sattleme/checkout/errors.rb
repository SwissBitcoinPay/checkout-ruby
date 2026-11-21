# frozen_string_literal: true

module Sattleme
  module Checkout
    # What every error of this gem is (SPEC.md §5), but for a cancelled call, which raises
    # Cancelled: a stable `code` for programs, and whether the same call may succeed later,
    # unchanged (`retryable?`). A message never holds a secret: neither the integration's key, nor
    # a sale's key, nor any key derived from them.
    class Error < StandardError
      # A stable code: "invalid_key", "network"…
      attr_reader :code

      def initialize(code, message, retryable: false)
        super(message)
        @code = code
        @retryable = retryable
      end

      # Whether the same call may succeed later, unchanged (a relay or a service down).
      def retryable?
        @retryable
      end
    end

    # Not an integration's secret key (`sattleme_ck_…`), or a damaged one.
    class InvalidKeyError < Error
      def initialize(message = "Not a sattle.me integration key")
        super("invalid_key", message)
      end
    end

    # An option of the client or of a call is invalid (a programming error, found before any
    # request): `param` names it.
    class InvalidOptionError < Error
      attr_reader :param

      def initialize(param, message)
        super("invalid_option", "#{param}: #{message}")
        @param = param
      end
    end

    # A parameter of the order, or a stored invoice, is invalid: `param` names it.
    class InvalidOrderError < Error
      attr_reader :param

      def initialize(param, message)
        super("invalid_order", "#{param}: #{message}")
        @param = param
      end
    end

    # The merchant removed the integration: no invoice can be made with this key any more.
    class RevokedError < Error
      def initialize(message = "The merchant removed this integration")
        super("revoked", message)
      end
    end

    # The relays answered, but none holds the integration's channel (or only one of a newer format
    # than this version of the gem reads: `newer_format?`, then not retryable: update the gem).
    class ChannelNotFoundError < Error
      def initialize(newer_format: false)
        super(
          "channel_not_found",
          if newer_format
            "The integration's channel is of a newer format: update sattleme-checkout"
          else
            "The integration's channel was not found on its relays"
          end,
          retryable: !newer_format
        )
        @newer_format = newer_format
      end

      def newer_format?
        @newer_format
      end
      alias newer_format newer_format?
    end

    # A relay, the Lightning address's server, a rate source or an explorer did not answer (in
    # time), or fewer relays than needed did. Retry later.
    class NetworkError < Error
      def initialize(message = "No answer")
        super("network", message, retryable: true)
      end
    end

    # An invoice, a pay request or a payment answer that fails the checks: another network, amount,
    # merchant, duration or date, a verify answer about another invoice, a preimage that does not
    # match. Never show such an invoice.
    class InvalidInvoiceError < Error
      def initialize(message = "The invoice failed the checks")
        super("invalid_invoice", message)
      end
    end

    # The order still has an invoice that may be paid (not expired, or in the 120 s after its end,
    # or its on-chain payment being confirmed): show that one (`invoice`, a DeclaredInvoice)
    # instead of making another. With `checkout: true`, `checkout_url` is a new link to it, else nil.
    class InvoicePendingError < Error
      attr_reader :invoice, :checkout_url

      def initialize(invoice, checkout_url = nil)
        super("invoice_pending", "This order still has an invoice that may be paid")
        @invoice = invoice
        @checkout_url = checkout_url
      end
    end

    # The order was already paid, with `invoice`: `status` is its `paid` PaymentStatus, `preimage`
    # the proof of its own Lightning payment (nil when it was paid on-chain, or mixed). Never charge
    # it again.
    class OrderPaidError < Error
      attr_reader :invoice, :status, :preimage

      def initialize(invoice, status)
        super("order_paid", "This order was already paid")
        @invoice = invoice
        @status = status
        @preimage = status.payment_method == "lightning" ? status.preimage : nil
      end
    end

    # The rate source has no price in this currency (`currency`).
    class UnsupportedCurrencyError < Error
      attr_reader :currency

      def initialize(currency, source = "The rate source", message = nil)
        super("unsupported_currency", message || "#{source} has no price in #{currency}")
        @currency = currency
      end
    end

    # No usable rate: a source answered something that is not a price, a price too old, or a custom
    # source failed (`cause`). Retry later, or with another source.
    class RateError < Error
      def initialize(message = "No usable price")
        super("rate", message, retryable: true)
      end
    end

    # A checkout link was asked, and the merchant's app gives no web app for it. Make the invoice
    # without `checkout`, and show it on the shop's page.
    class CheckoutUnavailableError < Error
      def initialize
        super("checkout_unavailable",
              "The merchant's app gives no web app for checkout links: show the invoice on the " \
              "shop's page")
      end
    end

    # The order can only be paid on-chain (its amount is outside the Lightning address's bounds),
    # and no deposit address of the integration's lot could be leased. Retry later: the merchant's
    # app fills the lot again whenever it is opened.
    class OnchainUnavailableError < Error
      def initialize
        super("onchain_unavailable",
              "No deposit address of the integration's lot could be leased: try again later",
              retryable: true)
      end
    end
  end
end
