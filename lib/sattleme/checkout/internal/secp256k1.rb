# frozen_string_literal: true

require "ffi"
require "securerandom"

module Sattleme
  module Checkout
    # libsecp256k1 (https://github.com/bitcoin-core/secp256k1, Bitcoin Core's) is not found, or
    # lacks a module the gem needs: raised when the gem is required, never by a call.
    class LibraryNotFound < LoadError; end

    module Internal
      # secp256k1 (SPEC.md §11, §12): BIP-340 signatures, x-only public keys and `lift_x`, and the
      # ECDH of NIP-44, from libsecp256k1, the library Bitcoin Core uses and audits, through FFI:
      # never a curve of this gem's own. The system's library (0.2.0 or later, with its ecdh,
      # extrakeys and schnorrsig modules, which its builds enable by default), or the one
      # SATTLEME_SECP256K1_LIBRARY names (a path).
      module Secp256k1
        extend FFI::Library

        # The environment variable that names the library's file, when it is not where the
        # system's dynamic loader finds it.
        LIBRARY_VARIABLE = "SATTLEME_SECP256K1_LIBRARY"
        # Its names: the development link first, then each release's soname (0.2.0 is .so.1, 0.8.0
        # .so.7), then Homebrew's prefixes, which macOS's loader does not search.
        NAMES = [
          "secp256k1",
          *8.downto(0).map { |version| "libsecp256k1.so.#{version}" },
          "/opt/homebrew/lib/libsecp256k1.dylib",
          "/usr/local/lib/libsecp256k1.dylib"
        ].freeze
        INSTALL = "install libsecp256k1 0.2.0 or later (Debian, Ubuntu: apt install " \
                  "libsecp256k1-dev; Fedora: dnf install libsecp256k1; Alpine: apk add " \
                  "libsecp256k1; macOS: brew install secp256k1), or name its file in " \
                  "#{LIBRARY_VARIABLE}".freeze

        begin
          path = ENV.fetch(LIBRARY_VARIABLE, "")
          ffi_lib(path.empty? ? NAMES : [path])
        rescue LoadError
          raise LibraryNotFound, "sattleme-checkout needs libsecp256k1: #{INSTALL}"
        end

        # SECP256K1_CONTEXT_NONE (secp256k1.h): every context can sign and verify since 0.2.0.
        CONTEXT_NONE = 1
        # The sizes of the library's opaque structures (secp256k1.h, secp256k1_extrakeys.h).
        PUBKEY_BYTES = 64
        KEYPAIR_BYTES = 96

        # The ECDH output function (secp256k1_ecdh.h): it gets the shared point's coordinates.
        callback :ecdh_hash, %i[pointer pointer pointer pointer], :int

        {
          "the library itself" => [
            [:secp256k1_context_create, [:uint], :pointer],
            [:secp256k1_context_randomize, %i[pointer pointer], :int],
            [:secp256k1_ec_seckey_verify, %i[pointer pointer], :int],
            [:secp256k1_ec_pubkey_parse, %i[pointer pointer pointer size_t], :int]
          ],
          "its extrakeys module" => [
            [:secp256k1_keypair_create, %i[pointer pointer pointer], :int],
            [:secp256k1_keypair_xonly_pub, %i[pointer pointer pointer pointer], :int],
            [:secp256k1_xonly_pubkey_parse, %i[pointer pointer pointer], :int],
            [:secp256k1_xonly_pubkey_serialize, %i[pointer pointer pointer], :int]
          ],
          "its schnorrsig module" => [
            [:secp256k1_schnorrsig_sign32, %i[pointer pointer pointer pointer pointer], :int],
            [:secp256k1_schnorrsig_verify, %i[pointer pointer pointer size_t pointer], :int]
          ],
          "its ecdh module" => [
            [:secp256k1_ecdh, %i[pointer pointer pointer pointer ecdh_hash pointer], :int]
          ]
        }.each do |part, functions|
          functions.each { |name, arguments, result| attach_function(name, arguments, result) }
        rescue FFI::NotFoundError
          raise LibraryNotFound, "sattleme-checkout needs libsecp256k1 with #{part} " \
                                 "(#{ffi_libraries.map(&:name).join(", ")} has not): #{INSTALL}"
        end

        # NIP-44's shared secret is the x coordinate of the ECDH point, unhashed: the library hashes
        # it by default, this output function copies it as it is.
        X_ONLY = FFI::Function.new(:int, %i[pointer pointer pointer pointer]) do |output, x, _y, _data|
          output.put_bytes(0, x.get_bytes(0, 32))
          1
        end

        # One context for every call: its API is thread-safe but for its randomization, done here
        # once (a blinding of the signing tables against side channels).
        CONTEXT = secp256k1_context_create(CONTEXT_NONE)
        raise LibraryNotFound, "libsecp256k1 made no context" if CONTEXT.null?

        FFI::MemoryPointer.new(:uchar, 32) do |seed|
          seed.put_bytes(0, SecureRandom.random_bytes(32))
          secp256k1_context_randomize(CONTEXT, seed)
          seed.clear
        end

        module_function

        # Whether `secret` (32 bytes) is a secret key: from 1 to the curve's order minus 1.
        def valid_secret?(secret)
          return false unless secret.is_a?(String) && secret.bytesize == 32

          with_bytes(secret) { |pointer| secp256k1_ec_seckey_verify(CONTEXT, pointer) == 1 }
        end

        # The x-only public key (32 bytes) of the secret key `secret` (BIP-340). Raises ArgumentError
        # for a value that is not a secret key.
        def public_key(secret)
          with_keypair(secret) do |keypair|
            FFI::MemoryPointer.new(:uchar, PUBKEY_BYTES) do |xonly|
              raise ArgumentError, "Invalid secret key" if secp256k1_keypair_xonly_pub(CONTEXT, xonly, nil,
                                                                                       keypair) != 1

              FFI::MemoryPointer.new(:uchar, 32) do |output|
                secp256k1_xonly_pubkey_serialize(CONTEXT, output, xonly)
                return output.get_bytes(0, 32)
              end
            end
          end
        end

        # Whether `x` (32 bytes) is the x coordinate of a point of the curve (BIP-340 `lift_x`).
        def xonly?(x)
          return false unless x.is_a?(String) && x.bytesize == 32

          FFI::MemoryPointer.new(:uchar, PUBKEY_BYTES) do |xonly|
            with_bytes(x) { |input| return secp256k1_xonly_pubkey_parse(CONTEXT, xonly, input) == 1 }
          end
        end

        # The BIP-340 signature (64 bytes) of `message` (32 bytes) by `secret`, with the 32 bytes
        # `aux` of auxiliary random data.
        def sign(message, secret, aux)
          raise ArgumentError, "A message of 32 bytes" unless message.bytesize == 32
          raise ArgumentError, "32 bytes of auxiliary data" unless aux.bytesize == 32

          with_keypair(secret) do |keypair|
            FFI::MemoryPointer.new(:uchar, 64) do |signature|
              with_bytes(message) do |digest|
                with_bytes(aux) do |random|
                  ok = secp256k1_schnorrsig_sign32(CONTEXT, signature, digest, keypair, random)
                  raise ArgumentError, "Signing failed" unless ok == 1
                end
              end
              return signature.get_bytes(0, 64)
            end
          end
        end

        # Whether `signature` (64 bytes) is a BIP-340 signature of `message` (32 bytes) by the
        # x-only public key `x` (32 bytes). False for anything malformed.
        def verify(signature, message, x)
          return false unless [signature, message, x].all?(String)
          return false unless signature.bytesize == 64 && message.bytesize == 32 && x.bytesize == 32

          Verifications.increment
          FFI::MemoryPointer.new(:uchar, PUBKEY_BYTES) do |xonly|
            with_bytes(x) { |input| return false unless secp256k1_xonly_pubkey_parse(CONTEXT, xonly, input) == 1 }
            with_bytes(signature) do |sig|
              with_bytes(message) do |digest|
                return secp256k1_schnorrsig_verify(CONTEXT, sig, digest, 32, xonly) == 1
              end
            end
          end
        end

        # The x coordinate (32 bytes) of the ECDH point of `secret` and the x-only public key `x`
        # (its even point: either has the same product's x), as NIP-44 v2 takes it. Constant time
        # in the secret (secp256k1_ecdh). Raises ArgumentError for an invalid key.
        def shared_x(secret, x)
          raise ArgumentError, "Invalid public key" unless x.is_a?(String) && x.bytesize == 32
          raise ArgumentError, "Invalid secret key" unless valid_secret?(secret)

          FFI::MemoryPointer.new(:uchar, PUBKEY_BYTES) do |point|
            with_bytes("\x02".b + x) do |input|
              raise ArgumentError, "Invalid public key" if secp256k1_ec_pubkey_parse(CONTEXT, point, input, 33) != 1
            end
            FFI::MemoryPointer.new(:uchar, 32) do |output|
              with_bytes(secret) do |scalar|
                raise ArgumentError, "Invalid secret key" if secp256k1_ecdh(CONTEXT, output, point, scalar, X_ONLY,
                                                                            nil) != 1
              end
              shared = output.get_bytes(0, 32)
              output.clear
              return shared
            end
          end
        end

        # `bytes` copied into memory of the library's, cleared once `block` returned.
        def with_bytes(bytes)
          FFI::MemoryPointer.new(:uchar, bytes.bytesize) do |pointer|
            pointer.put_bytes(0, bytes)
            return yield pointer
          ensure
            pointer.clear
          end
        end

        # The key pair of `secret`, cleared once `block` returned. ArgumentError for an invalid key.
        def with_keypair(secret)
          raise ArgumentError, "Invalid secret key" unless secret.is_a?(String) && secret.bytesize == 32

          FFI::MemoryPointer.new(:uchar, KEYPAIR_BYTES) do |keypair|
            with_bytes(secret) do |seckey|
              raise ArgumentError, "Invalid secret key" unless secp256k1_keypair_create(CONTEXT, keypair, seckey) == 1
            end
            return yield keypair
          ensure
            keypair.clear
          end
        end

        # How many signatures were verified: a test counts those a read checks (each costs a
        # fraction of a millisecond, and a relay decides how many records it sends).
        module Verifications
          @count = 0
          @mutex = Mutex.new

          class << self
            def increment
              @mutex.synchronize { @count += 1 }
            end

            def count
              @mutex.synchronize { @count }
            end
          end
        end
      end
    end
  end
end
