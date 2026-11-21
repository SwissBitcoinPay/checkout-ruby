# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Every constant of the protocol (SPEC.md §28), in one place. Those marked "never changes" are
      # fixed by data already published (keys, channels, declarations): changing one loses
      # merchants' sales or stops their integrations.
      module Protocol
        # The beginning of every integration key (`sattleme` sattle.me, `ck` checkout key). Never
        # changes: a later format of the key takes another prefix (`sattleme_ck2_`).
        INTEGRATION_KEY_PREFIX = "sattleme_ck_"
        # Bytes of the team's public key and of the integration's key.
        KEY_BYTES = 32

        # HKDF-SHA256 salts (UTF-8). Never change.
        INTEGRATION_SALT = "sattle.me/integration"
        SALE_SALT = "sattle.me/sale"
        DECLARATION_SALT = "sattle.me/registry-declaration"

        # HKDF-SHA256 `info` strings (UTF-8). Never change.
        CHANNEL_ADDRESS_INFO = "channel/address/v1"
        CHANNEL_ENCRYPTION_INFO = "channel/encryption-key/v1"
        TAKER_INFO = "taker/v1"
        SALE_NOSTR_SECRET_INFO = "nostr-secret-key/v1"
        # Bytes of HMAC-SHA256(taker key, author) kept as the taker tag.
        TAKER_TAG_BYTES = 16

        # NIP-78 application data: every record of the app. NIP-42 authentication.
        RECORD_KIND = 30_078
        AUTH_KIND = 22_242
        # A record's plaintext is padded with spaces to a multiple of this many bytes.
        RECORD_BLOCK_BYTES = 256

        CHANNEL_RECORD_TYPE = "team-channel"
        CHANNEL_VERSION = 1
        # At most this many moves of the merchant's relays are followed.
        MAX_RELAY_MOVES = 3
        # Longest business name, in Unicode code points.
        MAX_BUSINESS_NAME_LENGTH = 200

        DECLARATION_RECORD_TYPE = "registry-declaration"
        DECLARATION_VERSION = 1
        # The currency of a sale declared in sats: its `minor` is the sats, its `digits` 0.
        SATS_CURRENCY = "SAT"
        # Most decimals a declared price may have.
        MAX_DECLARED_DIGITS = 8
        # Largest amount in minor units (2^53 − 1: a JSON number every reader holds exactly).
        MAX_MINOR_UNITS = 9_007_199_254_740_991

        # Checkout links (SPEC.md §30). The salt and `info` strings never change: the merchant's web
        # app derives the same keys.
        CHECKOUT_SALT = "sattle.me/checkout"
        CHECKOUT_ADDRESS_INFO = "address/v1"
        CHECKOUT_ENCRYPTION_INFO = "encryption-key/v1"
        CHECKOUT_RECORD_TYPE = "checkout"
        CHECKOUT_VERSION = 1
        # The version of a checkout link's record for an invoice with an address.
        CHECKOUT_ONCHAIN_VERSION = 2
        # The first part of a checkout link's fragment: a link of this version. Never changes.
        CHECKOUT_MARKER = "c"
        # The page of the merchant's web app that reads checkout links.
        CHECKOUT_PATH = "/pay"
        # A checkout link's record lives this long after its invoice's end (NIP-40): a week.
        CHECKOUT_LIFE_SECONDS = 604_800
        # Longest redirect URL, in characters (ASCII only), and longest scheme of an app's link.
        MAX_REDIRECT_URL_LENGTH = 2048
        MAX_REDIRECT_SCHEME_LENGTH = 32
        # Schemes a redirect URL never has: the browser's own, files and scripts; other browsers
        # (they open any web page given in the rest of the link, whose host the page would not show:
        # a web page is an https URL); other transports; any Android activity; payments (a second
        # invoice right after the first); calls and messages; installing software or running system
        # tools. `https` follows its own rule.
        REFUSED_REDIRECT_SCHEMES = %w[
          about blob chrome chrome-extension content data file filesystem javascript moz-extension
          resource safari-extension vbscript view-source
          brave com-apple-mobilesafari-tab ddgquicklink firefox firefox-focus googlechrome
          googlechrome-x-callback googlechromes microsoft-edge microsoft-edge-http
          microsoft-edge-https onionbrowser onionbrowsers opera-http opera-https x-safari-http
          x-safari-https
          ftp http ws wss
          android-app intent
          bitcoin keyauth lightning liquidnetwork lnurl lnurlc lnurlp lnurlw
          callto facetime facetime-audio mailto sip sms tel
          itms-services ms-msdt search-ms
        ].to_set.freeze

        # Most relays a list holds, and the longest relay address (`wss://` included).
        MAX_RELAYS = 10
        MAX_RELAY_URL_LENGTH = 120
        # Longest host of a relay address, a checkout origin, a redirect URL or an https URL.
        MAX_HOST_LENGTH = 253
        # Longest https URL (a pay URL, a callback, a verify URL), in characters (ASCII only).
        MAX_HTTPS_URL_LENGTH = 2048

        # An order's reference: one order, one sale.
        REF_PATTERN = /\A[A-Za-z0-9._:-]{1,64}\z/
        REF_RULE = "1 to 64 characters A-Z a-z 0-9 . _ : -"
        # Invoice durations, in seconds.
        MIN_DURATION_SECONDS = 60
        MAX_DURATION_SECONDS = 3600
        DEFAULT_DURATION_SECONDS = 900
        # Longest note, in Unicode code points.
        MAX_NOTE_LENGTH = 100

        # After an invoice's end, a payment of its last seconds may still be reported: until then,
        # "not paid" is not final.
        GRACE_SECONDS = 120
        # An invoice's date may be this far from the server's clock (synchronized by NTP).
        CLOCK_TOLERANCE_SECONDS = 300
        # The LUD-21 refusal that means "never paid" once the grace period is over.
        NOT_FOUND_REASON = "Not found"

        # A dated price older than this is refused; one dated further than the clock tolerance
        # ahead too.
        MAX_RATE_AGE_SECONDS = 3600
        # Longest price text a rate source may give, and largest exponent (either sign) in it.
        MAX_PRICE_LENGTH = 64
        MAX_PRICE_EXPONENT = 64

        # Most events read from one relay for one query, and most pages of a paged read.
        MAX_EVENTS_PER_QUERY = 1000
        MAX_PAGES = 20
        # The `limit` of each page of a complete read: a page of fewer events is the relay's last.
        COMPLETE_READ_LIMIT = 100
        # The User-Agent of every HTTP request and WebSocket handshake: the same in every
        # implementation and version (CoinGecko refuses a request without one; one naming a language
        # or a version would help single it out).
        USER_AGENT = "sattleme-Checkout/1"
        # Largest message read from a relay, and largest HTTP answer body read.
        MAX_RELAY_MESSAGE_BYTES = 1 << 20
        MAX_HTTP_BODY_BYTES = 1 << 20
        # Earlier invoices of an order checked at once (createInvoice).
        MAX_PARALLEL_PAYMENT_CHECKS = 4

        # Per request timeouts, in milliseconds: the default and the bounds a caller may choose.
        DEFAULT_TIMEOUT_MS = 10_000
        MIN_TIMEOUT_MS = 100
        MAX_TIMEOUT_MS = 60_000
        # waitForPayment's interval, in milliseconds.
        DEFAULT_INTERVAL_MS = 2000
        MIN_INTERVAL_MS = 250
        MAX_INTERVAL_MS = 60_000

        # Longest `x` (expiry) field of a BOLT11 invoice, in 5-bit words (35 bits, as its date).
        MAX_BOLT11_EXPIRY_WORDS = 7
        # Largest BOLT11 amount: 21 million bitcoins, in millisatoshis.
        MAX_BOLT11_AMOUNT_MSAT = 2_100_000_000_000_000_000

        # On-chain payments (SPEC.md §31). The types, salts and `info` strings never change: the
        # merchant's app reads the same records.
        # Below this amount, an order is Lightning only.
        ONCHAIN_FLOOR_SATS = 1000
        # The largest amount of an order: 21 million bitcoins, in sats.
        MAX_SATS = 2_100_000_000_000_000
        SATS_PER_BTC = 100_000_000

        LOT_RECORD_TYPE = "integration-onchain-lot"
        LOT_VERSION = 1
        LOT_ADDRESS_INFO = "onchain-lot/address/v1"
        # Most addresses a lot holds.
        MAX_LOT_ADDRESSES = 100

        LEASE_RECORD_TYPE = "registry-onchain"
        LEASE_VERSION = 1
        # What a deposit address's registry address is the HMAC of: this, then the address (UTF-8).
        LEASE_ADDRESS_PREFIX = "onchain/v1/"
        # Leases read back this far: a lease ends at most 4 320 s after its `created_at` (a BOLT11
        # date up to 300 s ahead, 3600 s, the grace period, the clock tolerance).
        LEASE_LOOKBACK_SECONDS = 7200
        # Free addresses tried for one order.
        MAX_ADDRESS_TRIES = 3

        WITNESS_RECORD_TYPE = "integration-onchain-seen"
        WITNESS_VERSION = 1
        SEEN_SECRET_INFO = "onchain-seen/nostr-secret-key/v1"
        SEEN_ADDRESS_KEY_INFO = "onchain-seen/address-key/v1"
        # The tag of a witness that names its order (its address and sale), and its address.
        ORDER_TAG = "o"
        # The coins of a transaction a witness keeps: its first 100.
        MAX_WITNESS_INPUTS = 100
        # The `sale` a witness names when the transaction came at no lease's time.
        NO_SALE = "none"

        # mempool.space (Esplora REST): the explorer, unless the channel names the merchant's Bitcoin
        # node (BitcoinNodes), and the node's fallback when it says "mempool".
        MEMPOOL_URL = "https://mempool.space/api"
        # mempool.space's WebSocket, which wait_for_payment watches an address on without a node.
        MEMPOOL_WEBSOCKET_URL = "wss://mempool.space/api/v1/ws"
        # A node URL (SPEC.md §31, "A node URL"): 200 characters at most.
        MAX_NODE_URL_LENGTH = 200
        # A node that failed a read less than this long ago, in the same call, is asked after
        # mempool.space (`fallback` "mempool"): a node that does not answer does not make each read
        # wait for its timeout.
        NODE_FAILED_RECENTLY_SECONDS = 60
        # When a transaction was received, asked only for one no check saw while its lease ran.
        BLOCKCYPHER_URL = "https://api.blockcypher.com/v1/btc/main"
        # Confirmations of an on-chain payment, on the explorer read.
        CONFIRMATIONS = 3
        # The on-chain part is checked at least this often while waitForPayment waits.
        ONCHAIN_CHECK_INTERVAL_MS = 60_000
        # The explorer's WebSocket, lost: connected again after this, doubled at each failure, up
        # to RECONNECT_MAX_MS.
        RECONNECT_FIRST_MS = 1000
        RECONNECT_MAX_MS = 30_000

        # The rest of an on-chain underpayment (SPEC.md §31). The type, the salts and the `info`
        # strings never change: the merchant's web app reads the same records.
        REST_RECORD_TYPE = "checkout-rest"
        REST_VERSION = 1
        # HKDF `info` (salt CHECKOUT_SALT) of a rest record's encryption key.
        REST_ENCRYPTION_INFO = "rest/encryption-key/v1"
        # A rest invoice is asked only with this long left before the invoice's end.
        MIN_REST_SECONDS = 60

        # The merchant's tolerance of on-chain underpayments: an integer of basis points, from 0 to
        # MAX_TOLERANCE (10 %); anything else is 0.
        MAX_TOLERANCE = 1000
        # Basis points in a whole.
        TOLERANCE_SCALE = 10_000

        # Acceptance records (SPEC.md §31). The type and the `info` string never change.
        ACCEPTANCE_RECORD_TYPE = "checkout-accepted"
        ACCEPTANCE_VERSION = 1
        ACCEPTANCE_ADDRESS_INFO = "rest/accepted/v1"

        # The merchant's acceptance (SPEC.md §31, "The merchant's acceptance"): the merchant accepts
        # by hand, in its app, what an order underpaid on-chain received as paying it. A record of
        # the team (never the integration's: it opens one but cannot make one), sealed with the
        # channel's key, at an address the integration key derives (salt INTEGRATION_SALT) from the
        # order's sale author, the invoice's deposit address and its `expiresAt`. The type and the
        # `info` string never change: the merchant's app writes the same records.
        MERCHANT_ACCEPTANCE_RECORD_TYPE = "integration-onchain-accepted"
        MERCHANT_ACCEPTANCE_VERSION = 1

        module_function

        def sale_info(ref) = "sale/#{ref}/v1"

        def outer_info(address, author) = "outer/v1/#{address}/#{author}"

        # HKDF `info` of the rest key and the rest secret of the invoice of the order `ref` with the
        # deposit address `address` and the end `expires_at` (Unix seconds, decimal).
        def rest_key_info(ref, address, expires_at) = "checkout-rest/#{ref}/#{address}/#{expires_at}/key/v1"

        def rest_secret_info(ref, address, expires_at)
          "checkout-rest/#{ref}/#{address}/#{expires_at}/nostr-secret-key/v1"
        end

        # HKDF `info` (salt CHECKOUT_SALT) of a rest record's address, of the payment hash `hash`.
        def rest_address_info(hash) = "rest/address/#{hash}/v1"

        # HKDF `info` (salt INTEGRATION_SALT) of the merchant's acceptance address of the invoice of
        # the sale `sale` (its author, hex) with the deposit address `address` and the end
        # `expires_at` (Unix seconds, decimal).
        def merchant_acceptance_info(sale, address, expires_at) = "onchain-accepted/#{sale}/#{address}/#{expires_at}/v1"
      end
    end
  end
end
