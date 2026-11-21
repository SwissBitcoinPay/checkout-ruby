# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # What an object holding a secret (SPEC.md §27: the integration key, a key derived from it,
      # the merchant's registry key, CoinGecko's key) shows of itself: its `inspect` alone, which
      # leaves the secret out, in `pp` too (whose default shows every member of a Data, every
      # instance variable of an object), and as its JSON (`as_json`, `to_json`: ActiveSupport's
      # default writes every instance variable of an object, every member of a Data, and Rails
      # writes what it logs or renders so); never serialized by Marshal, nor by YAML (Psych), which
      # write its fields otherwise.
      module Redacted
        def pretty_print(printer)
          printer.text(inspect)
        end

        def as_json(*)
          inspect
        end

        def to_json(*)
          Json.generate(as_json)
        end

        def marshal_dump
          raise TypeError, "#{self.class.name} holds a secret: it is never serialized"
        end

        def _dump(_level)
          raise TypeError, "#{self.class.name} holds a secret: it is never serialized"
        end

        def encode_with(coder)
          coder.scalar = inspect
        end
      end

      # Bytes that are a secret (SPEC.md §27): the integration key and the keys derived from it.
      # Never in an inspection, a string, a serialization (Marshal, YAML) nor a message.
      class Secret
        include Redacted

        def initialize(bytes)
          @bytes = bytes.b.freeze
          freeze
        end

        # The secret's bytes, for the cryptography that needs them.
        attr_reader :bytes

        def inspect
          "#<#{self.class.name} [redacted]>"
        end
        alias to_s inspect
      end

      # What an integration's secret key holds (SPEC.md §8): `sattleme_ck_<team>.<key>.<relays>`,
      # each part in canonical base64url without padding. The key stays on the integrator's server:
      # never in a web page, a repository nor a log.
      class IntegrationKey
        include Redacted

        # Hex: the team's public key (x only), the author of the integration's channel.
        attr_reader :team_public_key
        # Where its channel was published when the key was given (`wss://` addresses).
        attr_reader :relays

        # Reads an integration's secret key. Raises InvalidKeyError for anything else: another
        # prefix (a link holding its parts included), a part too many or missing, a part that is
        # not canonical base64url, a length other than 32 bytes, a team key off the curve, an
        # invalid relay list. The message never holds the key.
        def self.parse(value)
          text = Text.caller_text(value)
          raise InvalidKeyError unless text&.start_with?(Protocol::INTEGRATION_KEY_PREFIX)

          parts = text.delete_prefix(Protocol::INTEGRATION_KEY_PREFIX).split(".", -1)
          raise InvalidKeyError, "Integration key cut short" if parts.size < 3
          raise InvalidKeyError if parts.size > 3

          team = Base64.decode_url(parts[0])
          key = Base64.decode_url(parts[1])
          relays = Relays.decode_list(parts[2])
          unless team&.bytesize == Protocol::KEY_BYTES && key&.bytesize == Protocol::KEY_BYTES && relays
            raise InvalidKeyError, "Damaged integration key"
          end
          raise InvalidKeyError, "Damaged integration key" unless Secp256k1.xonly?(team)

          new(Text.hex(team), Secret.new(key), relays)
        end

        def initialize(team_public_key, key, relays)
          @team_public_key = team_public_key.freeze
          @key = key
          @relays = relays.dup.freeze
          freeze
        end

        # The integration's key (32 bytes). Never log it.
        def key
          @key.bytes
        end

        # Its public parts: the team and the relays, never the key.
        def to_h
          { "teamPublicKey" => team_public_key, "relays" => relays }
        end

        def inspect
          "#<#{self.class.name} team=#{team_public_key} relays=#{relays.inspect}>"
        end
        alias to_s inspect
      end
    end
  end
end
