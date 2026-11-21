# frozen_string_literal: true

require "openssl"

module Sattleme
  module Checkout
    module Internal
      # SHA-256, HMAC-SHA256, HKDF-SHA256 (RFC 5869) and ChaCha20 (RFC 8439), from OpenSSL (Ruby's
      # standard library): SPEC.md §2, §10, §12.
      module Crypto
        module_function

        def sha256(data)
          OpenSSL::Digest.digest("SHA256", data)
        end

        def hmac(key, data)
          OpenSSL::HMAC.digest("SHA256", key, data)
        end

        # HKDF-SHA256 of `secret` with `salt` and `info` (texts, as their UTF-8), `length` bytes.
        def hkdf(secret, salt, info, length = 32)
          OpenSSL::KDF.hkdf(secret, salt: salt.b, info: info.b, length: length, hash: "SHA256")
        end

        # HKDF-Extract (RFC 5869 §2.2).
        def hkdf_extract(salt, secret)
          hmac(salt.b, secret)
        end

        # HKDF-Expand (RFC 5869 §2.3) of the pseudorandom key `prk`.
        def hkdf_expand(prk, info, length)
          out = "".b
          block = "".b
          counter = 1
          while out.bytesize < length
            block = hmac(prk, block + info.b + counter.chr)
            out << block
            counter += 1
          end
          out.byteslice(0, length)
        end

        # ChaCha20 of `data` with the 32-byte `key` and the 12-byte `nonce`, its block counter
        # from 0. OpenSSL's IV is the counter (32 bits, little-endian), then the nonce.
        def chacha20(key, nonce, data)
          cipher = OpenSSL::Cipher.new("chacha20")
          cipher.encrypt
          cipher.key = key
          cipher.iv = "\x00\x00\x00\x00".b + nonce
          return "".b if data.empty?

          cipher.update(data) + cipher.final
        end

        # Whether `a` and `b` are the same bytes, compared in constant time.
        def same?(a, b)
          a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
        end
      end
    end
  end
end
