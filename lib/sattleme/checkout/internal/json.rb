# frozen_string_literal: true

require "strscan"

module Sattleme
  module Checkout
    module Internal
      # JSON as every implementation reads and writes it (SPEC.md §2): as JavaScript does, not as
      # Ruby's `json` does.
      #
      # Reading (RFC 8259, nothing else): of members with one name, the last counts; every number is
      # its IEEE 754 double (a Float), whatever its spelling, so that `500`, `500.0` and `5e2` are
      # one value and a large integer loses what a double cannot hold, as in JavaScript; a string
      # escape of a lone surrogate (`"\ud800"`) is kept, as JavaScript keeps it: as the three bytes
      # that would encode it (WTF-8), which leave the string's UTF-8 invalid, so that a check of a
      # text (Text.well_formed?) refuses it, while the rest of the document reads (Ruby's `json`
      # refuses the whole document). Whitespace is space, tab, line feed and carriage return: a byte
      # order mark is not JSON. A text in which more than MAX_DEPTH arrays and objects nest, one in
      # another, is not JSON (a bound every platform's parser keeps): a scan tells it before the
      # text is read, the same in every implementation. A member's name is any string, U+0000 in it
      # too.
      #
      # Writing: compact, as `JSON.stringify` writes it (its escapes, numbers as JavaScript prints
      # them, names in the order given).
      module Json
        # Not JSON.
        class Invalid < StandardError; end

        # A JSON text written as it is (tests write escapes no Ruby string holds).
        Raw = Struct.new(:text)

        UTF_8 = Encoding::UTF_8
        WHITESPACE = /[ \t\n\r]*/
        NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/
        STRING = %r{"((?:[^"\\\x00-\x1F]++|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*+)"}
        ESCAPE = %r{\\(?:u[0-9a-fA-F]{4}|["\\/bfnrt])}
        # The bytes each escape of a string stands for: a short escape's character; a \u escape's
        # code unit as UTF-8 would encode it, a surrogate's too (WTF-8: SURROGATE_PAIR then joins a
        # pair, a lone one stays as JavaScript keeps it).
        UNESCAPED = Hash.new { |_, escape| Json.wtf8(escape.byteslice(2, 4).to_i(16)) }.update(
          { '\\"' => '"', "\\\\" => "\\", "\\/" => "/", "\\b" => "\b", "\\f" => "\f", "\\n" => "\n", "\\r" => "\r",
            "\\t" => "\t" }.to_h { |escape, char| [escape.b, char.b] }
        ).freeze
        # A high surrogate then a low one, each as Json.wtf8 encodes it: one code point.
        SURROGATE_PAIR = /\xED([\xA0-\xAF])([\x80-\xBF])\xED([\xB0-\xBF])([\x80-\xBF])/n
        # The first byte of a surrogate as Json.wtf8 encodes it (of U+D000 to U+D7FF in UTF-8 too).
        SURROGATE_LEAD = "\xED".b.freeze
        # The largest integer every JSON reader holds exactly: 2^53 − 1.
        MAX_SAFE_INTEGER = (2**53) - 1
        # The most arrays and objects that nest, one in another, in a JSON text (SPEC.md §2).
        MAX_DEPTH = 64
        # The most significant digits a number's double needs: a halfway point between two doubles
        # has at most 767, so those after 800 count only by whether one of them is not zero (as
        # V8 reads them).
        MAX_DIGITS = 800
        NONZERO_DIGIT = /[1-9]/
        # What the depth scan stops at: a bracket, or a string's quote.
        DEPTH_MARK = /[\[\]{}"]/
        # The rest of a string, its closing quote included (a backslash escapes the next character).
        STRING_REST = /(?:[^"\\]++|\\.)*+"/m

        module_function

        # The value of the JSON text `text` (a UTF-8 String); Invalid when it is not JSON.
        def parse(text)
          raise Invalid, "not a string" unless text.is_a?(String)

          text = text.dup.force_encoding(UTF_8) unless text.encoding == UTF_8
          raise Invalid, "not UTF-8" unless text.valid_encoding?
          raise Invalid, "more than #{MAX_DEPTH} arrays and objects nest" if too_deep?(text)

          Parser.new(text).parse
        end

        # Whether more than MAX_DEPTH arrays and objects nest in `text`, outside its strings: each
        # `[` or `{` one deeper, each `]` or `}` one less, as every implementation counts them.
        def too_deep?(text)
          scanner = StringScanner.new(text)
          depth = 0
          while scanner.skip_until(DEPTH_MARK)
            case scanner.matched
            when '"'
              # A string not closed holds the rest of the text.
              return false unless scanner.skip(STRING_REST)
            when "[", "{"
              depth += 1
              return true if depth > MAX_DEPTH
            else
              depth -= 1
            end
          end
          false
        end

        # The value of `text`, or `fallback` when it is not JSON.
        def parse_or(text, fallback = nil)
          parse(text)
        rescue Invalid
          fallback
        end

        # The compact JSON text of `value` (Hash, Array, String, Integer, Float, true, false, nil,
        # Raw), as `JSON.stringify` writes it.
        def generate(value)
          out = +""
          write(value, out)
          out
        end

        # Whether `value` is a JSON number (a boolean never is).
        def number?(value)
          value.is_a?(Float) || value.is_a?(Integer)
        end

        # Whether `value` is a number whose value is an integer (JavaScript's Number.isInteger).
        def integer?(value)
          value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.truncate)
        end

        # Whether `value` is an integer of at most 2^53 − 1 either way (Number.isSafeInteger).
        def safe_integer?(value)
          integer?(value) && value.abs <= MAX_SAFE_INTEGER
        end

        # The Integer of a safe integer, else nil.
        def safe_integer(value)
          safe_integer?(value) ? value.to_i : nil
        end

        # A JSON object: a Hash (never null, never an array).
        def object?(value)
          value.is_a?(Hash)
        end

        # Whether the object `hash` holds `name`, as null: absent is not null (JavaScript's
        # `undefined`), wherever a record reads null as a value.
        def null_member?(hash, name)
          hash.key?(name) && hash[name].nil?
        end

        # The IEEE 754 double nearest the JSON number `text` (correctly rounded, ties to even), as
        # JavaScript reads it, whatever its length: beyond the doubles' range, an infinity or a zero,
        # never an error. Its significant digits are taken once, without the zeros around them, at
        # most MAX_DIGITS of them: Ruby's own conversion misreads a text of some 20 000 digits or
        # more, its zeros included ("1" and 20 000 zeros "e-20000" is 10.0 there). An exponent of
        # more than 18 digits is beyond every range. So the time it takes is linear in its length.
        def double(text)
          match = /\A(-)?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?\z/.match(text)
          raise Invalid, "not a number" unless match

          negative = !match[1].nil?
          fraction = match[3] || ""
          written = match[2] + fraction
          first = written.index(NONZERO_DIGIT)
          # A zero, of the number's sign.
          return (negative ? -1.0 : 1.0) * 0.0 if first.nil?

          last = written.rindex(NONZERO_DIGIT)
          digits = written[first..last]
          # The power of ten of the last significant digit.
          exponent = exponent_of(match[4], match[5]) - fraction.length + (written.length - 1 - last)
          if digits.length > MAX_DIGITS
            # Its last digit is not zero: the digits cut count as one more that is not either.
            exponent += digits.length - MAX_DIGITS - 1
            digits = "#{digits[0, MAX_DIGITS]}1"
          end
          magnitude = digits.length - 1 + exponent
          # Well within the doubles' range: Ruby's own conversion is correctly rounded there.
          value = if magnitude.between?(-300, 300)
                    Float("#{digits}e#{exponent}")
                  elsif magnitude > 309
                    Float::INFINITY
                  elsif magnitude < -325
                    0.0
                  else
                    nearest_double(Integer(digits, 10), exponent)
                  end
          negative ? -value.abs : value
        end

        # The exponent a number writes (`sign` and `digits`, nil without one): beyond 18 digits, a
        # power of ten no text reaches with its own digits (a number of 10^18 characters), so that
        # the number is out of range whatever they are.
        def exponent_of(sign, digits)
          return 0 if digits.nil?

          significant = digits.sub(/\A0+/, "")
          value = significant.length > 18 ? 10**18 : significant.to_i
          sign == "-" ? -value : value
        end

        # The double nearest `units` × 10^`exponent` (positive), on integers: for the edges of the
        # doubles' range, where Ruby's conversion warns.
        def nearest_double(units, exponent)
          numerator = exponent.negative? ? units : units * (10**exponent)
          denominator = exponent.negative? ? 10**-exponent : 1
          # 2^bits ≤ value < 2^(bits + 1).
          bits = numerator.bit_length - denominator.bit_length
          bits -= 1 if bits >= 0 ? numerator < denominator << bits : numerator << -bits < denominator
          return Float::INFINITY if bits > 1023

          # The weight of the last bit of the result: 53 bits, fewer below the normal doubles.
          scale = [bits - 52, -1074].max
          scaled_num = scale.negative? ? numerator << -scale : numerator
          scaled_den = scale.negative? ? denominator : denominator << scale
          quotient, remainder = scaled_num.divmod(scaled_den)
          twice = remainder * 2
          quotient += 1 if twice > scaled_den || (twice == scaled_den && quotient.odd?)
          return Float::INFINITY if quotient.bit_length + scale > 1024

          Math.ldexp(quotient.to_f, scale)
        end

        # The text JavaScript gives a finite number (Number::toString): the shortest digits that
        # read back as the same double, in full below 10^21 (1.2345678901234568e20 is
        # 123456789012345680000, not the double's exact 123456789012345683968), else with an
        # exponent. An Integer is written as it is (the gem writes safe integers only).
        def number_text(value)
          raise ArgumentError, "not a finite number" unless value.is_a?(Integer) || value.finite?
          return value.to_s if value.is_a?(Integer)
          return "0" if value.zero?

          sign = value.negative? ? "-" : ""
          # Ruby's shortest digits (David Gay's), in JavaScript's layout.
          mantissa, exponent = value.abs.to_s.split("e")
          whole, fraction = mantissa.split(".")
          digits = whole + fraction.to_s
          point = whole.length + exponent.to_i
          leading = digits[/\A0*/].length
          digits = digits[leading..]
          point -= leading
          digits = digits.sub(/0+\z/, "")
          sign + layout(digits, point)
        end

        # ECMAScript's Number::toString of the digits `digits` with the decimal point after
        # `point` of them.
        def layout(digits, point)
          size = digits.length
          if point.between?(size, 21)
            digits + ("0" * (point - size))
          elsif point.positive? && point <= 21
            "#{digits[0, point]}.#{digits[point..]}"
          elsif point > -6 && point <= 0
            "0.#{"0" * -point}#{digits}"
          else
            exponent = point - 1
            mark = exponent.negative? ? "-" : "+"
            head = size == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
            "#{head}e#{mark}#{exponent.abs}"
          end
        end

        def write(value, out)
          case value
          when nil then out << "null"
          when true then out << "true"
          when false then out << "false"
          when Integer, Float then out << number_text(value)
          when String then write_string(value, out)
          when Symbol then write_string(value.to_s, out)
          when Array
            out << "["
            value.each_with_index do |item, index|
              out << "," if index.positive?
              write(item, out)
            end
            out << "]"
          when Hash
            out << "{"
            value.each_with_index do |(name, item), index|
              out << "," if index.positive?
              write_string(name.to_s, out)
              out << ":"
              write(item, out)
            end
            out << "}"
          when Raw then out << value.text
          else raise ArgumentError, "no JSON for a #{value.class}"
          end
        end

        # What JSON.stringify writes of each character a string escapes: its short escape, else
        # \u00XX (the other control characters). Complete, so that each is looked up as it comes.
        STRING_ESCAPES = (0x00..0x1F).to_h { |code| [code.chr, format("\\u%04x", code)] }.merge(
          '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n",
          "\r" => "\\r", "\t" => "\\t"
        ).freeze
        # The characters a string escapes.
        ESCAPED = /["\\\x00-\x1F]/
        # Lone surrogates, as Json.parse keeps them (WTF-8), which JSON.stringify writes as escapes.
        SURROGATE = /\xED[\xA0-\xBF][\x80-\xBF]/n

        def write_string(text, out)
          text = text.dup.force_encoding(UTF_8) unless text.encoding == UTF_8
          out << '"'
          out << if text.valid_encoding?
                   text.gsub(ESCAPED, STRING_ESCAPES)
                 else
                   wtf8_escaped(text)
                 end
          out << '"'
        end

        # `text`, whose UTF-8 is broken only by lone surrogates, with JSON.stringify's escapes.
        def wtf8_escaped(text)
          bytes = text.b
          parts = []
          rest = bytes
          until rest.empty?
            index = rest =~ SURROGATE
            plain = (index ? rest[0, index] : rest).force_encoding(UTF_8)
            raise ArgumentError, "not a text" unless plain.valid_encoding?

            parts << plain.gsub(ESCAPED, STRING_ESCAPES)
            break unless index

            unit = ((rest.getbyte(index) & 0x0F) << 12) | ((rest.getbyte(index + 1) & 0x3F) << 6) |
                   (rest.getbyte(index + 2) & 0x3F)
            parts << format("\\u%04x", unit)
            rest = rest[(index + 3)..]
          end
          parts.join
        end

        # The text of a string's `body` (between its quotes, as RFC 8259 writes it), its escapes
        # read: a surrogate pair joined, a lone surrogate kept (WTF-8). Over its bytes, each escape
        # replaced as it comes: time linear in its length (SPEC.md §13, Limits). Read over its
        # characters, each escape's offset would be counted from the start again: a cost that grows
        # with the square of the length, with which anybody who writes events at a lease's `d` tag
        # would make every read of leases run out of time.
        def unescape(body)
          text = body.b.gsub(ESCAPE, UNESCAPED)
          text = text.gsub(SURROGATE_PAIR) { joined(Regexp.last_match) } if text.include?(SURROGATE_LEAD)
          text.force_encoding(UTF_8)
        end

        # The bytes of a code unit below U+10000 as UTF-8 would encode it, surrogates included.
        def wtf8(unit)
          if unit < 0x80
            unit.chr
          elsif unit < 0x800
            [0xC0 | (unit >> 6), 0x80 | (unit & 0x3F)].pack("C*")
          else
            [0xE0 | (unit >> 12), 0x80 | ((unit >> 6) & 0x3F), 0x80 | (unit & 0x3F)].pack("C*")
          end
        end

        # The UTF-8 of the code point of a SURROGATE_PAIR match: its high and its low surrogate, each
        # as wtf8 encodes it (0xED, then its 12 low bits in two bytes).
        def joined(match)
          high = 0xD000 | ((match[1].ord & 0x3F) << 6) | (match[2].ord & 0x3F)
          low = 0xD000 | ((match[3].ord & 0x3F) << 6) | (match[4].ord & 0x3F)
          [0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)].pack("U").b
        end

        # An iterative RFC 8259 reader over a StringScanner.
        class Parser
          def initialize(text)
            @scanner = StringScanner.new(text)
          end

          def parse
            # Each frame: [container, name of the member being read (objects)].
            stack = []
            loop do
              value = read_value(stack)
              next if value.equal?(Parser::OPENED)

              loop do
                if stack.empty?
                  skip_whitespace
                  invalid("text after the value") unless @scanner.eos?
                  return value
                end
                frame = stack.last
                container = frame[0]
                if container.is_a?(Hash)
                  container[frame[1]] = value
                else
                  container << value
                end
                skip_whitespace
                if @scanner.skip(/,/)
                  frame[1] = read_name if container.is_a?(Hash)
                  break
                end
                closing = container.is_a?(Hash) ? /\}/ : /\]/
                invalid("expected , or a closing bracket") unless @scanner.skip(closing)
                stack.pop
                value = container
              end
            end
          end

          # Marks a container opened: its first member or element is read next.
          OPENED = Object.new.freeze

          private

          def read_value(stack)
            skip_whitespace
            if @scanner.skip(/\{/)
              skip_whitespace
              return {} if @scanner.skip(/\}/)

              stack << [{}, read_name(skip: false)]
              OPENED
            elsif @scanner.skip(/\[/)
              skip_whitespace
              return [] if @scanner.skip(/\]/)

              stack << [[], nil]
              OPENED
            elsif @scanner.check(/"/)
              read_string
            elsif (number = @scanner.scan(NUMBER))
              Json.double(number)
            elsif @scanner.skip(/true/)
              true
            elsif @scanner.skip(/false/)
              false
            elsif @scanner.skip(/null/)
              nil
            else
              invalid("expected a value")
            end
          end

          # A member's name and its colon.
          def read_name(skip: true)
            skip_whitespace if skip
            invalid("expected a name") unless @scanner.check(/"/)
            name = read_string
            skip_whitespace
            invalid("expected :") unless @scanner.skip(/:/)
            name
          end

          def read_string
            invalid("invalid string") unless @scanner.scan(STRING)
            body = @scanner[1]
            body.include?("\\") ? Json.unescape(body) : body
          end

          def skip_whitespace
            @scanner.skip(WHITESPACE)
          end

          def invalid(reason)
            raise Invalid, reason
          end
        end
      end
    end
  end
end
