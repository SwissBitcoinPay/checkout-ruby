# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Text rules every implementation applies alike (SPEC.md §6): lengths in Unicode code
      # points, trimming and case of ASCII only, strict UTF-8, lone surrogates refused. Ruby's own
      # `strip`, `downcase` and regular expressions follow other rules, or raise on a string whose
      # UTF-8 is broken (as a lone surrogate from Json.parse leaves it): every check here takes any
      # value and answers false for anything but a well-formed text.
      module Text
        UTF_8 = Encoding::UTF_8

        module_function

        # Whether `value` is a String of well-formed UTF-8: no invalid byte, no lone surrogate (US-ASCII,
        # which Ruby gives what it packs and prints, is UTF-8 too).
        def well_formed?(value)
          value.is_a?(String) && [UTF_8, Encoding::US_ASCII].include?(value.encoding) &&
            value.valid_encoding?
        end

        # A caller's String as well-formed UTF-8, whatever its encoding says: UTF-8 as it is,
        # US-ASCII (`42.to_s`, a variable of the environment under the C locale) or binary bytes
        # decoded strictly as UTF-8, any other encoding transcoded from it. Nil when it is no String,
        # or its bytes are not valid in its encoding (a lone surrogate included): never repaired.
        def caller_text(value)
          return nil unless value.is_a?(String)
          return (value.valid_encoding? ? value : nil) if value.encoding == UTF_8
          return decode_utf8(value) if [Encoding::US_ASCII, Encoding::BINARY].include?(value.encoding)
          return nil unless value.valid_encoding?

          value.encode(UTF_8)
        rescue EncodingError
          nil
        end

        # Whether `value` is a well-formed text that `pattern` matches.
        def match?(value, pattern)
          well_formed?(value) && value.match?(pattern)
        end

        # The text of UTF-8 `bytes`, decoded strictly (a byte order mark kept, as U+FEFF); nil when
        # they are not valid UTF-8 (never repaired).
        def decode_utf8(bytes)
          text = bytes.dup.force_encoding(UTF_8)
          text.valid_encoding? ? text : nil
        end

        # The UTF-8 bytes of a well-formed text.
        def utf8(text)
          text.b
        end

        # Unicode code points of a well-formed text.
        def code_point_length(text)
          text.length
        end

        # Bytes of a well-formed text in UTF-8.
        def utf8_length(text)
          text.bytesize
        end

        # A well-formed text with A–Z lowered to a–z, and nothing else changed.
        def ascii_lower(text)
          text.tr("A-Z", "a-z")
        end

        # A well-formed text without its leading and trailing ASCII whitespace (space, tab, line
        # feed, carriage return).
        def trim_ascii(text)
          text.sub(/\A[ \t\n\r]+/, "").sub(/[ \t\n\r]+\z/, "")
        end

        # Whether a well-formed text holds a C0 control character (U+0000 to U+001F) or DEL.
        def control_character?(text)
          text.match?(/[\x00-\x1F\x7F]/)
        end

        # Lowercase hex of 32 bytes.
        def hex32?(value)
          match?(value, /\A[0-9a-f]{64}\z/)
        end

        # Lowercase hex of 64 bytes.
        def hex64?(value)
          match?(value, /\A[0-9a-f]{128}\z/)
        end

        # The bytes of lowercase (or any case) hex text.
        def hex_bytes(text)
          [text].pack("H*")
        end

        # Lowercase hex of `bytes`.
        def hex(bytes)
          bytes.unpack1("H*").force_encoding(UTF_8)
        end
      end

      # Base64 (RFC 4648), as the merchant's app writes it (SPEC.md §2): decoding is strict, one
      # value has one spelling (the alphabet's characters only, padding exactly where §4 puts it,
      # unused trailing bits zero); anything else is refused (nil), never repaired.
      module Base64
        STANDARD = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}
        URL_SAFE = /\A[A-Za-z0-9_-]*\z/

        module_function

        # Standard base64 with "=" padding (RFC 4648 §4), as NIP-44 payloads use it.
        def encode(bytes)
          [bytes].pack("m0").force_encoding(Text::UTF_8)
        end

        # The bytes of padded standard base64 text, or nil when it is not canonical.
        def decode(text)
          return nil unless Text.match?(text, STANDARD)

          bytes = text.unpack1("m0")
          encode(bytes) == text ? bytes : nil
        rescue ArgumentError
          nil
        end

        # Base64url without padding (RFC 4648 §5).
        def encode_url(bytes)
          encode(bytes).tr("+/", "-_").delete("=")
        end

        # The bytes of unpadded base64url text, or nil when it is not canonical.
        def decode_url(text)
          return nil unless Text.match?(text, URL_SAFE) && text.length % 4 != 1

          padded = text.tr("-_", "+/") + ("=" * ((4 - (text.length % 4)) % 4))
          bytes = padded.unpack1("m0")
          encode_url(bytes) == text ? bytes : nil
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
