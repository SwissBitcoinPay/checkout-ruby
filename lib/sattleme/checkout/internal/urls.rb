# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Hosts and https URLs, in their one spelling (SPEC.md §9, §15): what the gem asks over the
      # network (relays, the Lightning address's pay URL, its callback and verify URLs) and what a
      # checkout link sends the customer to. Nothing is repaired: a URL that is not so is refused,
      # so that no request goes to an IP address, to the machine itself (`localhost` and the names
      # under it, RFC 6761) or to a host other than the one checked.
      module Urls
        # A host: labels of `a–z 0–9 -` separated by `.`, the last of at least two letters `a–z`.
        HOST = /\A[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\z/
        # The characters of a redirect URL and of an https URL: RFC 3986's, and `%` with two hex
        # digits.
        URL_CHARACTERS = %r{\A(?:[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]|%[0-9A-Fa-f]{2})+\z}
        # `https://`, the authority (up to the first `/`, `?` or `#`), then anything.
        HTTPS = %r{\Ahttps://([^/?#]*)(?:[/?#].*)?\z}m
        # An authority: a host and an optional port of 1 to 5 digits.
        AUTHORITY = /\A([^:]*)(?::([0-9]{1,5}))?\z/

        # An https URL's host and port: 443 when it names none.
        HttpsUrl = Data.define(:host, :port)

        module_function

        # Whether `host` is a host as in a relay address: lower case, at most 253 characters, so
        # never an IP address; its last label not `localhost`, nor a name under it.
        def host?(host)
          Text.well_formed?(host) && host.length <= Protocol::MAX_HOST_LENGTH && host.match?(HOST) &&
            !host.match?(/(?:\A|\.)localhost\z/)
        end

        # Whether `port` (its digits, nil when the URL has none) is absent or 1 to 65535.
        def port?(port)
          port.nil? || port.to_i.between?(1, 65_535)
        end

        # `value` as an https URL (rule 1 of a redirect URL): 1 to 2048 characters of a redirect
        # URL, `https://`, a host, an optional port, then nothing or `/`, `?` or `#` and anything.
        # So no upper case in the scheme or the host, no user name nor password, no IP address, no
        # whitespace, no `\`. Nil when it is not one.
        def https_url(value)
          return nil unless Text.match?(value, URL_CHARACTERS) && value.length <= Protocol::MAX_HTTPS_URL_LENGTH

          authority = AUTHORITY.match(HTTPS.match(value)&.[](1) || "")
          return nil unless authority && host?(authority[1]) && port?(authority[2])

          HttpsUrl.new(host: authority[1], port: authority[2].nil? ? 443 : authority[2].to_i)
        end

        # Whether two https URLs are on the same host: their hosts and their ports are equal.
        def same_host?(first, second)
          first.host == second.host && first.port == second.port
        end

        # The host of a URL, for messages: never its path (a Lightning address's name is in it).
        def host_of(url)
          match = %r{\A[a-z][a-z0-9+.-]*://([^/?#]*)}.match(url.to_s)
          match ? match[1] : "(invalid URL)"
        end

        # The request target (path and query) of a URL whose authority ends at `start`: what a
        # browser asks of it (WHATWG): `\` is a separator, `.` and `..` segments resolved (`%2e`
        # is a dot), what a request line cannot hold percent-encoded; the fragment dropped.
        def request_target(rest)
          path, query = rest.sub(/#.*\z/m, "").split("?", 2)
          parts = path.to_s.tr("\\", "/").split("/", -1).drop(1)
          segments = []
          parts.each_with_index do |segment, index|
            last = index == parts.size - 1
            case segment.downcase
            when ".", "%2e"
              segments << "" if last
            when "..", ".%2e", "%2e.", "%2e%2e"
              segments.pop
              segments << "" if last
            else
              segments << segment
            end
          end
          target = "/#{segments.map { |segment| percent_encode(segment, PATH_UNSAFE) }.join("/")}"
          query ? "#{target}?#{percent_encode(query, QUERY_UNSAFE)}" : target
        end

        # WHATWG's path percent-encode set and special-query percent-encode set (with `#`, which the
        # fragment's removal leaves out), every byte beyond ASCII included.
        PATH_UNSAFE = /[\x00-\x20"#<>?`{}\x7F-\xFF]/n
        QUERY_UNSAFE = /[\x00-\x20"#<>'\x7F-\xFF]/n

        def percent_encode(text, unsafe)
          text.b.gsub(unsafe) { |byte| format("%%%02X", byte.ord) }.force_encoding(Encoding::UTF_8)
        end
      end

      # Lists of Nostr relays, as the merchant's app writes them (SPEC.md §9): every address a
      # `wss://` URL in its one spelling, 1 to 10 of them, none twice. A list that is not so is
      # refused, never repaired.
      module Relays
        PREFIX = "wss://"
        # ECMAScript's whitespace (`\s`), as the merchant's app's rule reads it.
        WHITESPACE = "\\t\\n\\v\\f\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
        # A lowercase host name, an optional port, an optional path without whitespace, query,
        # fragment nor comma: the merchant's app's rule.
        ADDRESS = %r{\A([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(:[0-9]{1,5})?(/[^#{WHITESPACE}?\#,]*)?\z}

        # Where a relay address connects: its host, its port (443 when it names none) and the request
        # target of its WebSocket handshake.
        Endpoint = Data.define(:host, :port, :target)

        module_function

        # Whether `url` is a relay address in its one spelling: `wss://`, a lowercase host name (not
        # `localhost` nor a name under it), an optional port (1 to 65535) and an optional path
        # without a trailing slash, 120 code points at most.
        def url?(url)
          return false unless Text.well_formed?(url) && url.start_with?(PREFIX)

          match = ADDRESS.match(url.delete_prefix(PREFIX))
          return false unless match

          path = match[3] || ""
          Urls.host?(match[1]) && Urls.port?(match[2]&.delete_prefix(":")) && !path.end_with?("/") &&
            Text.code_point_length(url) <= Protocol::MAX_RELAY_URL_LENGTH
        end

        # A valid list (1 to MAX_RELAYS addresses in their one spelling, none twice), else nil.
        def parse_list(value)
          return nil unless value.is_a?(Array) && value.size.between?(1, Protocol::MAX_RELAYS)

          list = []
          value.each do |item|
            return nil unless url?(item) && !list.include?(item)

            list << item
          end
          list.freeze
        end

        # The list of a key's part: hosts without `wss://`, joined by commas, in base64url.
        def decode_list(text)
          bytes = Base64.decode_url(text)
          return nil if bytes.nil? || bytes.empty?

          # Strict UTF-8: a byte order mark stays U+FEFF, which no host holds (SPEC.md §8).
          decoded = Text.decode_utf8(bytes)
          return nil if decoded.nil?

          parse_list(decoded.split(",", -1).map { |host| PREFIX + host })
        end

        # The part of a key or a checkout link naming `relays`.
        def encode_list(relays)
          Base64.encode_url(relays.map { |relay| relay.delete_prefix(PREFIX) }.join(",").b)
        end

        def same_list?(first, second)
          first.size == second.size && first.zip(second).all? { |a, b| a == b }
        end

        # Where the relay address `url` connects (a relay address, or the explorer's WebSocket).
        def endpoint(url)
          match = %r{\Awss://([^/:]+)(?::([0-9]{1,5}))?(/.*)?\z}m.match(url)
          raise ArgumentError, "Not a wss:// address" unless match

          Endpoint.new(host: match[1], port: match[2] ? match[2].to_i : 443,
                       target: Urls.request_target(match[3] || "/"))
        end
      end
    end
  end
end
