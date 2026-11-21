# frozen_string_literal: true

# The sattle.me checkout SDK: take Lightning and on-chain payments for a sattle.me merchant from an
# online shop's server (README.md). Sattleme::Checkout::Client is where to start.

require_relative "checkout/version"
require_relative "checkout/errors"
require_relative "checkout/cancellation"
require_relative "checkout/internal/concurrency"
require_relative "checkout/internal/protocol"
require_relative "checkout/internal/secp256k1"
require_relative "checkout/internal/json"
require_relative "checkout/internal/text"
require_relative "checkout/internal/crypto"
require_relative "checkout/internal/nip44"
require_relative "checkout/internal/urls"
require_relative "checkout/internal/key"
require_relative "checkout/internal/event"
require_relative "checkout/internal/record"
require_relative "checkout/internal/derive"
require_relative "checkout/internal/bolt11"
require_relative "checkout/internal/currencies"
require_relative "checkout/models"
require_relative "checkout/internal/http"
require_relative "checkout/internal/rates"
require_relative "checkout/internal/onchain/address"
require_relative "checkout/internal/onchain/basics"
require_relative "checkout/internal/onchain/node"
require_relative "checkout/internal/lnurl"
require_relative "checkout/internal/order"
require_relative "checkout/internal/checkout_link"
require_relative "checkout/internal/channel"
require_relative "checkout/internal/declaration"
require_relative "checkout/internal/onchain/lease"
require_relative "checkout/internal/onchain/witness"
require_relative "checkout/internal/onchain/merchant_acceptance"
require_relative "checkout/internal/onchain/rest"
require_relative "checkout/internal/onchain/payment"
require_relative "checkout/internal/onchain/watch"
require_relative "checkout/internal/sales"
require_relative "checkout/internal/relay_pool"
require_relative "checkout/websocket_client"
require_relative "checkout/http_client"
require_relative "checkout/client"

module Sattleme
  # The sattle.me checkout SDK (README.md): Client makes invoices and checks their payments; every
  # error it raises is an Error, but for a Cancelled call.
  module Checkout
    # The rate sources the gem knows by name (SPEC.md §26), and the list asked when the client is
    # given none, in its order.
    RATE_SOURCES = Internal::Rates::NAMES
    DEFAULT_RATE_SOURCES = Internal::Rates::DEFAULT_SOURCES

    # The decimals of the currency whose code is exactly `code`, of those an order may be priced in
    # (ISO 4217 in upper case, the gem's table: SPEC.md §4 and §25), an Integer; nil for any other
    # text, and for anything that is not a String. `code` is read as create_invoice reads an
    # order's currency (a String in any encoding, as its text), so that it says whether an order
    # may be priced in it, and in how many decimals: whatever the platform's locale data says.
    def self.currency_digits(code)
      Internal::Currencies.digits(Internal::Text.caller_text(code))
    end

    # The sats an order priced `fiat` (`{ amount: "24.50", currency: "CHF" }`) asks at `price`, the
    # price of one bitcoin in its currency (a decimal String): exact, rounded up to the next whole
    # sat, as create_invoice converts it. InvalidOrderError (`fiat`) for an invalid price in a
    # currency, RateError for an invalid price of one bitcoin.
    def self.fiat_to_sats(fiat, price)
      Internal::Rates.fiat_to_sats(fiat, price)
    end
  end
end
