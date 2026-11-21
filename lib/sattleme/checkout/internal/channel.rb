# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The integration's channel (SPEC.md §14): one record signed by the team, which the merchant's
      # app publishes on the account's relays and which only the integration's key opens. It gives
      # the merchant's Lightning address, registry and relays, or says that the integration was
      # removed.
      module Channels
        # The channel, as far as the server uses it. Active: the business's name, the Lightning
        # address (never shown to the integrator by the app: the gem never returns it either), the
        # registry, the account's relays when the channel names them (nil otherwise), the web app of
        # checkout links (nil when none or an invalid one), the merchant's tolerance (0 when none),
        # the merchant's Bitcoin node (BitcoinNodes::Node, nil when none or an invalid one), and the
        # record's `created_at`. Removed: `status` :removed and `updated_at`.
        Channel = Data.define(:status, :business_name, :lightning_address, :registry_key, :registry_reader, :relays,
                              :checkout_origin, :tolerance, :bitcoin_node, :updated_at) do
          # It holds the registry key.
          include Redacted

          def active? = status == :active

          def inspect = "#<Channel #{status} updated_at=#{updated_at}>"
          alias_method :to_s, :inspect
        end

        # What the relays of one list hold: :found (with the channel), :not_found (with whether a
        # copy of a newer format was seen), or :unreachable (fewer than a majority answered).
        Lookup = Data.define(:status, :channel, :newer) do
          def unreachable? = status == :unreachable
        end

        # The channel, active, and the relays it was read on.
        Read = Data.define(:channel, :relays)

        module_function

        # A channel's value, as the merchant's app reads it, for what the server uses: version 1,
        # `updatedAt` = `created_at`, then removed, or active with the role of an integration, the
        # business's name, a Lightning address, the registry and an optional valid relay list, the
        # web app of checkout links when it gives a valid one (an invalid one gives none, and leaves
        # the channel valid), the merchant's tolerance of on-chain underpayments (absent or invalid:
        # none, the channel valid), and the merchant's Bitcoin node (`bitcoinNode`, SPEC.md §31:
        # absent or invalid in any way, none, the server reads mempool.space, the channel valid; a
        # field a reader that does not know it ignores, no new version of the channel). The other
        # fields are the app's own and not read here, so that a change to them never stops a shop's
        # server. Raises Records::Newer for a newer version.
        def parse(value, created_at)
          return nil unless value.is_a?(Hash)

          version = value["version"]
          raise Records::Newer if Json.number?(version) && version > Protocol::CHANNEL_VERSION
          return nil unless version == Protocol::CHANNEL_VERSION && value["updatedAt"] == created_at
          return removed(created_at) if value["status"] == "removed"
          return nil unless value["status"] == "active" && value["role"] == "integration"

          profile = value["profile"]
          return nil unless profile.is_a?(Hash)

          business_name, lightning_address = profile.values_at("businessName", "lightningAddress")
          return nil unless CheckoutLinks.business_name?(business_name)
          return nil unless Lnurl.address_url(lightning_address)
          # The reading key must be a point of the curve: every declaration's inside is sealed to it.
          return nil unless Text.hex32?(value["registryKey"]) && Events.public_key?(value["registryReader"])

          relays = value.key?("relays") ? Relays.parse_list(value["relays"]) : nil
          return nil if value.key?("relays") && relays.nil?

          Channel.new(status: :active, business_name: business_name, lightning_address: lightning_address,
                      registry_key: value["registryKey"], registry_reader: value["registryReader"], relays: relays,
                      checkout_origin: CheckoutLinks.origin_of(value["checkout"]),
                      # Absent or invalid, none: the channel stays valid.
                      tolerance: Tolerance.of(value["onchainTolerance"]),
                      bitcoin_node: BitcoinNodes.of(value["bitcoinNode"]), updated_at: created_at)
        end

        def removed(created_at)
          Channel.new(status: :removed, business_name: nil, lightning_address: nil, registry_key: nil,
                      registry_reader: nil, relays: nil, checkout_origin: nil, tolerance: 0, bitcoin_node: nil,
                      updated_at: created_at)
        end

        # The newest copy of the integration's channel on `relays`, signed by its team: every relay
        # at once, read as soon as a majority of them answered (the app publishes the channel, and
        # its removal, on a majority of them: any two majorities share a relay). Raises only
        # Cancelled.
        def lookup(pool, key, relays, random:, logger:, stop:)
          address, encryption_key = Derive.channel_keys(key.key)
          team = key.team_public_key
          filter = { "kinds" => [Protocol::RECORD_KIND], "authors" => [team], "#d" => [address] }
          keep = Records.that_open { |_, author| author == team ? encryption_key : nil }
          # A relay that asks to authenticate (NIP-42) gets a key of this read alone.
          result = pool.query_relays(relays, filter, random.call(32), paged: false, stop: stop, keep: keep)
          return Lookup.new(status: :unreachable, channel: nil, newer: false) unless result.answered

          found = Records.newest(result.answers) do |value|
            Records.open(value, type: Protocol::CHANNEL_RECORD_TYPE, encryption_key: encryption_key, address: address,
                                author: team) { |channel, event| parse(channel, event.created_at) }
          end
          if found.newest_unreadable && found.newest_unreadable > (found.event&.created_at || -1)
            logger.warn("sattleme-checkout: the integration's channel has a newer format than this version " \
                        "reads; update the gem")
          end
          return Lookup.new(status: :found, channel: found.value, newer: false) if found.value

          Lookup.new(status: :not_found, channel: nil, newer: !found.newest_unreadable.nil?)
        end

        # The integration's channel, active, on the account's current relays: read on the key's
        # relays, then where the channel says the account moved (MAX_RELAY_MOVES at most), since only
        # the new list gets its later changes, its removal included. RevokedError when it is
        # removed, NetworkError when fewer than a majority of a list answered, ChannelNotFoundError
        # when a majority of the key's relays answered without it.
        def read(pool, key, random:, logger:, stop:)
          relays = key.relays
          found = lookup(pool, key, relays, random: random, logger: logger, stop: stop)
          raise NetworkError, "Fewer than a majority of the integration key's relays answered" if found.unreachable?
          raise ChannelNotFoundError.new(newer_format: found.newer) if found.status == :not_found

          channel = found.channel
          Protocol::MAX_RELAY_MOVES.times do
            break unless channel.active? && channel.relays && !Relays.same_list?(channel.relays, relays)

            following = channel.relays
            found = lookup(pool, key, following, random: random, logger: logger, stop: stop)
            raise NetworkError, "Fewer than a majority of the merchant's relays answered" if found.unreachable?
            # Not copied there (yet): the channel read so far stands, and the declarations still go to
            # the account's relays it names.
            break if found.status == :not_found

            channel = found.channel
            relays = following
          end
          raise RevokedError unless channel.active?

          Read.new(channel: channel, relays: relays)
        end

        # The merchant's relays, where declarations go: the channel's, else the key's.
        def merchant_relays(channel, key)
          channel.relays || key.relays
        end
      end
    end
  end
end
