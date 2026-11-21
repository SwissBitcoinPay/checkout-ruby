# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The merchant's registry, as the integration's channel gives it: the registry key (32 bytes)
      # and the public half of the merchant's reading key (hex).
      Registry = Data.define(:key, :reader) do
        include Redacted

        def inspect = "#<Registry reader=#{reader}>"
        alias_method :to_s, :inspect
      end

      # Everything the sale of `ref` needs, derived once: its keys, its taker tag and the
      # conversation key (ECDH) of its declarations' inside with the merchant's reading key.
      # Secrets but `ref`, `author` and `taker`.
      class Sale
        include Redacted

        attr_reader :ref, :key, :secret_key, :author, :taker, :registry, :inner_key

        def initialize(ref:, key:, secret_key:, author:, taker:, registry:, inner_key:)
          @ref = ref
          @key = key
          @secret_key = secret_key
          @author = author
          @taker = taker
          @registry = registry
          @inner_key = inner_key
          freeze
        end

        def inspect = "#<Sale ref=#{ref} author=#{author}>"
        alias to_s inspect
      end

      # The keys an integration's server derives (SPEC.md §10), HKDF-SHA256, 32 bytes, salt and
      # info in UTF-8. They never change: the integration's channel, its sales and their
      # declarations derive from them, in the merchant's app as here.
      module Derive
        # The keys of an invoice's rest records (SPEC.md §31, "Rest records"): the rest key (its
        # checkout links' records carry it), the rest secret (it signs the records; only the
        # integration key derives it), its public key, the author, and the records' encryption key.
        RestKeys = Data.define(:key, :secret_key, :author, :encryption_key) do
          include Redacted

          def inspect = "#<RestKeys author=#{author}>"
          alias_method :to_s, :inspect
        end

        # The integration's witnesses' keys (SPEC.md §31, "Witnesses"): the seen secret (it signs
        # them), its public key (their author), the key of their addresses and order tags, and the
        # channel's encryption key (their conversation key). Secrets but `author`.
        SeenKeys = Data.define(:secret_key, :author, :address_key, :encryption_key) do
          include Redacted

          def inspect = "#<SeenKeys author=#{author}>"
          alias_method :to_s, :inspect
        end

        module_function

        def key(secret, salt, info)
          Crypto.hkdf(secret, salt, info)
        end

        # The integration's channel: its `d` tag (hex) and its NIP-44 conversation key.
        def channel_keys(integration_key)
          [Text.hex(key(integration_key, Protocol::INTEGRATION_SALT, Protocol::CHANNEL_ADDRESS_INFO)),
           key(integration_key, Protocol::INTEGRATION_SALT, Protocol::CHANNEL_ENCRYPTION_INFO)]
        end

        # Where the integration's lot of deposit addresses is: its `d` tag (hex).
        def lot_address(integration_key)
          Text.hex(key(integration_key, Protocol::INTEGRATION_SALT, Protocol::LOT_ADDRESS_INFO))
        end

        def seen_keys(integration_key)
          secret = key(integration_key, Protocol::INTEGRATION_SALT, Protocol::SEEN_SECRET_INFO)
          SeenKeys.new(secret_key: secret, author: Events.public_key(secret),
                       address_key: key(integration_key, Protocol::INTEGRATION_SALT, Protocol::SEEN_ADDRESS_KEY_INFO),
                       encryption_key: channel_keys(integration_key)[1])
        end

        # The key that marks the integration's declarations ("By" in the app).
        def taker_key(integration_key)
          key(integration_key, Protocol::INTEGRATION_SALT, Protocol::TAKER_INFO)
        end

        # The sale of an order: its own key, its Nostr secret and public key (its records' author).
        def sale_keys(integration_key, ref)
          sale_key = key(integration_key, Protocol::INTEGRATION_SALT, Protocol.sale_info(ref))
          secret = key(sale_key, Protocol::SALE_SALT, Protocol::SALE_NOSTR_SECRET_INFO)
          [sale_key, secret, Events.public_key(secret)]
        end

        def rest_keys(integration_key, ref, address, expires_at)
          rest_key = key(integration_key, Protocol::INTEGRATION_SALT, Protocol.rest_key_info(ref, address, expires_at))
          secret = key(integration_key, Protocol::INTEGRATION_SALT,
                       Protocol.rest_secret_info(ref, address, expires_at))
          RestKeys.new(key: rest_key, secret_key: secret, author: Events.public_key(secret),
                       encryption_key: key(rest_key, Protocol::CHECKOUT_SALT, Protocol::REST_ENCRYPTION_INFO))
        end

        # The `d` tag (hex) of the rest record of the invoice whose payment hash is `hash`.
        def rest_record_address(rest_key, hash)
          Text.hex(key(rest_key, Protocol::CHECKOUT_SALT, Protocol.rest_address_info(hash)))
        end

        # The `d` tag (hex) of the acceptance record of the invoice whose rest key is `rest_key`.
        def acceptance_record_address(rest_key)
          Text.hex(key(rest_key, Protocol::CHECKOUT_SALT, Protocol::ACCEPTANCE_ADDRESS_INFO))
        end

        # The `d` tag (hex) of the merchant's acceptance of the invoice of the sale `sale_author`
        # with the deposit address `address` and the end `expires_at` (SPEC.md §31, "The merchant's
        # acceptance"): one per invoice.
        def merchant_acceptance_address(integration_key, sale_author, address, expires_at)
          Text.hex(key(integration_key, Protocol::INTEGRATION_SALT,
                       Protocol.merchant_acceptance_info(sale_author, address, expires_at)))
        end

        # d(H): where the declarations of the payment hash `hash` (hex) are.
        def registry_address(registry_key, hash)
          Text.hex(Crypto.hmac(registry_key, Text.hex_bytes(hash)))
        end

        # The outer key of a record at `address` by `author` (hex).
        def outer_key(registry_key, address, author)
          key(registry_key, Protocol::DECLARATION_SALT, Protocol.outer_info(address, author))
        end

        # Who took a sale: the first 16 bytes of HMAC-SHA256(taker key, author), hex.
        def taker_tag(taker_key, sale_author)
          Text.hex(Crypto.hmac(taker_key, Text.hex_bytes(sale_author)).byteslice(0, Protocol::TAKER_TAG_BYTES))
        end

        # The registry of a channel's hex fields.
        def registry(registry_key, registry_reader)
          Registry.new(key: Text.hex_bytes(registry_key), reader: registry_reader)
        end

        def sale(integration_key, registry, ref)
          sale_key, secret, author = sale_keys(integration_key, ref)
          Sale.new(ref: ref, key: sale_key, secret_key: secret, author: author,
                   taker: taker_tag(taker_key(integration_key), author), registry: registry,
                   inner_key: Nip44.conversation_key(secret, registry.reader))
        end
      end
    end
  end
end
