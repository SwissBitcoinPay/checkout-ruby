# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # NIP-44 version 2 (https://github.com/nostr-protocol/nips/blob/master/44.md, SPEC.md §12):
      # ChaCha20, HMAC-SHA256 over the nonce and the ciphertext, per-message keys from a random
      # 32-byte nonce, plaintexts padded. Checked against the official vectors. The conversation key
      # is a 32-byte HKDF output used as it is, but inside a registry declaration and a lease:
      # the ECDH conversation key.
      module Nip44
        VERSION = 2
        MIN_PLAINTEXT = 1
        MAX_PLAINTEXT = 0xFFFF

        # A payload of another version (empty, `#`…, or another version byte): a newer client's.
        class UnknownVersion < StandardError; end

        # A payload that is not a NIP-44 v2 encryption under this key.
        class Invalid < StandardError; end

        # A plaintext longer than NIP-44 v2 holds (65 535 bytes): an invoice too long to be declared.
        class TooLong < ArgumentError; end

        module_function

        # The conversation key of a secret key and an x-only public key (hex): the x coordinate of
        # their ECDH, through HKDF-extract with the salt "nip44-v2". ArgumentError for a key out of
        # range or off the curve.
        def conversation_key(secret, public_key)
          raise ArgumentError, "Invalid public key" unless Text.hex32?(public_key)

          shared = Secp256k1.shared_x(secret, Text.hex_bytes(public_key))
          Crypto.hkdf_extract("nip44-v2", shared)
        end

        # The padded length of a plaintext of `length` bytes (`calc_padded_len`).
        def padded_length(length)
          return 32 if length <= 32

          next_power = 1 << (length - 1).bit_length
          chunk = next_power <= 256 ? 32 : next_power / 8
          chunk * (((length - 1) / chunk) + 1)
        end

        # The ChaCha20 key and nonce and the HMAC key of one message (`get_message_keys`).
        def message_keys(conversation_key, nonce)
          raise ArgumentError, "Invalid conversation key" unless conversation_key.bytesize == 32
          raise ArgumentError, "Invalid nonce" unless nonce.bytesize == 32

          keys = Crypto.hkdf_expand(conversation_key, nonce, 76)
          [keys.byteslice(0, 32), keys.byteslice(32, 12), keys.byteslice(44, 32)]
        end

        # The payload of the well-formed text `text` under `conversation_key`, with a fresh nonce
        # of `random` (32 bytes).
        def encrypt(text, conversation_key, random)
          encrypt_with_nonce(text, conversation_key, random.call(32))
        end

        # Encryption with a given nonce: for the official vectors only.
        def encrypt_with_nonce(text, conversation_key, nonce)
          chacha_key, chacha_nonce, hmac_key = message_keys(conversation_key, nonce)
          ciphertext = Crypto.chacha20(chacha_key, chacha_nonce, pad(text))
          mac = Crypto.hmac(hmac_key, nonce + ciphertext)
          Base64.encode(VERSION.chr + nonce + ciphertext + mac)
        end

        # The text of a payload: UnknownVersion for another version, Invalid when it is malformed
        # or not sealed with `conversation_key`.
        def decrypt(payload, conversation_key)
          raise Invalid, "not a payload" unless payload.is_a?(String)
          raise UnknownVersion if payload.empty? || payload.start_with?("#")
          raise Invalid, "Invalid payload size" unless payload.length.between?(132, 87_472)

          data = Base64.decode(payload)
          raise Invalid, "Invalid payload" if data.nil? || !data.bytesize.between?(99, 65_603)
          raise UnknownVersion unless data.getbyte(0) == VERSION

          nonce = data.byteslice(1, 32)
          ciphertext = data.byteslice(33, data.bytesize - 65)
          chacha_key, chacha_nonce, hmac_key = message_keys(conversation_key, nonce)
          # Constant time: the comparison does not stop at the first byte that differs.
          unless Crypto.same?(Crypto.hmac(hmac_key, nonce + ciphertext), data.byteslice(-32, 32))
            raise Invalid, "Invalid MAC"
          end

          unpad(Crypto.chacha20(chacha_key, chacha_nonce, ciphertext))
        end

        def pad(text)
          bytes = text.b
          raise TooLong, "Plaintext longer than #{MAX_PLAINTEXT} bytes" if bytes.bytesize > MAX_PLAINTEXT
          raise ArgumentError, "Empty plaintext" if bytes.bytesize < MIN_PLAINTEXT

          padded = [bytes.bytesize].pack("n") + bytes
          padded + ("\x00".b * (2 + padded_length(bytes.bytesize) - padded.bytesize))
        end

        def unpad(padded)
          length = padded.byteslice(0, 2).unpack1("n")
          raise Invalid, "Invalid padding" if length < MIN_PLAINTEXT || padded.bytesize != 2 + padded_length(length)

          # Strict UTF-8: a byte order mark is kept, as U+FEFF (SPEC.md §2).
          text = Text.decode_utf8(padded.byteslice(2, length))
          raise Invalid, "Invalid UTF-8" if text.nil?

          text
        end
      end
    end
  end
end
