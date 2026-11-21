# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # A signed Nostr event (NIP-01): what the gem makes, and what a relay sent once its id checked
      # out (its numbers then integers).
      Event = Data.define(:id, :pubkey, :created_at, :kind, :tags, :content, :sig) do
        # The event as JSON holds it.
        def to_h
          { "id" => id, "pubkey" => pubkey, "created_at" => created_at, "kind" => kind, "tags" => tags,
            "content" => content, "sig" => sig }
        end

        # The value of its first `d` tag, nil without one.
        def d_tag
          tags.find { |tag| tag[0] == "d" }&.[](1)
        end
      end

      # Nostr events (SPEC.md §11): their id, their BIP-340 signature with fresh auxiliary random
      # data, and the checks of an event a relay sent, which is never trusted.
      module Events
        module_function

        # The NIP-01 serialization of an event (SPEC.md §11): the JSON array [0, pubkey, created_at,
        # kind, tags, content] without whitespace, its numbers written as integers whatever their
        # spelling, its strings as JSON.stringify writes them.
        def serialization(pubkey, created_at, kind, tags, content)
          Json.generate([0, pubkey, created_at, kind, tags, content])
        end

        # The event id: SHA-256 of the UTF-8 of its serialization.
        def hash_of(pubkey, created_at, kind, tags, content)
          Crypto.sha256(serialization(pubkey, created_at, kind, tags, content).b)
        end

        # The x-only public key (hex) of a BIP-340 secret key.
        def public_key(secret)
          Text.hex(Secp256k1.public_key(secret))
        end

        # Whether `value` is an x-only public key (lowercase hex) of a point of secp256k1 (BIP-340
        # `lift_x`).
        def public_key?(value)
          Text.hex32?(value) && Secp256k1.xonly?(Text.hex_bytes(value))
        end

        # The event of `kind`, `tags`, `content` at `created_at`, signed by `secret` with 32 random
        # bytes of `random` as auxiliary data (BIP-340).
        def sign(secret, random, created_at:, kind:, tags:, content:)
          pubkey = public_key(secret)
          hash = hash_of(pubkey, created_at, kind, tags, content)
          Event.new(id: Text.hex(hash), pubkey: pubkey, created_at: created_at, kind: kind, tags: tags,
                    content: content, sig: Text.hex(Secp256k1.sign(hash, secret, random.call(32))))
        end

        # `value` as a Hash of an event's fields (a relay's JSON object, or an Event).
        def fields(value)
          value.is_a?(Event) ? value.to_h : value
        end

        # Whether `value` has the shape of an event and its id is its hash: what is checked of a
        # record before anything else where anybody may write (SPEC.md §31, "Opening a lease"),
        # its signature only where it decides. A string of its content or tags holding a lone
        # surrogate has no UTF-8, which its hash needs: such an event does not check out.
        def valid_id?(value)
          event = fields(value)
          return false unless event.is_a?(Hash)
          return false unless Text.hex32?(event["id"]) && Text.hex32?(event["pubkey"]) && Text.hex64?(event["sig"])
          return false unless Json.safe_integer?(event["created_at"]) && Json.integer?(event["kind"])
          return false unless Text.well_formed?(event["content"]) && tags?(event["tags"])

          Text.hex(hash_of(event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"])) ==
            event["id"]
        end

        def tags?(tags)
          tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(Array) && tag.all? { |item| Text.well_formed?(item) } }
        end

        # The NIP-01 members of `value`, a relay's event that checked out, and nothing else: what a
        # relay adds to an event (its id and its signature cover none of it) is never kept (SPEC.md
        # §13, Limits).
        def nip01_members(value)
          value.slice("id", "pubkey", "created_at", "kind", "tags", "content", "sig")
        end

        # Whether the signature of `value`, whose id was checked, verifies (BIP-340).
        def signature_checks?(value)
          event = fields(value)
          Secp256k1.verify(Text.hex_bytes(event["sig"]), Text.hex_bytes(event["id"]), Text.hex_bytes(event["pubkey"]))
        end

        # Whether `value` is an event whose id and signature check out. Relays are never trusted.
        def valid?(value)
          valid_id?(value) && signature_checks?(value)
        end

        # The Event of a value whose id checked out (valid_id?).
        def from(value)
          return value if value.is_a?(Event)

          Event.new(id: value["id"], pubkey: value["pubkey"], created_at: value["created_at"].to_i,
                    kind: value["kind"].to_i, tags: value["tags"], content: value["content"], sig: value["sig"])
        end
      end
    end
  end
end
