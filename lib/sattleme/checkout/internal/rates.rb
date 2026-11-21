# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Amounts in a currency, converted to sats on the integrator's server at the rate of the
      # source it chooses (SPEC.md §25, §26). Exact integers end to end: the price of one bitcoin is
      # read as the exact decimal its source wrote, and the sats are rounded up to the next whole
      # sat: the merchant never receives less than the price.
      module Rates
        # An exact positive decimal: `units` × 10^-`scale`.
        Decimal = Data.define(:units, :scale)

        # A price of one bitcoin as a source gave it: a decimal string, and when it was set (Unix
        # seconds, nil when the source does not say).
        Quote = Data.define(:price, :time)

        # What a source may use: the HTTP context (the call's stop included) and CoinGecko's key.
        Context = Data.define(:http, :coingecko_api_key) do
          include Redacted

          def stop = http.stop

          def inspect = "#<Rates::Context>"
          alias_method :to_s, :inspect
        end

        DECIMAL = /\A([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z/
        FIAT_AMOUNT = /\A([0-9]{1,15})(?:\.([0-9]{1,15}))?\z/
        # The sources the gem knows, by name.
        NAMES = %w[coingecko mempool opennode coinbase kraken].freeze
        # The sources asked when the client is given none, in this order: the dated ones first
        # (their price's age is checked), CoinGecko for its currencies, then mempool.space for its
        # 7; then the undated ones, Coinbase and Kraken (two exchanges), and OpenNode.
        DEFAULT_SOURCES = %w[coingecko mempool coinbase kraken opennode].freeze
        # The currencies of mempool.space's `/api/v1/prices`.
        MEMPOOL_CURRENCIES = %w[USD EUR GBP CAD CHF AUD JPY].freeze
        # A member a source's answer does not hold.
        ABSENT = Object.new.freeze

        module_function

        # A price as an exact decimal: digits, an optional fraction and an optional exponent
        # (`"69025.1084416666694295"`, `"8e-8"`), 64 characters at most, an exponent of 64 at most
        # either way, nothing around it. Nil unless it is strictly positive.
        def parse_decimal(value)
          return nil unless Text.well_formed?(value) && value.length <= Protocol::MAX_PRICE_LENGTH

          match = DECIMAL.match(value)
          return nil unless match

          fraction = match[2] || ""
          exponent = (match[3] || "0").to_i
          return nil if exponent.abs > Protocol::MAX_PRICE_EXPONENT

          units = Integer(match[1] + fraction, 10)
          scale = fraction.length - exponent
          if scale.negative?
            units *= 10**-scale
            scale = 0
          end
          # The shortest exact writing: 69012.50 is 69012.5.
          while scale.positive? && (units % 10).zero?
            units /= 10
            scale -= 1
          end
          units.positive? ? Decimal.new(units: units, scale: scale) : nil
        end

        # The text of a JSON number a source answered: the shortest decimal that reads back as the
        # same double (ECMAScript's Number::toString). Nil when it is not a finite number.
        def number_text(value)
          return nil unless value.is_a?(Float) || value.is_a?(Integer)
          return nil if value.is_a?(Float) && !value.finite?

          Json.number_text(value.is_a?(Integer) ? value.to_f : value)
        end

        # The plain decimal writing of an exact decimal: `69012.5`, `0.00000008`.
        def format_decimal(decimal)
          return decimal.units.to_s if decimal.scale.zero?

          digits = decimal.units.to_s.rjust(decimal.scale + 1, "0")
          "#{digits[0...-decimal.scale]}.#{digits[-decimal.scale..]}"
        end

        # A price given as `{ amount: "24.50", currency: "CHF" }`, as integer minor units of its
        # currency: the currency an ISO 4217 code of the table (upper case); the amount a string of
        # digits with at most the currency's decimals (trailing zeros aside), nothing around it:
        # never a float, never rounded. Raises InvalidOrderError (`fiat`).
        def parse_fiat(fiat)
          raise InvalidOrderError.new("fiat", "expected { amount:, currency: }") unless fiat.is_a?(Hash)

          # Strings in any encoding, read as text (Text.caller_text): never repaired.
          currency = Text.caller_text(member(fiat, "currency"))
          amount = member(fiat, "amount")
          digits = Currencies.digits(currency)
          raise InvalidOrderError.new("fiat", "currency: an ISO 4217 code in upper case, as CHF") if digits.nil?
          unless amount.is_a?(String)
            raise InvalidOrderError.new("fiat", 'amount: a string of digits, as "24.50" (never a float)')
          end

          amount = Text.caller_text(amount)
          match = amount && FIAT_AMOUNT.match(amount)
          raise InvalidOrderError.new("fiat", 'amount: digits, as "24.50"') unless match

          fraction = (match[2] || "").sub(/0+\z/, "")
          if fraction.length > digits
            raise InvalidOrderError.new("fiat", "amount: #{currency} has #{digits} decimals at most")
          end

          padded = fraction.ljust(digits, "0")
          minor = (Integer(match[1], 10) * (10**digits)) + (padded.empty? ? 0 : Integer(padded, 10))
          unless minor.between?(1, Protocol::MAX_MINOR_UNITS)
            raise InvalidOrderError.new("fiat", "amount: more than 0, and not that large")
          end

          Fiat.new(amount: format_decimal(Decimal.new(units: minor, scale: digits)), currency: currency,
                   minor: minor.to_s, digits: digits)
        end

        # A member of a Hash given by the caller, by its name as a String or a Symbol.
        def member(hash, name)
          hash.key?(name) ? hash[name] : hash[name.to_sym]
        end

        # Sats for `minor` units of a currency with `digits` decimals, at `price` (one bitcoin in
        # that currency), rounded up to the next whole sat, on integers:
        # ⌈minor × 10^8 × 10^scale / (units × 10^digits)⌉.
        def minor_to_sats(minor, digits, price)
          dividend = minor * Protocol::SATS_PER_BTC * (10**price.scale)
          divisor = price.units * (10**digits)
          (dividend + divisor - 1) / divisor
        end

        # Sats for a price in a currency at the price of one bitcoin (a decimal string): exact,
        # rounded up. InvalidOrderError for an invalid price in a currency, RateError for an
        # invalid price of one bitcoin.
        def fiat_to_sats(fiat, price)
          parsed = parse_fiat(fiat)
          decimal = parse_decimal(price)
          raise RateError, "A price must be a decimal string above 0" unless decimal

          minor_to_sats(Integer(parsed.minor, 10), parsed.digits, decimal)
        end

        # A rate source as the gem keeps it: a name it knows (a String, or a Symbol of that name), as
        # a String, or a callable of the integrator's (a custom source); nil for anything else (a
        # name in another case, `custom`, a list).
        def source_of(value)
          if value.is_a?(String) || value.is_a?(Symbol)
            name = Text.caller_text(value.to_s)
            NAMES.include?(name) ? name.dup.freeze : nil
          elsif value.respond_to?(:call) && !value.is_a?(Array)
            value
          end
        end

        # The sources `value` names, in the order they are asked: a source alone, or a non-empty
        # list of sources without the same name twice (and no list inside it). Nil when it is
        # neither.
        def source_list(value)
          single = source_of(value)
          return [single].freeze if single
          return nil unless value.is_a?(Array) && !value.empty?

          list = value.map { |source| source_of(source) }
          return nil if list.include?(nil)

          names = list.grep(String)
          names.uniq.size == names.size ? list.freeze : nil
        end

        def source_name(source)
          source.is_a?(String) ? source : "custom"
        end

        # The price of one bitcoin in `currency` from `source`, checked: an exact positive decimal,
        # not older than an hour, not further ahead than 5 minutes. Undated sources cannot be
        # checked for age. UnsupportedCurrencyError when the source has no price in the currency,
        # NetworkError when it does not answer, RateError for anything else. [price, RateInfo].
        def fetch_rate(source, currency, context, now)
          name = source_name(source)
          quote = if source.is_a?(String)
                    named_quote(source, currency, context)
                  else
                    custom_quote(source, currency, context)
                  end
          price = parse_decimal(quote.price)
          raise RateError, "#{name} gave no valid price in #{currency}" unless price

          time = quote.time
          unless time.nil?
            if !Json.safe_integer?(time) || time > now + Protocol::CLOCK_TOLERANCE_SECONDS
              raise RateError, "#{name} gave an invalid date for its price"
            end
            raise RateError, "#{name}'s price in #{currency} is too old" if now - time > Protocol::MAX_RATE_AGE_SECONDS

            time = time.to_i
          end
          [price,
           RateInfo.new(source: name, currency: currency, price: format_decimal(price), fetched_at: now, time: time)]
        end

        # The first usable price of `sources`, asked one at a time in their order (SPEC.md §26):
        # the next source only when the previous one gives no usable price (NetworkError, RateError
        # or UnsupportedCurrencyError, each logged but the last). A cancellation, or any other error
        # a custom source raises, stops the list. With no price: UnsupportedCurrencyError when no
        # source has the currency, else the last NetworkError or RateError.
        def fetch_first_rate(sources, currency, context, now, logger, ask: method(:fetch_rate))
          failure = nil
          unsupported = nil
          sources.each_with_index do |source, index|
            return ask.call(source, currency, context, now.call)
          rescue UnsupportedCurrencyError, NetworkError, RateError => e
            context.stop.check!
            e.is_a?(UnsupportedCurrencyError) ? unsupported = e : failure = e
            following = sources[index + 1]
            unless following.nil?
              logger.warn("Rate source #{source_name(source)} failed (#{e.code}): #{e.message}; " \
                          "trying #{source_name(following)}")
            end
          end
          raise failure if failure

          if sources.size > 1
            names = sources.map { |source| source_name(source) }.join(", ")
            raise UnsupportedCurrencyError.new(currency, names, "None of #{names} has a price in #{currency}")
          end
          raise unsupported
        end

        # A custom source's quote: it takes the currency (and, when it takes two arguments, a
        # Cancellation, cancelled with the call's or once the call no longer needs the price: the
        # call waits for the source to return) and gives a decimal string or `{ price:, time: }`,
        # never a number. An error of the gem it raises goes through as it is; any other becomes a
        # RateError (its `cause`).
        def custom_quote(source, currency, context)
          answer = begin
            arity = source.respond_to?(:arity) ? source.arity : source.method(:call).arity
            arity == 1 ? source.call(currency) : context.stop.as_cancellation { |given| source.call(currency, given) }
          rescue Error, Cancelled
            context.stop.check!
            raise
          rescue StandardError
            context.stop.check!
            raise RateError, "The custom rate source failed"
          end
          context.stop.check!
          return Quote.new(price: answer, time: nil) if answer.is_a?(String)
          raise RateError, "The custom rate source gave no price" unless answer.is_a?(Hash)

          time = member(answer, "time")
          Quote.new(price: member(answer, "price"), time: time)
        end

        def named_quote(name, currency, context)
          case name
          when "coingecko" then coingecko(currency, context)
          when "mempool" then mempool(currency, context)
          when "opennode" then opennode(currency, context)
          when "coinbase" then coinbase(currency, context)
          when "kraken" then kraken(currency, context)
          else raise RateError, "No rate source named #{name}"
          end
        end

        # A source's JSON object: NetworkError without an answer (5xx, 408, 429), RateError for any
        # other status or a body that is not a JSON object.
        def source_json(name, url, context, headers = {})
          answer = Http.get_json(url, context.http, headers)
          unless answer.ok?
            status = answer.status
            # Only 5xx (500 to 599), 408 and 429 say "try again" (a redirect never comes here: §15).
            again = status.between?(500, 599) || [408, 429].include?(status)
            raise NetworkError, "#{name} answered HTTP #{status}" if again

            raise RateError, "#{name} answered HTTP #{status}"
          end
          raise RateError, "#{name} gave no JSON object" unless answer.body.is_a?(Hash)

          answer.body
        end

        def object_at(value, name)
          raise RateError, "#{name}: unexpected answer" unless value.is_a?(Hash)

          value
        end

        # A member of a source's JSON object, or ABSENT.
        def at(object, name)
          object.key?(name) ? object[name] : ABSENT
        end

        # A source's price: a string as written, a JSON number as its shortest decimal.
        def price_of(value, name, currency)
          raise UnsupportedCurrencyError.new(currency, name) if value.equal?(ABSENT)

          text = value.is_a?(String) ? value : number_text(value)
          raise RateError, "#{name}: unexpected price" if text.nil?

          text
        end

        # CoinGecko (`/simple/price`, dated with `include_last_updated_at`); with the Demo key, its
        # header, sent to CoinGecko only.
        def coingecko(currency, context)
          code = Text.ascii_lower(currency)
          url = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=#{code}" \
                "&include_last_updated_at=true"
          headers = context.coingecko_api_key ? { "x-cg-demo-api-key" => context.coingecko_api_key } : {}
          bitcoin = object_at(at(source_json("coingecko", url, context, headers), "bitcoin"), "coingecko")
          time = at(bitcoin, "last_updated_at")
          Quote.new(price: price_of(at(bitcoin, code), "coingecko", currency), time: Json.number?(time) ? time : nil)
        end

        # mempool.space (`/api/v1/prices`, dated): 7 currencies.
        def mempool(currency, context)
          raise UnsupportedCurrencyError.new(currency, "mempool") unless MEMPOOL_CURRENCIES.include?(currency)

          body = source_json("mempool", "https://mempool.space/api/v1/prices", context)
          time = at(body, "time")
          raise RateError, "mempool: no time" unless Json.number?(time)

          Quote.new(price: price_of(at(body, currency), "mempool", currency), time: time)
        end

        # OpenNode (`/v1/rates`): some 140 currencies, undated.
        def opennode(currency, context)
          data = object_at(at(source_json("opennode", "https://api.opennode.com/v1/rates", context), "data"),
                           "opennode")
          pair = at(data, "BTC#{currency}")
          raise UnsupportedCurrencyError.new(currency, "opennode") if pair.equal?(ABSENT)

          Quote.new(price: price_of(at(object_at(pair, "opennode"), currency), "opennode", currency), time: nil)
        end

        # Coinbase (`/v2/exchange-rates?currency=BTC`): prices as decimal strings, read as written.
        def coinbase(currency, context)
          body = source_json("coinbase", "https://api.coinbase.com/v2/exchange-rates?currency=BTC", context)
          data = object_at(at(body, "data"), "coinbase")
          raise RateError, "coinbase: not the rates of BTC" unless at(data, "currency") == "BTC"

          rates = object_at(at(data, "rates"), "coinbase")
          Quote.new(price: price_of(at(rates, currency), "coinbase", currency), time: nil)
        end

        # Kraken (`/0/public/Ticker?pair=XBT<currency>`): the last trade's price (`c[0]`). The
        # result's key is not always the pair asked (XBTUSD gives XXBTZUSD): its only entry is read.
        def kraken(currency, context)
          body = source_json("kraken", "https://api.kraken.com/0/public/Ticker?pair=XBT#{currency}", context)
          errors = at(body, "error")
          raise RateError, "kraken: unexpected answer" unless errors.is_a?(Array)
          if errors.any? { |error| Text.well_formed?(error) && error.start_with?("EQuery:Unknown asset pair") }
            raise UnsupportedCurrencyError.new(currency, "kraken")
          end
          unless errors.empty?
            raise RateError, "kraken: #{Text.well_formed?(errors[0]) ? errors[0] : "an error"}"
          end

          entries = object_at(at(body, "result"), "kraken").values
          raise RateError, "kraken: unexpected answer" unless entries.size == 1

          last = at(object_at(entries[0], "kraken"), "c")
          raise RateError, "kraken: unexpected answer" unless last.is_a?(Array)

          Quote.new(price: price_of(last.empty? ? ABSENT : last[0], "kraken", currency), time: nil)
        end
      end
    end
  end
end
