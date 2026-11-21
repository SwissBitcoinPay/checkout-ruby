# Changelog

All notable changes to `sattleme-checkout`. Versions follow
[Semantic Versioning](https://semver.org/); tags are `vX.Y.Z`.

Released versions are published to RubyGems.org by CI, from the tag, once a maintainer approves
the release (README.md, "Releasing").

## 1.0.0 - 2026-11-20

First version. Follows version 1.0.0 of the specification
([sattleme/checkout-spec](https://github.com/sattleme/checkout-spec)) and passes its
conformance vectors.

- **The client**, `Sattleme::Checkout::Client`: reads the integration key and the merchant
  (`merchant`), makes the invoice of an order and declares it in the merchant's registry
  (`create_invoice`), checks its payment (`get_status`, `wait_for_payment`), finds the invoices of
  an order again (`find_invoices`). Made for a server that lives for one call: nothing is kept
  between calls. Every method takes a `Sattleme::Checkout::Cancellation`.
- **One order, one invoice at a time**, checked against the registry (`InvoicePendingError`,
  `OrderPaidError`): the payment of an invoice that may still be paid is checked first, even when
  it is the only one, so that an invoice already paid is never handed out again; of several, the
  one a majority of the relays holds is handed out.
- **Orders in sats or in a currency** (the ISO 4217 currencies), converted exactly and rounded up
  to the sat, at the price of a list of rate sources asked in turn: CoinGecko, mempool.space,
  Coinbase, Kraken, OpenNode, or your own. `Sattleme::Checkout.currency_digits(code)` gives the
  decimals of a currency an order may be priced in (nil for any other code), and
  `Sattleme::Checkout.fiat_to_sats(fiat, price)` the sats of a price.
- **Lightning payments**: an invoice from the merchant's Lightning address (LUD-16, LUD-21 verify
  URL).
- **On-chain payments**: from 1 000 sats, a taproot deposit address of the merchant's wallet leased
  for the order, with a single `bitcoin:` QR code (`payment_uri`). A lease is published
  unconfirmed, read again on every relay of the merchant, then marked confirmed: only a confirmed
  lease gives the order its address, and no order leases an address another order holds or a
  witness names. Payment checked on one explorer, paid at 3 confirmations on the explorer read,
  with fee bumps (RBF) and the `unconfirmed` state; `wait_for_payment` watches the address on the
  explorer's WebSocket. BlockCypher tells when a transaction no check saw in time was received.
- **The merchant's Bitcoin node**: the node the integration's channel names (`bitcoinNode`: its
  URL, by a rule of its own that allows `http` to a host of a local network, its `fallback`
  "mempool" or "none", and `payers`) is the explorer, read over REST and WebSocket with its
  fallback: a node that failed less than 60 s ago in the same call is asked after mempool.space, a
  check's two reads always come from one explorer; with "none", mempool.space is never asked, and
  a node that does not answer leases no address and gives `network`, never `expired`. With
  `payers` true, the checkout links' records name the node, whose page then reads it too. An
  invalid `bitcoinNode` is none. The gem's HTTP and WebSocket clients ask such a node in clear
  HTTP, and no other host.
- **Witnesses** of the transactions each check sees, which name the invoice they are of: a
  transaction a witness of another invoice names counts for nothing.
- **The rest of an on-chain underpayment**, payable in Lightning (and on-chain from 1 000 sats),
  shown on the order's checkout links; an order paid both ways is `paid` with `method: "mixed"`.
- **The merchant's tolerance of on-chain underpayments** (0 to 10 %), read in the integration's
  channel and kept in the lease of each order's address.
- **The merchant's acceptance** of an order underpaid on-chain at what it received, made by the
  merchant in its app: read by every check on every relay of the merchant, and counted only when a
  majority of them hold it; the order is then paid with `received` below its amount.
- **Checkout links**: `create_invoice(..., checkout: true, redirect_url:)` gives a `checkout_url`,
  a page of the merchant's web app where the customer pays, then is sent to `redirect_url`.
- **Outbound requests**: https URLs only (a lowercase host name, no IP address, no host under
  `localhost`), but for the merchant's Bitcoin node (its URL's own rule), no redirect followed, at most 1 MiB read of an answer's body and 16 KiB of its
  head, and `User-Agent: sattleme-Checkout/1`. The relays' WebSocket handshake follows no
  redirect, carries the same User-Agent and offers no compression; a read keeps only what opens
  with its keys, so a relay cannot make the server's memory grow.
- **Typed errors** with a stable `code` and whether they are retryable.
- **Stored invoices are JSON** (`Invoice#to_json`, `Invoice.from_json`), with the field names of
  every implementation of the specification: an invoice stored by another one is checked here, and
  the other way round.
