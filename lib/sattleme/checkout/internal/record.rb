# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Sealed records, as the merchant's app writes and reads them (SPEC.md §12): one addressable
      # event of kind 30078 (NIP-78), an opaque `d` tag, NIP-44 v2 content whose plaintext
      # `{"t": <type>, "v": <value>}` is padded with spaces to a multiple of 256 bytes.
      module Records
        # A record of a newer format than this gem reads: ignored, never written over.
        class Newer < StandardError; end

        # A record opened: its event and value, or authentic but of a newer format (`newer`).
        Opened = Data.define(:status, :event, :value) do
          def ok? = status == :ok
          def newer? = status == :newer
        end

        # The newest of the records relays sent: its event and value (nil when none), and the
        # `created_at` of the newest copy of a newer format (nil when none).
        Newest = Data.define(:event, :value, :newest_unreadable)

        module_function

        # The signed event of a record: `value` (JSON) of `type`, sealed with `encryption_key`, at
        # `address` (its `d` tag, then `tags`), signed by `signer` at `created_at`. Encryption and
        # signature drawn from `random`.
        def seal(type:, value:, signer:, encryption_key:, address:, created_at:, random:, tags: [])
          text = Json.generate({ "t" => type, "v" => value })
          length = text.bytesize
          # Spaces after the JSON: whitespace when it is parsed.
          padded = text + (" " * ((-length) % Protocol::RECORD_BLOCK_BYTES))
          Events.sign(signer, random, created_at: created_at, kind: Protocol::RECORD_KIND,
                                      tags: [["d", address], *tags],
                                      content: Nip44.encrypt(padded, encryption_key, random))
        end

        # What a relay sent, if it is a record of `type` at `address` by `author` sealed with
        # `encryption_key`: kind, author, `d` tag, then a content that opens with the key and holds a
        # value of the type, then the signature; `parse` validates the value (nil when invalid; it
        # may raise Newer). Anything else is nil: a relay is never trusted.
        def open(value, type:, encryption_key:, address:, author:, &parse)
          claimed = Events.fields(value)
          return nil unless claimed.is_a?(Hash) && claimed["kind"] == Protocol::RECORD_KIND
          return nil unless claimed["pubkey"] == author && claimed["content"].is_a?(String)
          return nil unless tagged?(claimed["tags"], address)

          newer = false
          payload = nil
          begin
            payload = read_content(claimed["content"], type, encryption_key)
            return nil if payload.equal?(NONE)
          rescue Newer
            newer = true
          end
          return nil unless Events.valid?(claimed)

          event = Events.from(claimed)
          return Opened.new(status: :newer, event: event, value: nil) if newer

          begin
            parsed = parse.call(payload, event)
            parsed.nil? ? nil : Opened.new(status: :ok, event: event, value: parsed)
          rescue Newer
            Opened.new(status: :newer, event: event, value: nil)
          rescue StandardError
            # A value no check expected stops nothing: it is no record, as anything else a relay sends.
            nil
          end
        end

        # Whether `tags` (a relay's) hold the `d` tag `address`, as one of them.
        def tagged?(tags, address)
          tags.is_a?(Array) && tags.any? { |tag| tag.is_a?(Array) && tag[0] == "d" && tag[1] == address }
        end

        # What a record's content holds when it does not open, or holds another type.
        NONE = Object.new.freeze

        # The value inside a record's content; NONE when it does not open or is of another type.
        # Raises Newer for a content of a newer NIP-44 version.
        def read_content(content, type, encryption_key)
          begin
            text = Nip44.decrypt(content, encryption_key)
          rescue Nip44::UnknownVersion
            raise Newer
          rescue Nip44::Invalid
            return NONE
          end
          envelope = Json.parse_or(text, NONE)
          return NONE unless envelope.is_a?(Hash) && envelope.key?("v")

          envelope["t"] == type ? envelope["v"] : NONE
        end

        # What a read of sealed records keeps of each event (SPEC.md §13: the event, when it opens):
        # an event of kind 30078 whose content decrypts with the key `key_of` gives for its first `d`
        # tag (hex32, else nil) and its author (NIP-44 v2, its MAC checked), or is of a newer NIP-44
        # version, and that checks out (§11), its signature included: anybody may send a copy of a
        # record under an id of its own, its content and signature left as they are, and only the
        # signature tells it from the record. Checked once per id and signature, whatever relays
        # send copies. `key_of` gives nil for an author or an address the read does not open. Its
        # value is not checked here: the read opens what it keeps. Of the event, only its NIP-01
        # members are kept: a relay may add any to a record that checks out (its id and signature
        # cover none of it). Thread-safe: every relay's reader calls it.
        def that_open(&key_of)
          verified = {}
          mutex = Mutex.new
          lambda do |value|
            next nil unless value.is_a?(Hash) && value["kind"] == Protocol::RECORD_KIND
            next nil unless value["content"].is_a?(String) && value["pubkey"].is_a?(String)

            key = key_of.call(d_tag_of(value), value["pubkey"])
            next nil if key.nil?

            begin
              Nip44.decrypt(value["content"], key)
            rescue Nip44::UnknownVersion
              nil
            rescue Nip44::Invalid
              next nil
            end
            next nil unless Events.valid_id?(value)

            copy = "#{value["id"]}/#{value["sig"]}"
            valid = mutex.synchronize { verified[copy] }
            if valid.nil?
              valid = Events.signature_checks?(value)
              mutex.synchronize { verified[copy] = valid }
            end
            valid ? Events.nip01_members(value) : nil
          end
        end

        # The `d` tag of a value a relay sent, when it is hex32 (its first `d` tag); nil otherwise.
        def d_tag_of(value)
          tags = Events.fields(value).then { |fields| fields.is_a?(Hash) ? fields["tags"] : nil }
          return nil unless tags.is_a?(Array)

          tag = tags.find { |item| item.is_a?(Array) && item[0] == "d" }
          d = tag&.[](1)
          Text.hex32?(d) ? d : nil
        end

        # Whether `a` replaces `b` as relays keep them: a later `created_at`, then the lowest id.
        def replaces?(first, second)
          first.created_at > second.created_at ||
            (first.created_at == second.created_at && first.id < second.id)
        end

        # The newest record of what relays sent (`answers`: relay → values), each copy opened with
        # `open` once per event id that checked out (a copy with the id of one already checked is
        # the same event); the newest by `created_at` wins (on a tie, the lowest event id).
        def newest(answers, &open)
          checked = {}
          newest = nil
          newest_unreadable = nil
          answers.each_value do |events|
            events.each do |value|
              fields = Events.fields(value)
              next if fields.is_a?(Hash) && fields["id"].is_a?(String) && checked.key?(fields["id"])

              copy = open.call(value)
              next unless copy

              checked[copy.event.id] = true
              if copy.newer?
                newest_unreadable = [newest_unreadable || -1, copy.event.created_at].max
                next
              end
              newest = copy if newest.nil? || replaces?(copy.event, newest.event)
            end
          end
          Newest.new(event: newest&.event, value: newest&.value, newest_unreadable: newest_unreadable)
        end
      end
    end
  end
end
