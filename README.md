# sattleme-checkout

Take Lightning and on-chain payments for a sattle.me merchant from an online shop's **server**,
in Ruby: the invoice of each order (a Lightning invoice, a deposit address of the merchant's
wallet, or both), its declaration in the merchant's registry, and the check of its payment.

- Everything runs on your server, which holds the integration's secret key. The customer's
  browser only ever gets the invoice and its address: on your page, or on the merchant's web app
  through a [checkout link](#checkout-links), if you ask for one.
- Payments go straight to the merchant's wallet. sattle.me runs no server and no API for
  integrations: this gem talks to the merchant's Lightning address (breez.tips), to the merchant's
  Nostr relays and, for [on-chain payments](#on-chain-payments), to one block explorer
  (mempool.space, or [the merchant's own Bitcoin node](#the-merchants-bitcoin-node) when it names
  one) and BlockCypher; nothing else (and to the rate source you choose, for prices in a
  currency).
- Amounts are exact: strings of digits (sats, a currency's minor units), never floating-point.

The protocol is specified, for implementations in other languages, in
[sattleme/checkout-spec](https://github.com/sattleme/checkout-spec) (`SPEC.md`), with conformance
vectors every implementation passes. This version implements its version 1.0.0 (`spec/PIN.json`).

## Requirements

- Ruby 3.3 or later (CRuby), on a **server**.
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) 0.2.0 or later, Bitcoin Core's
  library, installed on the system (see [Installing](#installing)).
- A clock synchronized by NTP: invoices more than 5 minutes off the server's clock are refused.
- An integration's secret key: the merchant creates the integration in the sattle.me app
  ("Integrations") and gives you its key, `sattleme_ck_…`.

## Installing

```ruby
# Gemfile
gem "sattleme-checkout", "1.0.0"
```

```sh
bundle install
```

The gem signs and checks Nostr events with libsecp256k1, the system's (it builds nothing):

| System          | Install                                                    |
| --------------- | ---------------------------------------------------------- |
| Debian, Ubuntu  | `apt install libsecp256k1-1` (Ubuntu 24.04, Debian 12 on)  |
| Fedora          | `dnf install libsecp256k1`                                 |
| Alpine          | `apk add libsecp256k1`                                     |
| macOS           | `brew install secp256k1`                                   |

Elsewhere, build it from Bitcoin Core's release (its `ecdh`, `extrakeys` and `schnorrsig` modules,
which its builds enable by default) and name the file in the environment:
`SATTLEME_SECP256K1_LIBRARY=/opt/secp256k1/lib/libsecp256k1.so`. Without it,
`require "sattleme/checkout"` raises `Sattleme::Checkout::LibraryNotFound`, which says how to
install it: never a call, later.

## The key is a secret

Keep the integration's key on the server only: in an environment variable or a secrets vault,
never in a web page, an app, a code repository or a log. With it, anyone can make invoices that
pay the merchant and mark sales as the integration's. It can never spend the merchant's funds nor
read their wallet. The gem never writes it anywhere: not in an error, a log, `inspect` nor
`to_h`.

If it leaks, the merchant removes the integration in the app ("Remove the integration") and
creates another one: the old key then makes no invoice, finds none and reads no merchant
(`RevokedError`). A check of an invoice it made still finds its Lightning payment: an invoice
without an address is checked as before, and one with an address is `RevokedError` unless its
Lightning invoice was paid (SPEC.md §14). The merchant settles by hand the orders still being paid
on-chain.

**One key, one shop.** The merchant creates one integration for each shop (each system with its
own orders' references), and two shops never share a key: the sale of an order is derived from the
key and the order's reference, so two shops with one key would share their references, and an
order of one would be found paid, or pending, with an invoice of the other. The servers of one
shop share its key.

## Quick start

```ruby
require "sattleme/checkout"

# Nothing to connect nor to close: each call reads the merchant, opens one connection per relay
# and closes it when it is done. One client for the whole process: it is safe to share between
# threads (Puma, Sidekiq).
SATTLEME = Sattleme::Checkout::Client.new(key: ENV.fetch("SATTLEME_INTEGRATION_KEY"))

# When the customer checks out, or when the payment page asks again:
def invoice_of(order)
  return order.invoice if order.invoice # one order, one invoice at a time

  begin
    invoice = SATTLEME.create_invoice(
      ref: order.ref, # "ORD-1042": the order's reference, its sale in the merchant's app
      sats: 49_000, # or "49000"; or: fiat: { amount: "24.50", currency: "CHF" }
      duration_seconds: 900, # 60 to 3600
      note: "Order #{order.number}" # shown to the merchant, 100 characters at most
    )
    order.update!(invoice: invoice.to_json) # a JSON column, or text
  rescue Sattleme::Checkout::InvoicePendingError => e
    # An invoice of this order may still be paid (say, after a crash): keep that one. It is the
    # registry's copy (a DeclaredInvoice): the same fields, without `rate`.
    order.update!(invoice: e.invoice.to_json)
  end
  order.invoice
end

# The payment page gets the invoice alone: its paymentUri ("bitcoin:bc1p…?amount=…&lightning=lnbc…")
# and expiresAt. When it asks for the order's status (every 1 to 2 seconds):
def status_of(order)
  status = SATTLEME.get_status(order.invoice) # the stored JSON as it is
  if status.paid?
    # In Lightning: keep the preimage, the proof of payment. On-chain: the transactions. Mixed
    # (on-chain, its rest in Lightning): both.
    order.mark_paid!(status.to_json)
  elsif status.expired?
    # Never paid: the order may get a new invoice. `received` above "0": an on-chain
    # underpayment the merchant received, to settle with the customer.
    order.update!(invoice: nil)
  end
  status.state # "open", "unconfirmed", "paid" or "expired"
end
```

`create_invoice` gives a `Sattleme::Checkout::Invoice`, whose JSON (`invoice.to_json`) you store
with the order:

```ruby
{
  "ref" => "ORD-1042",
  "bolt11" => "lnbc490u1p…", # the BOLT11 invoice; nil for an order paid on-chain only
  "paymentHash" => "9c41…",
  "verifyUrl" => "https://breez.tips/lnurlp/verify/9c41…",
  "onchainAddress" => "bc1p…", # the deposit address it leased, or nil (Lightning only)
  "paymentUri" => "bitcoin:bc1p…?amount=0.00049&lightning=lnbc490u1p…", # one QR code for both
  "sats" => "49000",
  "fiat" => nil, # or { "amount" => "24.50", "currency" => "CHF", "minor" => "2450", "digits" => 2 }
  "rate" => nil, # or { "source" => "coingecko", "currency" => "CHF", "price" => "69012", "fetchedAt", "time" }
  "note" => "Order 1042",
  "createdAt" => 1791378000, # Unix seconds
  "expiresAt" => 1791378900,
  "checkoutUrl" => nil, # a checkout link, with checkout: true
  "redirectUrl" => nil
}
```

Every amount is a string of digits, every date an integer of Unix seconds, an absent value `null`:
the JSON is the same in every implementation of the specification, which reads what this gem
stores, and the other way round. Its members are the Invoice's in snake case
(`invoice.onchain_address`, `invoice.expires_at`…); `Sattleme::Checkout::Invoice.from_json(text)`
reads it back, every member there (a member left out is not `null`: `ArgumentError`), but
`onchainAddress`, which an invoice stored without an address may leave out. `get_status` and
`wait_for_payment` take the Invoice, its JSON text, or the Hash of its JSON.

**Stored invoices are your shop's.** Check only the invoices your shop stored itself with their
orders, where only it writes (its database), never one that comes from the customer (a form field,
a URL, a cookie): `get_status` checks that a stored invoice is well formed (SPEC.md §22), never that
this integration made it. An invoice someone else wrote, with a Lightning invoice of their own that
they paid, reads as `paid` (SPEC.md §27).

Instead of polling from your page's requests, a background job may wait for the payment:

```ruby
final = SATTLEME.wait_for_payment(order.invoice, interval_ms: 2000,
                                  cancellation: Sattleme::Checkout::Cancellation.after(3600)) do |status|
  Rails.logger.info("#{order.ref}: #{status.state}")
end
# final.paid? (final.payment_method: "lightning", "onchain" or "mixed"), or final.expired?
```

A network failure only delays the next check. One that each check meets again (an explorer or the
Lightning address that does not answer…) is reported to your `logger` once, and again only after
it stopped.

### One order, one invoice at a time

- An order keeps its invoice until it has **expired**: `get_status` says `expired` 120 seconds
  after the invoice's end (a payment of its last seconds may be reported that late). Only then may
  the order get a new invoice. `create_invoice` checks it in the merchant's registry and raises
  `InvoicePendingError` (with that invoice) while an earlier invoice of the same `ref` may still be
  paid (or its on-chain payment is being confirmed), or `OrderPaidError` (with its `status`, and
  the `preimage` of a Lightning payment) when one was paid.
- Only the order that holds an invoice is marked paid with it, in the database transaction that
  marks it paid. Keep the `preimage` (the proof of a Lightning payment) or the `txids` (of an
  on-chain one) and the `rate` the amount was converted at, to answer a customer or an audit.
- Invoices of the same `ref` are one sale in the merchant's app. One order, one `ref`: never
  reused for another order by anything that holds the key (a test copy of the shop, a restored
  database included), and never taken from what the customer sends (make it on your server).
- After a failure, `find_invoices(ref)` lists the invoices declared for an order, from the
  merchant's registry.
- "One at a time" holds within one `Client` and against the registry: when several processes may
  make the invoice of the same order at once, lock the order (in your database:
  `order.with_lock { invoice_of(order) }`) around `create_invoice`.

### Showing the invoice

This gem is for servers only. The shop's page shows the invoice with its own code:

- a QR code of `payment_uri`, with any QR library (`rqrcode`, a JavaScript one):
  `bitcoin:<address>?amount=…&lightning=<bolt11>` with an address (BIP-21, the "unified QR" wallets
  read: they pay in Lightning or on-chain), `lightning:<bolt11>` without one;
- an "Open in wallet" link to the same URI;
- the time left until `expires_at`, then the status your server gives (`open`, `unconfirmed`,
  `paid`, `expired`). With an on-chain underpayment, `open` carries what was `received` and its
  `rest`: show its `payment_uri` as the QR code (the rest in Lightning, and on-chain to the same
  address from 1 000 sats), until `expires_at`.

The page talks to your server only: never give it the key, nor ask it to reach breez.tips or the
relays. Or send the customer to a checkout link instead (below).

## Checkout links

Instead of showing the invoice on your page, you may send the customer to a page of the merchant's
sattle.me web app made for this invoice: its QR code, a button that opens the customer's wallet,
the time left, then "Paid" or "Expired". Once the invoice is paid, the page sends the customer
back to your `redirect_url`, 7 seconds later or at once with a tap.

```ruby
invoice = SATTLEME.create_invoice(
  ref: "ORD-1042",
  fiat: { amount: "24.50", currency: "CHF" },
  note: "Order 1042", # shown to the customer too
  checkout: true,
  redirect_url: "https://shop.example/orders/1042/thanks" # or "myshop://orders/1042"
)
# Store it with the order, then redirect the customer's browser to invoice.checkout_url:
# "https://…/pay#c.…" (nothing after "#" is ever sent to the web app's host).
```

- **Optional, per order.** Without `checkout: true`, nothing changes. `redirect_url:` alone is
  refused (`InvalidOrderError`, `param` `"redirect_url"`); without one, the page shows the receipt
  and sends the customer nowhere.
- **Not a proof of payment.** Anyone can open your redirect URL. When the customer arrives there,
  check the order with `get_status(invoice)` (or `wait_for_payment`) on your server, and mark it
  paid only then, as without checkout.
- **What the page gets**: a record the gem publishes on a majority of the merchant's relays, before
  the invoice is declared: the invoice, its verify URL, its deposit address (with its amount and
  dates), the business's name, the price, the note and your redirect URL; and, when the merchant
  lets the pages read [its Bitcoin node](#the-merchants-bitcoin-node) (`payers`), that node's URL
  and fallback. Never the key, the merchant's Lightning address nor its registry. It is signed by
  a key of that link alone, forgotten once it is published: nobody, you included, can change a
  link afterwards. Relays that honor NIP-40 drop it a week after the invoice's end.
- **The rest of an underpayment**: with an address, the record also carries the key and the public
  key with which the page reads the invoices of the rest your server asks for
  ([On-chain payments](#on-chain-payments)): the page shows the rest's invoice as soon as a check of
  your server published it, so keep checking the payment while the customer pays
  (`wait_for_payment`, or `get_status` from your page's polling). Only the integration key signs
  them.
- **Who sees the customer**: the customer's browser loads the web app, reads the record from the
  merchant's relays and checks the payment with the merchant's Lightning address (breez.tips) and,
  with an address, the explorer (mempool.space, or the merchant's node with `payers`): they see
  its IP address, which they never do when your page shows the invoice.
- **Redirect URLs**: `https://` with a lowercase host name (no IP address, no `localhost` nor a
  name under it, no `user:password@`), or an app's link (`myshop://…`), 2048 characters at most,
  every character of RFC 3986 (anything else percent-encoded, host names in punycode). Refused:
  `http:`, browser and file schemes, other browsers' schemes (`x-safari-https:`, `googlechrome:`,
  `firefox:`…, which would open a web page whose host the page cannot show: a web page is an
  `https` URL), `intent:`, payment schemes (`lightning:`, `bitcoin:`…), calls and messages. The
  page shows "Redirecting to shop.example" (or "myshop://") on its button. Prefer universal links
  (iOS) and App Links (Android), which are `https` URLs: browsers do not open an app on their own
  after a delay (Chrome on Android refuses it), so for an app's link the customer taps the button.
- **One order, one invoice at a time** holds with checkout links too. When an invoice of the order
  may still be paid, `InvoicePendingError` carries, with `checkout: true`, a new link to it:
  `error.checkout_url`. Send the customer there.
- **Availability**: the merchant's app says in the integration's channel where its web app is. An
  app without a web app gives none: `create_invoice` with `checkout: true` raises
  `CheckoutUnavailableError`; show the invoice on your page instead.

## On-chain payments

From 1 000 sats, an order may also be paid on-chain, to a deposit address of the merchant's
wallet. Nothing to ask for: `create_invoice` leases an address when the amount allows it, and the
Invoice's `payment_uri` shows both methods in one QR code.

| Amount                                          | Methods                                                      |
| ----------------------------------------------- | ------------------------------------------------------------ |
| below 1 000 sats                                | Lightning (outside its bounds: `InvalidOrderError`)          |
| 1 000 sats or more, within the Lightning bounds | Lightning and on-chain (Lightning only without an address)   |
| 1 000 sats or more, outside them                | on-chain only (`OnchainUnavailableError` without an address) |

- **The lot**: your server has no wallet and makes no address. The merchant's app gives the
  integration a lot of up to 100 taproot addresses (`bc1p…`) of its wallet, and fills it again
  whenever the merchant opens the app. `merchant.onchain_addresses` says how many it holds (0: no
  on-chain payment yet).
- **One address, one order**: an order leases an address in the merchant's registry until its
  invoice's end plus 120 seconds; two servers never keep the same one. The lease is published, read
  again on every relay of the merchant (it is confirmed when no other order holds the address),
  then marked confirmed: only then is the address the order's. An address the explorer shows paid
  already, or that a witness (below) names, is skipped.
- **Unconfirmed, then paid**: `get_status` says `unconfirmed` once enough was sent in time, then
  `paid` (`payment_method` `"onchain"`) at 3 confirmations on the explorer read (mempool.space, or
  the merchant's node): about 30 minutes. Ship the order only once it is `paid`.
  `wait_for_payment` watches the address on the explorer's WebSocket meanwhile; a server that
  cannot wait that long checks again later with `get_status` (`create_invoice` for the same `ref`
  raises `InvoicePendingError` while it is being confirmed).
- **In time**: a transaction counts for the order when it came while the lease ran. The gem records
  each transaction it sees in the merchant's registry (a witness), so that the merchant's app tells
  the same order paid: check the payment while the customer pays (your page's polling, or
  `wait_for_payment`), until the invoice's end and its 120 seconds. A transaction no check saw by
  then is told by BlockCypher's time; one received after the end is late: it reaches the merchant,
  but pays no order. A replacement (RBF, a fee bump) of a payment in time counts for it. A
  transaction counts for one invoice at most: one that a witness of another invoice names counts
  for nothing here.
- **Underpaid**: `received` is what came in time. Below the amount (and unless the merchant's
  tolerance or acceptance, below, accepted it), the invoice stays `open` until its end, then
  `expired` with `received` above "0": the merchant received it, settle it with the customer. An
  overpayment is `paid`.
- **The merchant's tolerance**: the merchant may accept, in its app, an on-chain payment a little
  short of the amount (up to 10 %) as paying the order in full. An order keeps the tolerance of its
  creation, whatever the merchant sets later. A payment short by no more than it is
  `unconfirmed`, then `paid`, with `received` below the amount: ship the order as for any `paid`
  status. One short by more is underpaid: its whole rest is asked. The tolerance is the merchant's:
  the gem never gives it to your server, nor to your customer; the page of a checkout link learns
  only that this payment counts (an acceptance record), and sends the customer back to your shop.
- **The merchant's acceptance**: the merchant may also accept, by hand in its app, what an order
  underpaid on-chain received as paying it in full: one short by more than its tolerance, which
  the merchant would rather settle at what came. Nothing to configure, nothing to call: every check
  (`get_status`, `wait_for_payment`, and `create_invoice`'s check of an order's earlier invoices)
  reads it on every relay of the merchant with the order's witnesses, and counts it only when a
  majority of those relays hold it. The order is then `unconfirmed`, then `paid` (`payment_method`
  `"onchain"`, or `"mixed"` with invoices of the rest), with `received` below the amount, as with
  the tolerance: ship it as for any `paid` status. `wait_for_payment` sees it at its next check of
  the on-chain part (within 60 s), the `rest` still given until then. Only the merchant's team can
  make one: neither your server's key nor a customer can. The page of a checkout link learns of it
  as of the tolerance, through an acceptance record.
- **The rest, in Lightning**: the check that sees an underpayment (`get_status`,
  `wait_for_payment`) asks the merchant's Lightning address for an invoice of the rest, until the
  invoice's end, declares it in the merchant's registry and publishes it for the order's checkout
  links, whose page shows it at once. `open` carries it in `rest`:

  ```ruby
  status.to_h
  # {
  #   "state" => "open",
  #   "expiresAt" => 1791378900,
  #   "received" => "20000", # what came in time
  #   "rest" => {
  #     "sats" => "29000", # what is left
  #     "bolt11" => "lnbc290u1p…", # its invoice; nil while there is none (asked at the next check)
  #     "paymentUri" => "bitcoin:bc1p…?amount=0.00029&lightning=lnbc290u1p…" # one QR code
  #   }
  # }
  ```

  From 1 000 sats the rest is payable on-chain to the same address too; below, in Lightning only
  (`payment_uri` is `lightning:…`, or nil while its invoice is asked). No invoice of the rest is
  asked with less than a minute left, nor outside the Lightning address's bounds; a failure is
  logged as a warning, never raised: the next check asks again. Once the rest is paid, the order
  is `unconfirmed` until its on-chain part is 3 confirmations deep, then `paid` with
  `payment_method` `"mixed"`: keep its `txids` and the `preimages` of the invoices of the rest.

- **Who sees what**: the explorer (mempool.space, or the merchant's node, and mempool.space too
  when the node fails and its fallback is `"mempool"`) sees your server's IP address and the
  addresses and transactions it asks about; BlockCypher, a transaction no check saw in time. Never
  a key. Trust rests on that one explorer: what it alone shows makes a payment count as made.

### The merchant's Bitcoin node

The merchant may have the blockchain read from a node of its own that serves mempool.space's API
(an Umbrel, a server of its own) rather than from mempool.space. It sets it in its app, which
writes it in the integration's channel (`bitcoinNode`): nothing to configure on your server. Every
call reads it with the channel; every read of an address and of the chain's height (when an
address is leased, at each check), and `wait_for_payment`'s WebSocket, then go to the node:
`http://192.168.1.10:3006` is read at `http://192.168.1.10:3006/api` and
`ws://192.168.1.10:3006/api/v1/ws` (`wss://` for an `https://` node). BlockCypher and the
`"mempool"` rate source stay BlockCypher's and mempool.space's.

- **Its URL** follows a rule of its own (SPEC.md §31): `https`, or `http` for a host of a local
  network only (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, a name under `.local`);
  an IPv4 address or a lowercase name, never `localhost`, 127.0.0.0/8 nor 0.0.0.0/8; an optional
  port and path (not ending with `/` nor `/api`); no user name, query nor fragment; 200 characters
  at most. A node the channel names in any other way, or with an invalid `fallback` or `payers`,
  is none: mempool.space is read, and the channel stays valid.
- **Its `fallback`**, when the node does not answer a read (no answer, an error status, a
  redirect, an answer out of format):
  - `"mempool"`: the same read of mempool.space, `NetworkError` when both fail. A node that failed
    less than 60 s ago in the same call (`create_invoice`, `get_status`, one `wait_for_payment`) is
    asked after mempool.space, so that a node that is down does not make each read wait for its
    timeout. The WebSocket goes to mempool.space's when the node's fails, or is lost before any
    message.
  - `"none"`: mempool.space is never asked. While the node does not answer, no address is leased
    (`create_invoice` gives a Lightning invoice only, or `NetworkError` for an order paid on-chain
    only) and every check of an order with an address is `NetworkError`: never `expired` nor
    final underpaid for want of an answer, however long it lasts. The order waits until the node
    answers again; `wait_for_payment` goes on meanwhile.

  A check's two reads (the address's transactions and the chain's height) always come from one
  explorer: when the node fails either, both are asked of mempool.space.

- **A node on the merchant's network** (`http://192.168.1.10:3006`, `http://umbrel.local`) is
  reachable only by a server on that network: a shop the merchant hosts itself, or one that joined
  it (by Tailscale, for one). Any other server fails every read of it, and its fallback applies:
  with `"none"`, no on-chain payment at all. The gem's `HttpClient` and `WebSocketClient` ask such
  a node in clear (`http://`, `ws://`), and no other host: every other URL stays `https` or `wss`
  to a name. An `http_client:` or `websocket_client:` of yours gets an `http://` or `ws://` URL
  only for such a node: reach it in clear HTTP (through your proxy, if it allows that host), or
  raise, and the fallback applies.
- **`payers`**: with `true` (only for a node of the Internet: `https` and a name, not under
  `.local`), the checkout links' records name the node (its `url` and `fallback`, never `payers`),
  and their page reads the chain from it too, with the same fallback; the node then sees the
  customer's IP address and the address the page follows, and whoever holds a link reads the
  node's URL. With `false`, only your server reads the node, and the page reads mempool.space.
- **Security**: a node's URL is the merchant's choice, and the gem follows a valid one: GET
  requests at the paths of mempool.space's API under `/api`, and the WebSocket's two messages, in
  clear HTTP too to a host of a local network, and to an IPv4 address. Nothing is sent but
  deposit addresses, no redirect is followed, and every answer is bounded and checked. But if your
  server holds the keys of several merchants (a shared host), one merchant could so have it ask
  machines of your own network: restrict what your server can reach to public addresses (see
  [Outbound requests](#outbound-requests)); such a merchant's node is then unreachable, and its
  fallback applies. The node is trusted as mempool.space is: what it shows decides whether an
  order is paid. Over `http`, whoever is on the network between your server and the node can
  change its answers: it is as safe as that network.

## Prices in a currency

Give `fiat:` instead of `sats:`: the gem converts the price to sats on your server, at the rate of
a price source, and declares the price to the merchant's app, which shows it. Nothing to set up:
without `rate_source`, it asks the default list of sources (below).

```ruby
invoice = SATTLEME.create_invoice(
  ref: "ORD-1043",
  fiat: { amount: "24.50", currency: "CHF" } # a String: never a Float
)
# 24.50 CHF at 69 012 CHF/BTC: ⌈2450 × 10^8 / 6 901 200⌉ = 35 502 sats
```

- `currency` is an ISO 4217 code in upper case, of the ISO 4217 currencies (List One, without
  funds, metals and test codes). `amount` is a string of digits with at most the currency's
  decimals (2 for CHF, 0 for JPY, 3 for KWD): those the merchant's app uses, from the gem's own
  table, never from the platform's locale data. `Sattleme::Checkout.currency_digits(code)` gives
  them, with no key and nothing asked: `2` for `"CHF"`, nil for any text that is not exactly one of
  these codes (`"chf"`, `" CHF"`, `"XAU"`, `"BTC"`). Ask it, for one, whether your shop may offer
  its customers to pay in its currency, and in how many decimals its prices go to `create_invoice`.
- The conversion is exact, on integers: the price of one bitcoin is read as the decimal its source
  wrote, and the sats are **rounded up** to the next whole sat, so that the merchant never receives
  less than the price. `Sattleme::Checkout.fiat_to_sats(fiat, price)` gives what an order asks at a
  price.
- The sats must fit the bounds of the merchant's Lightning address (`merchant`), as for an amount
  in sats.

### Rate sources

`rate_source` is optional. Without it, the gem asks these sources **one after the other**, the next
one only when the previous one does not answer, gives no usable price, or has no price in the
currency (`Sattleme::Checkout::DEFAULT_RATE_SOURCES`):

`"coingecko"`, then `"mempool"`, `"coinbase"`, `"kraken"` and `"opennode"`.

The dated sources come first (a dated price is checked for its age), then the undated ones. The
first usable price is the rate, and `invoice.rate.source` names the source that gave it. Each
source that failed before it is reported to your `logger` as a warning.

To choose, give `rate_source:` to the client or to an order (an order's wins):

```ruby
Sattleme::Checkout::Client.new(key: key, rate_source: "kraken") # this source only: no other is asked
Sattleme::Checkout::Client.new(key: key, rate_source: %w[kraken coingecko]) # asked in this order
SATTLEME.create_invoice(ref: ref, fiat: fiat, rate_source: %i[mempool coinbase]) # this order only
```

A list holds sources (names, as Strings or Symbols, or callables), at least one, no name twice;
anything else raises `InvalidOptionError` (`InvalidOrderError` for an order). `rate_source: nil` is
no source either: leave the keyword out for the default list. Each source asked may take up to
`http_timeout_ms`: a list of 5 sources that all fail to answer may take 5 times as long.

| Source        | Currencies                  | Dated | Notes                                                                                                                 |
| ------------- | --------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------- |
| `"coingecko"` | many                        | yes   | No key needed. Optional: a Demo key (`coingecko_api_key:`), sent to CoinGecko only. Without one, limited by IP.       |
| `"mempool"`   | USD EUR GBP CAD CHF AUD JPY | yes   |                                                                                                                       |
| `"coinbase"`  | many                        | no    | Prices are decimal strings, read as written.                                                                          |
| `"kraken"`    | Kraken's pairs              | no    | The last trade's price.                                                                                               |
| `"opennode"`  | ~140                        | no    |                                                                                                                       |
| a callable    | yours                       | maybe | `->(currency) { "69012.5" }`, or `{ price:, time: }`. Never a number. `rate.source` is then `"custom"`.               |

Any other source (a CoinGecko Pro key, your own mempool instance, several sources checked against
each other) is a callable. It gives the price as a **String**, as its source wrote it: a number may
already have lost digits. With two parameters, it gets a `Cancellation` too, cancelled when the call
is, or once the call no longer needs the price (another of its steps failed meanwhile): stop then,
the call waits for your callable to return.

```ruby
require "net/http"
require "json"

rates = lambda do |currency, cancellation|
  # Your service answers { "price": "69012.50", "time": 1791378000 }: the price as a string.
  response = Net::HTTP.get_response(URI("https://rates.example.ch/btc/#{currency}"))
  raise Sattleme::Checkout::UnsupportedCurrencyError.new(currency, "rates.example.ch") if response.code == "404"

  cancellation.raise_if_cancelled
  body = JSON.parse(response.body)
  { price: body.fetch("price"), time: body["time"] }
end
SATTLEME = Sattleme::Checkout::Client.new(key: ENV.fetch("SATTLEME_INTEGRATION_KEY"), rate_source: rates)
```

A price its source dates is refused when it is more than an hour old, or more than 5 minutes
ahead: the next source of the list is then asked. When no source gives a price, `create_invoice`
raises `UnsupportedCurrencyError` if none of them has the currency, else the last `RateError` (no
usable price) or `NetworkError` (no answer), both retryable. Your callable raises
`UnsupportedCurrencyError` when it has no price in a currency, `NetworkError` or `RateError` when
it cannot give one now: the next source is then asked. Any other error of yours becomes a
`RateError` (your error as its `cause`); an error of this gem of another kind stops the list and
goes through as it is.

## Errors

Every error is a `Sattleme::Checkout::Error` with a stable `code` and `retryable?`, but for a
cancelled call, which raises `Sattleme::Checkout::Cancelled` (never an `Error`). None ever holds a
secret: neither the key, nor a sale's key, nor any key derived from them.

| Error                      | Code                   | When                                                                                                                                                                   | Retry?           |
| -------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `InvalidKeyError`          | `invalid_key`          | The key is not an integration key (another prefix, damaged, an old `https://…/pay#…` link).                                                                            | no               |
| `InvalidOptionError`       | `invalid_option`       | An option of the client or of `wait_for_payment` is invalid: `error.param` names it.                                                                                   | no               |
| `InvalidOrderError`        | `invalid_order`        | A parameter is invalid: `error.param` names it (`ref`, `sats`, `fiat`, `rate_source`, `duration_seconds`, `note`, `checkout`, `redirect_url`, `invoice`, `order`).    | no               |
| `RevokedError`             | `revoked`              | The merchant removed the integration.                                                                                                                                  | no               |
| `ChannelNotFoundError`     | `channel_not_found`    | The relays answered without the integration's channel (`newer_format?`: update the gem).                                                                               | when not newer   |
| `NetworkError`             | `network`              | A relay, breez.tips, a rate source or an explorer did not answer, or fewer than a majority of the merchant's relays took a record.                                     | yes              |
| `InvalidInvoiceError`      | `invalid_invoice`      | An invoice or a payment answer failed the checks. Never show such an invoice.                                                                                          | no               |
| `InvoicePendingError`      | `invoice_pending`      | An earlier invoice of this order may still be paid, or is being confirmed on-chain: `error.invoice` (and `error.checkout_url` with `checkout: true`).                  | after it expires |
| `OrderPaidError`           | `order_paid`           | An earlier invoice of this order was paid: `error.invoice`, `error.status`, `error.preimage` (nil on-chain).                                                           | no               |
| `UnsupportedCurrencyError` | `unsupported_currency` | The rate source has no price in this currency (`error.currency`).                                                                                                      | no               |
| `RateError`                | `rate`                 | No usable price: invalid, too old, or your rate callable failed.                                                                                                       | yes              |
| `CheckoutUnavailableError` | `checkout_unavailable` | `checkout: true`, and the merchant's app gives no web app for checkout links.                                                                                          | no               |
| `OnchainUnavailableError`  | `onchain_unavailable`  | The order can only be paid on-chain, and no address of the integration's lot could be leased.                                                                          | yes              |

`error.invoice` is a `DeclaredInvoice`, `error.status` a `PaymentStatus`: both have `to_json`.
Every value the gem gives (`Invoice`, `DeclaredInvoice`, `PaymentStatus` of each state, `Rest`,
`Fiat`, `RateInfo`, `Merchant`) writes the JSON of SPEC.md §3 with `to_json`, and gives it as a
Hash with `as_json` and `to_h`: the json gem (`JSON.generate`) and Rails (`render json:`, a log)
write it so too, alone or in a document. An option or a parameter given as `nil` is one not given
(its default), but for `rate_source: nil`, which is invalid (no source).

## Cancellation

Every method takes `cancellation:`, a `Sattleme::Checkout::Cancellation`:

```ruby
cancellation = Sattleme::Checkout::Cancellation.new
Thread.new { sleep 5; cancellation.cancel("the customer left") }
SATTLEME.wait_for_payment(invoice, cancellation: cancellation) # raises Cancelled after 5 s

# Or bounded in time:
SATTLEME.wait_for_payment(invoice, cancellation: Sattleme::Checkout::Cancellation.after(600))
```

A cancelled call stops its requests, closes its connections and raises `Cancelled` (its `reason`,
and its message when the reason is a String), even when a step that cannot stop at once (a name's
resolution, a callable of yours) delayed it: never an error of the table above, never a result.

## What `create_invoice` does

1. Reads the integration's channel on the Nostr relays of the key (signed by the merchant's team,
   following up to 3 moves of the merchant's relays): the merchant's Lightning address, registry
   and relays, or `removed`. At every call: a removal stops the next invoice.
2. Checks that no earlier invoice of the order may still be paid (its payment checked: one already
   paid is never handed out again, `OrderPaidError`; one underpaid on-chain gets the invoice of its
   rest, as with `get_status`, before `InvoicePendingError`). Meanwhile, reads the Lightning
   address and, for a price in a currency, the rate.
3. Converts the price to sats, when it is in a currency; its methods follow from the amount.
4. With Lightning, asks the merchant's Lightning address for the invoice (LUD-06/16), and checks
   it: Bitcoin mainnet, exactly the amount, the merchant's description hash, a verify URL (LUD-21)
   on the same host and port, no longer than asked, dated within 5 minutes.
5. With on-chain, leases an address of the integration's lot: publishes the lease on a majority of
   the merchant's relays, reads the address's leases again on every relay to confirm it, then marks
   it confirmed. A lease that was not confirmed is withdrawn, and the next address is tried.
   Without an address, Lightning only (or `OnchainUnavailableError`).
6. With `checkout: true`, publishes its checkout link on a majority of the merchant's relays.
   Without a majority, no invoice (nothing is declared).
7. With Lightning, declares it in the merchant's registry, on a majority of the merchant's relays:
   so that its payment counts for this order's sale and for no other. Without a majority, no
   invoice.

A confirmed lease is never withdrawn, whatever fails after it (its mark, the link, the
declaration): it holds its address until its end, and the order's next `create_invoice` may hand
its invoice out (`InvoicePendingError`).

`get_status` asks the invoice's verify URL (LUD-21) and accepts a Lightning payment only with the
preimage of its payment hash, in an answer about this very invoice; with an address, it asks the
explorer at the same time and reads the witnesses of the order (see
[On-chain payments](#on-chain-payments)).

A call opens one connection per relay, used for all it reads and writes there, and closes them
when it is done. Every relay is asked at once, each in a thread of its own, and reads and writes go
on as soon as a majority of the relays answered (each declaration is on a majority of them, and
any two majorities share a relay): a slow or down relay slows nothing. Three reads decide that a
record is nobody else's and wait for every relay instead, up to `relay_timeout_ms` after a
majority answered: a lease's confirmation, the witnesses read again after one is published, and
the choice among several invoices of an order that may still be paid. A relay that failed earlier
in the call is not waited for again. A write to the relays past the majority goes on in a
background thread, for `relay_timeout_ms` at most, then its connection closes.

HTTP requests follow no redirect, read at most 1 MiB of an answer's body, 16 KiB of its head
(status line and headers) and 10 MiB of all it holds besides its body (a chunked body's size lines
included), and carry `User-Agent: sattleme-Checkout/1`, the same in every implementation of the specification. The
relays' WebSocket handshake follows no redirect either, carries the same User-Agent (relays behind
a bot protection refuse a handshake without one), and offers no compression; a message larger than
1 MiB fails its connection before it is read. Of what a relay sends, a read keeps only what opens
with its keys and, for a signed record, whose signature checks out (of a lease, only its id,
author, date, signature and end; of any other event, its id and its date): a relay cannot make the
server's memory grow. A JSON text in which more than 64 arrays and objects nest is no JSON.

## Outbound requests

Besides fixed hosts (the rate sources, mempool.space, BlockCypher), your server asks hosts that
others choose: the merchant's Lightning address and its provider (breez.tips), the merchant's
relays and [its Bitcoin node](#the-merchants-bitcoin-node). Their URLs are checked first: `https`
or `wss` only, no IP address, no `localhost` nor a name under it, no redirect followed; but for
the merchant's node, whose URL follows its own rule (`http` and `ws` to a host of a local network,
an IPv4 address). A name may still lead into your own network (an internal name, a public name
resolving to a private address), and the gem does not resolve names itself (a name that resolves
again would bypass such a check). If your server holds the keys of several merchants, or sits in a
network with services of its own, restrict what it can reach to public addresses: in your network
(an egress proxy, a firewall), or in the HTTP and WebSocket clients you give the client (below).

The time a request takes counts from its start, the resolution of the host's name and the
connection included: `http_timeout_ms` bounds an HTTP request, its body included,
`relay_timeout_ms` each request to a relay.

## Security

- **Constant time.** What handles a secret key on the curve is libsecp256k1's, Bitcoin Core's
  library (see [Dependencies](#dependencies)): signing (BIP-340, `secp256k1_schnorrsig_sign32`),
  a key's public point (`secp256k1_keypair_create`) and the ECDH of NIP-44 (`secp256k1_ecdh`) run
  in constant time and with constant memory access in the secret: its README says so of signing
  and key generation ("Constant time, constant memory access signing and public key generation"),
  and its ECDH multiplies by the secret with `secp256k1_ecmult_const` ("in constant-time for q",
  `src/ecmult_const.h`). Its context is randomized once loaded (`secp256k1_context_randomize`), a
  blinding against side channels. HKDF, HMAC-SHA256 and ChaCha20 are OpenSSL's, and MACs are
  compared with `OpenSSL.fixed_length_secure_compare`. The Ruby code around them (a key copied,
  a sale's key written in hex into its records) is not constant time, and Ruby cannot erase a
  String from memory: the key lives in the server's memory as long as the client does.
- **Reports**: [SECURITY.md](SECURITY.md).

## Limits

- One hour at most per invoice; on-chain, about 30 minutes more to be `paid` (3 confirmations).
- Not measured: the limits of breez.tips, of mempool.space and of the relays for a shop that makes
  many invoices from one IP address. BlockCypher takes 100 requests an hour from an IP address
  without a token: it is asked only about a transaction no check saw while its lease ran.
- Each call runs a thread per relay, and a few for the HTTP requests it makes at once: a server
  that makes many calls at once runs that many more threads.

Not in this version: refunds, webhooks, and showing open (unpaid) invoices in the merchant's app.

## Options

```ruby
Sattleme::Checkout::Client.new(
  key: ENV.fetch("SATTLEME_INTEGRATION_KEY"), # required
  # A source or a list of them (names or callables); without it, the default list.
  rate_source: Sattleme::Checkout::DEFAULT_RATE_SOURCES,
  coingecko_api_key: nil, # optional: CoinGecko's Demo key (visible ASCII), sent to CoinGecko only
  # Anything with get(url, headers:, timeout:, cancellation:) { |chunk| … } giving the HTTP status.
  http_client: Sattleme::Checkout::HttpClient.new,
  # Anything with connect(url, timeout:, headers:, cancellation:) giving a socket.
  websocket_client: Sattleme::Checkout::WebSocketClient.new,
  relay_timeout_ms: 10_000, # per relay request, connection included: 100 to 60 000
  http_timeout_ms: 10_000, # per HTTP request, body included: 100 to 60 000
  # Anything with warn(message), never given a secret: Rails.logger, a Logger (require "logger").
  logger: nil # nil: standard error, a line each
)
```

An invalid option, or one the client does not know, raises `InvalidOptionError` at once, before any
request. `now:` (a callable giving Unix seconds) and `random:` (a callable giving that many random
bytes) are for tests only.

**Threads.** A call runs its requests in threads of its own (one per relay, one per HTTP request,
its checks at once): what you give the client (`http_client`, `websocket_client`, `logger`, `now`,
`random`, a rate source of yours) is called from several threads within one call, so it must be
safe to call so. Once a call returned, nothing it started runs on, but the relays of a publication
past its majority: each may still finish its own request (with NIP-42's one authentication and the
one write again), up to `relay_timeout_ms`, and so use your `websocket_client`, `now` and `random`
after the call returned (SPEC.md §4, §13). A request the gem gives up (its time ran out, its call is
cancelled or failed meanwhile) is told so through its `cancellation`, or its socket is closed, and
the call waits half a second for it to stop: a client that does not is left behind, never the call.

- **Behind an HTTP proxy**: `Sattleme::Checkout::HttpClient.new(proxy: URI("http://proxy:3128"))`
  (a proxy that tunnels with CONNECT). It never reads the proxy of the environment.
- **A company's certificate authority**: `HttpClient.new(cert_store: store)`, an
  `OpenSSL::X509::Store`; for the relays,
  `WebSocketClient.new(connector: TlsConnector.new(ssl_context: context))`.
- **The merchant's node on a local network**: `HttpClient` and `WebSocketClient` reach it in clear
  (`WebSocketClient.new(plain_connector: …)`, a `PlainConnector` by default), and no other host
  (see [The merchant's Bitcoin node](#the-merchants-bitcoin-node)).
- **Your own WebSocket client**: its `connect` gives a socket with `send_text(text)`, `receive` (the
  next text message, nil once closed) and `close`. Keep it bounded as the gem's is: no redirect
  followed, no compression offered, the headers it is given (the User-Agent) sent, a message capped
  at 1 MiB, the handshake within `timeout`.

## Dependencies

| Dependency                                                    | Version                     | Why                                                                                                                                                                          |
| ------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [libsecp256k1](https://github.com/bitcoin-core/secp256k1)     | 0.2.0 or later (the system) | BIP-340 Schnorr signatures, x-only keys and the ECDH of NIP-44: the library Bitcoin Core uses and audits. Never a curve of this gem's own. 0.2.0 is the oldest supported.     |
| [ffi](https://github.com/ffi/ffi)                             | 1.17.4 (`>= 1.17.4, < 2`)   | Calls libsecp256k1 without a C extension of this gem's own: ffi ships prebuilt for Linux and macOS, where installing compiles nothing.                                     |
| Ruby's own `openssl`                                          | Ruby's                      | SHA-256, HMAC-SHA256, HKDF-SHA256 and ChaCha20 (NIP-44, key derivations), TLS 1.2 or later for HTTP and the relays, the certificates' checks.                              |
| Ruby's own `socket`                                           | Ruby's                      | The TCP connections of the gem's HTTP client (HTTP/1.1, its own: no redirect, every part of an answer bounded) and WebSocket client (RFC 6455, its own: no compression).   |

Nothing else at run time. Development only, pinned exactly in `Gemfile.lock` (with their
checksums): minitest 5.27.0 (the tests), rake 13.4.2 (the checks), RuboCop 1.92.2 with
rubocop-minitest 0.41.0 (format and lint), and RuboCop's own json 2.18.0, parser 3.3.13.0, prism
1.8.2 and racc 1.8.1, held at the versions Ruby 4.0.9 ships so that the CI compiles nothing.

## Development

```sh
bundle install
bundle exec rake # the pinned specification, RuboCop (format and lint), the tests, the package
```

`bundle exec rake test` runs the tests alone, `bundle exec rubocop -a` corrects what RuboCop can.
Without a system libsecp256k1, `bundle exec rake secp256k1` builds Bitcoin Core's v0.8.0 (its commit
checked; git, cmake and a C compiler) into `tmp/secp256k1`, which the tests find.

The tests run local Nostr relays (in-process WebSocket servers) and fakes of breez.tips, of the
rate sources, of mempool.space and of a merchant's Bitcoin node (REST and WebSocket) and of
BlockCypher, reached through the injected HTTP and WebSocket clients: no network.

`spec/` is a copy of [sattleme/checkout-spec](https://github.com/sattleme/checkout-spec) pinned to
one commit (`spec/PIN.json`, checked file by file by `bundle exec rake spec:check` and the tests),
never edited here. Its vectors are what the tests check the gem against: the conformance vectors,
the official NIP-44 vectors, the merchant's app's vectors (`spec/vectors/app/app.json`) and the
vectors an implementation makes for the app to read (`spec/vectors/app/implementation-declaration.json`,
`spec/vectors/app/checkout-link.json`, `spec/vectors/app/checkout-rest.json`). A disagreement with
the specification, or a wrong vector, is reported to checkout-spec. To take a newer version: clone
checkout-spec at that commit (of its default branch, a tagged version when there is one), then
`bundle exec rake "spec:import[../checkout-spec]"`: it replaces `spec/` and `spec/PIN.json`
together, from the clone's `manifest.json`, and refuses a clone with changes of its own. Commit the
copy with the code that passes the new vectors, in one pull request.

## Releasing

Releases are the maintainers': never from a development or agent session. A maintainer writes the
version's entry in `CHANGELOG.md` and sets `Sattleme::Checkout::VERSION`
(`lib/sattleme/checkout/version.rb`), then pushes a tag `vX.Y.Z` of that version on a commit of
`main`.
`.github/workflows/release.yml` then runs the CI again, checks that the tag is the gem's version and
that its commit is on `main`, and publishes the gem to RubyGems.org in a job bound to the protected
environment `rubygems` (required reviewers: a maintainer approves each release). It publishes by
trusted publishing: RubyGems.org exchanges that job's OIDC token for a short-lived key, and no key
is stored anywhere. To set it up once: on RubyGems.org, the gem's trusted publisher
`sattleme/checkout-ruby`, workflow `release.yml`, environment `rubygems`; on GitHub, the environment
`rubygems` with its required reviewers, and a ruleset that lets only maintainers create `v*` tags.
The exchange names the RubyGems.org account that owns the gem, by its immutable ID
(`RUBYGEMS_OWNER` in `release.yml`): RubyGems.org creates the gem, at its first release, only from
that account's pending trusted publisher, which expires if no release uses it in time.

## License

[MIT](LICENSE)
