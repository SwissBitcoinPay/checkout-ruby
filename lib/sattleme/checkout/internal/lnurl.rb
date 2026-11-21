# frozen_string_literal: true

require "uri"

module Sattleme
  module Checkout
    module Internal
      # The merchant's Lightning address (LUD-16, LUD-06, LUD-12, LUD-21; SPEC.md §16, §18, §22):
      # plain HTTPS requests to the merchant's LNURL server (breez.tips), which makes invoices for
      # the merchant's wallet even while it is offline.
      module Lnurl
        LIGHTNING_ADDRESS = /\A([a-z0-9\-_.+]+)@([a-z0-9-]+(?:\.[a-z0-9-]+)+)\z/

        # The LNURL-pay parameters of the merchant's Lightning address: its callback (an https URL),
        # its bounds in millisatoshis, its metadata (the invoices' description hash is its SHA-256)
        # and the longest comment it takes (LUD-12, 0 when none).
        PayRequest = Data.define(:callback, :min_sendable_msat, :max_sendable_msat, :metadata, :comment_allowed) do
          # Whole sats the Lightning address accepts: its bounds rounded inwards (the minimum up,
          # the maximum down), so that a whole-sat amount within them is within the service's.
          def sendable_sats
            [(min_sendable_msat + 999) / 1000, max_sendable_msat / 1000]
          end

          # The description hash of its invoices (hex): SHA-256 of the UTF-8 of its metadata.
          def description_hash
            Text.hex(Crypto.sha256(Text.utf8(metadata)))
          end
        end

        # What the Lightning address answered: an invoice and its LUD-21 verify URL, not checked.
        InvoiceAnswer = Data.define(:pr, :verify)

        # What the Lightning part of a payment check needs of an invoice.
        LightningInvoice = Data.define(:bolt11, :payment_hash, :verify_url, :expires_at)

        # The Lightning part of an invoice's payment: "open", "expired", or "paid" with its preimage.
        Part = Data.define(:state, :preimage) do
          def self.open = new(state: "open", preimage: nil)
          def self.expired = new(state: "expired", preimage: nil)
          def self.paid(preimage) = new(state: "paid", preimage: preimage)
          def paid? = state == "paid"
          def open? = state == "open"
          def expired? = state == "expired"
        end

        module_function

        # LUD-16: the LNURL-pay endpoint of a Lightning address (ASCII whitespace around it removed,
        # ASCII letters lowered, as the app reads it), or nil when it is not one. The endpoint is an
        # https URL (SPEC.md §16): its domain is never an IP address, nor `localhost`.
        def address_url(address)
          return nil unless Text.well_formed?(address)

          match = LIGHTNING_ADDRESS.match(Text.ascii_lower(Text.trim_ascii(address)))
          return nil unless match

          url = "https://#{match[2]}/.well-known/lnurlp/#{match[1]}"
          Urls.https_url(url) ? url : nil
        end

        # An LNURL error answer (LUD-06): `{"status": "ERROR", "reason": …}`, `ERROR` in any case.
        def service_error?(body)
          body.is_a?(Hash) && Text.well_formed?(body["status"]) && Text.ascii_lower(body["status"]) == "error"
        end

        # An LNURL answer (SPEC.md §16): [:json, object], or [:refusal, reason] for the service's
        # refusal sent with a 2xx or a client error status but 408 and 429. Anything else, or no
        # JSON object, is no answer: NetworkError.
        def get(url, http)
          answer = Http.get_json(url, http)
          status = answer.status
          refusal_status = status.between?(400, 499) && status != 408 && status != 429
          if (answer.ok? || refusal_status) && service_error?(answer.body)
            reason = answer.body["reason"]
            return [:refusal, reason.is_a?(String) ? reason : ""]
          end
          unless answer.ok? && answer.body.is_a?(Hash)
            raise NetworkError, "#{Urls.host_of(url)} answered HTTP #{status} without an LNURL answer"
          end

          [:json, answer.body]
        end

        # Millisatoshis of a JSON number: a non-negative safe integer, else nil.
        def msat(value)
          Json.safe_integer?(value) && value >= 0 ? value.to_i : nil
        end

        # The pay request of the Lightning address (LUD-16): a refusal is no answer (NetworkError);
        # an answer that is not a pay request is InvalidInvoiceError.
        def pay_request(address, http)
          url = address_url(address)
          raise InvalidInvoiceError, "The merchant's Lightning address is invalid" unless url

          kind, json = get(url, http)
          raise NetworkError, "#{Urls.host_of(url)} refused the Lightning address: #{json}" if kind == :refusal

          callback = json["callback"]
          min = msat(json["minSendable"])
          max = msat(json["maxSendable"])
          unless json["tag"] == "payRequest" && Urls.https_url(callback) && min && max && min <= max &&
                 Text.well_formed?(json["metadata"])
            raise InvalidInvoiceError, "#{Urls.host_of(url)} gave no valid LNURL-pay request"
          end

          comment_allowed = json["commentAllowed"]
          comment_allowed = Json.safe_integer?(comment_allowed) ? [comment_allowed.to_i, 0].max : 0
          PayRequest.new(callback: callback, min_sendable_msat: min, max_sendable_msat: max,
                         metadata: json["metadata"], comment_allowed: comment_allowed)
        end

        # The callback's URL for an invoice (SPEC.md §17, step 5): its fragment (from its first `#`)
        # dropped, since the parameters added after it would never reach the server, and
        # `parameters` set as URLSearchParams#set sets them: the callback's first pair of a name
        # takes its value, its other pairs of that name are removed, a name it lacks is added at the
        # end; its other pairs are kept as written. Values are form-urlencoded.
        def callback_url(callback, parameters)
          path, query = callback.sub(/#.*\z/m, "").split("?", 2)
          placed = {}
          pairs = (query || "").split("&", -1).filter_map do |pair|
            name = form_name(pair)
            if parameters.key?(name)
              next if placed[name]

              placed[name] = true
              form_pair(name, parameters[name])
            elsif !pair.empty?
              pair
            end
          end
          parameters.each { |name, value| pairs << form_pair(name, value) unless placed[name] }
          "#{path}?#{pairs.join("&")}"
        end

        # The name of a query's pair, form-decoded (`+` a space, `%XX` its byte); nil when it does
        # not decode to UTF-8, as no parameter set is named so.
        def form_name(pair)
          name = URI.decode_www_form_component(pair.split("=", 2)[0])
          name.valid_encoding? ? name : nil
        rescue ArgumentError
          nil
        end

        def form_pair(name, value)
          "#{URI.encode_www_form_component(name)}=#{URI.encode_www_form_component(value)}"
        end

        # Asks the Lightning address for an invoice of `sats` (LUD-06): `amount` in millisatoshis,
        # `expiry` in seconds, and `comment` only when its UTF-8 fits `comment_allowed` (LUD-12
        # does not say how a comment's length counts: bytes are never fewer than characters). The
        # answer is not checked: check_invoice does.
        def request_invoice(pay, sats:, expiry_seconds:, comment:, http:)
          parameters = { "amount" => (sats * 1000).to_s, "expiry" => expiry_seconds.to_s }
          if comment && !comment.empty? && Text.utf8_length(comment) <= pay.comment_allowed
            parameters["comment"] = comment
          end
          kind, json = get(callback_url(pay.callback, parameters), http)
          raise NetworkError, "The Lightning address refused the invoice: #{json}" if kind == :refusal

          pr = json["pr"]
          verify = json["verify"]
          unless pr.is_a?(String) && verify.is_a?(String)
            raise InvalidInvoiceError, "The Lightning address gave no invoice or no verify URL (LUD-21)"
          end

          InvoiceAnswer.new(pr: pr, verify: verify)
        end

        # Checks an invoice before it is declared or shown (SPEC.md §18): Bitcoin mainnet, exactly
        # `sats`, the merchant's description hash (breez.tips serves the invoices of all its users),
        # a verify URL in https on the callback's host, an expiry no longer than asked, a date
        # within 5 minutes of the clock, time left before its end. InvalidInvoiceError naming the
        # first check failed. The decoded invoice.
        def check_invoice(answer, pay:, sats:, duration_seconds:, now:)
          decoded = Text.well_formed?(answer.pr) ? Bolt11.decode(answer.pr) : nil
          raise InvalidInvoiceError, "Not a BOLT11 invoice" unless decoded
          raise InvalidInvoiceError, "Not a Bitcoin mainnet invoice" unless decoded.network == "bc"
          unless decoded.amount_msat == sats * 1000
            raise InvalidInvoiceError,
                  "The invoice's amount differs from the order's"
          end
          unless decoded.description_hash == pay.description_hash
            raise InvalidInvoiceError, "The invoice does not pay the merchant's Lightning address"
          end

          verify = Urls.https_url(answer.verify)
          unless verify && Urls.same_host?(verify, Urls.https_url(pay.callback))
            raise InvalidInvoiceError, "No verify URL (LUD-21) on the Lightning address's host"
          end
          raise InvalidInvoiceError, "The invoice lasts longer than asked" if decoded.expiry_seconds > duration_seconds
          raise InvalidInvoiceError, "The invoice has no time left" if decoded.expiry_seconds <= 0
          if (decoded.timestamp - now).abs > Protocol::CLOCK_TOLERANCE_SECONDS
            raise InvalidInvoiceError, "The invoice's date is too far from this server's clock"
          end
          # Dated up to 5 minutes back, a short invoice may already be over: never declared nor shown.
          raise InvalidInvoiceError, "The invoice has no time left" if decoded.expires_at <= now

          decoded
        end

        # The Lightning part of an invoice's payment (LUD-21, SPEC.md §22), checked: the verify
        # answer names this very invoice (`pr`, whatever the case of its ASCII letters), `settled`
        # is true and the preimage's SHA-256 is the payment hash. After the invoice's end and its
        # grace period, "not settled" and "Not found" are final (`expired`); before, any refusal of
        # the service keeps it `open`. NetworkError when the service gives no answer (or another
        # refusal past the grace), InvalidInvoiceError when its answer is about another invoice or
        # its preimage is wrong.
        def verify_payment(invoice, http, now)
          final = now >= invoice.expires_at + Protocol::GRACE_SECONDS
          kind, json = get(invoice.verify_url, http)
          if kind == :refusal
            return Part.open unless final
            return Part.expired if json == Protocol::NOT_FOUND_REASON

            raise NetworkError, "The payment check was refused: #{json}"
          end
          pr = json["pr"]
          raise InvalidInvoiceError, "The payment check names no invoice (LUD-21 pr)" unless pr.is_a?(String)
          # BOLT11 is case-insensitive (bech32): the same invoice may be written in upper case.
          unless Text.well_formed?(pr) && Text.ascii_lower(pr) == Text.ascii_lower(invoice.bolt11)
            raise InvalidInvoiceError, "The payment check is about another invoice"
          end
          return final ? Part.expired : Part.open unless json["settled"] == true

          preimage = json["preimage"]
          raise InvalidInvoiceError, "Paid without a valid preimage" unless Text.match?(preimage, /\A[0-9a-fA-F]{64}\z/)

          proof = Text.ascii_lower(preimage)
          unless Text.hex(Crypto.sha256(Text.hex_bytes(proof))) == invoice.payment_hash
            raise InvalidInvoiceError, "The preimage does not match the payment hash"
          end

          Part.paid(proof)
        end
      end
    end
  end
end
