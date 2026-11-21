# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The merchant's Bitcoin node (SPEC.md §31, "The merchant's Bitcoin node"): a node of its own
      # that serves mempool.space's API (an Umbrel, a server of its own), which the channel names
      # (`bitcoinNode`, §14) and the server then reads the blockchain from, rather than from
      # mempool.space. Its URL follows a rule of its own (NodeUrl), not the https URL's (§15):
      # `http` is allowed for a host of a local network, and so is an IPv4 address. Nothing is
      # repaired: a URL that is not in its one spelling is no node URL, and the channel then names
      # no node.
      module BitcoinNodes
        # What the server does when the node does not answer a read: "mempool", the same read of
        # mempool.space; "none", never mempool.space.
        FALLBACKS = %w[mempool none].freeze

        # The channel's `bitcoinNode`, valid: its URL (a node URL, as the channel writes it), its
        # fallback, and whether the pages of checkout links read it too (`payers`, a node of the
        # Internet only).
        Node = Data.define(:url, :fallback, :payers)

        # The node a checkout link's record names (SPEC.md §30): its URL and its fallback.
        RecordNode = Data.define(:url, :fallback) do
          def to_h = { "url" => url, "fallback" => fallback }
        end

        module_function

        # The channel's `bitcoinNode` (SPEC.md §14, §31): an object (a Hash, never an array) whose
        # `url` is a node URL, whose `fallback` is exactly "mempool" or "none" and whose `payers` is
        # a JSON boolean, true only for a node of the Internet; its other members ignored. Nil when
        # it is absent or invalid in any way: there is none, the server reads mempool.space, and the
        # channel stays valid.
        def of(value)
          return nil unless value.is_a?(Hash)

          url, fallback, payers = value.values_at("url", "fallback", "payers")
          node = NodeUrl.parse(url)
          return nil unless node && fallback?(fallback) && [true, false].include?(payers)
          # A link must never make each customer's browser probe its own local network.
          return nil if payers && !node.internet?

          Node.new(url: node.url, fallback: fallback, payers: payers)
        end

        # What a checkout link's record of version 2 holds of `node` (SPEC.md §30): its `url` and
        # `fallback`, copied as they are, never `payers`; nil (the field absent) when the channel
        # names no node or its `payers` is false.
        def record_node_for(node)
          node&.payers ? RecordNode.new(url: node.url, fallback: node.fallback) : nil
        end

        # The node a page reads from a record of version 2's `bitcoinNode` (SPEC.md §30, "Reading a
        # record"): an object whose `url` is a node URL of a node of the Internet and whose
        # `fallback` is exactly "mempool" or "none" (its other members ignored); anything else (null
        # included) is set aside, the page reading mempool.space, and leaves the record valid.
        def record_node_of(value)
          return nil unless value.is_a?(Hash)

          url, fallback = value.values_at("url", "fallback")
          node = NodeUrl.parse(url)
          return nil unless node&.internet? && fallback?(fallback)

          RecordNode.new(url: node.url, fallback: fallback)
        end

        # Whether `value` is "mempool" or "none", exactly.
        def fallback?(value)
          value.is_a?(String) && FALLBACKS.include?(value)
        end

        # The explorers one read asks, in order (SPEC.md §31, `fallback`): without a node
        # (`fallback` nil), mempool.space; with "none", the node alone; with "mempool", the node
        # then mempool.space, or mempool.space first when the node failed a read less than 60 s ago
        # in the same call (`failed_recently`). The next one is asked only when the one before
        # failed.
        def explorers_to_ask(fallback, failed_recently)
          return [:mempool] if fallback.nil?
          return [:node] if fallback == "none"

          failed_recently ? %i[mempool node] : %i[node mempool]
        end
      end

      # A node URL (SPEC.md §31, "A node URL"), checked, with where the node is read: in its one
      # spelling `<scheme>://<host>[:<port>][<path>]`, 200 characters at most. `https`, or `http` for
      # a local host; a host in lowercase, an IPv4 address (never in 0.0.0.0/8 nor 127.0.0.0/8) or a
      # name (never `localhost` nor under it); a port from 1 to 65535; a path that ends neither with
      # `/` nor with `/api`. So no user name nor password, no query, no fragment, no IPv6 address, no
      # whitespace.
      #
      # `rest` is `<url>/api`, the `<explorer>` of SPEC.md §31, "Explorers"; `web_socket` is `<url>`
      # with `ws` for its leading `http`, then `/api/v1/ws`. `local`: its host is of a local network
      # (a local IPv4 range, or a name under `.local`); `internet`: it is a node of the Internet
      # (`https`, and a name whose last label is not `local`).
      NodeUrl = Data.define(:url, :scheme, :host, :port, :local) do
        def rest = "#{url}/api"

        def web_socket = "ws#{url.delete_prefix("http")}/api/v1/ws"

        def local? = local

        def internet? = scheme == "https" && !NodeUrl.ipv4?(host) && !local

        # Whether it is asked over TLS (`https`), else in clear HTTP (a local host only).
        def tls? = scheme == "https"
      end

      # The rule of a node URL (NodeUrl.parse) and the checks of its parts.
      class NodeUrl
        # `<scheme>://<host>[:<port>][<path>]`: the host up to `:` or `/` (nothing that may start a
        # user name, a query or a fragment), a port of 1 to 5 digits without a leading zero, a path
        # of visible ASCII. The parts are then checked one by one.
        SHAPE = %r{\A(https?)://([^/:?#@\\\s]+)(?::([1-9][0-9]{0,4}))?(/[\x21-\x7e]*)?\z}
        # An IPv4 address: 4 numbers from 0 to 255, none with a leading zero (`0` alone is one).
        OCTET = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
        IPV4 = /\A#{OCTET}\.#{OCTET}\.#{OCTET}\.#{OCTET}\z/
        # A label of a name: 1 to 63 of `a–z 0–9 -`, neither starting nor ending with `-`.
        LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
        # A name's length, at most.
        MAX_NAME_LENGTH = 253

        # `value` as a node URL, nil when it is not one.
        def self.parse(value)
          return nil unless Text.well_formed?(value) && value.length <= Protocol::MAX_NODE_URL_LENGTH

          match = SHAPE.match(value)
          return nil unless match

          scheme, host, port, path = match.captures
          return nil if port && Integer(port, 10) > 65_535
          return nil unless path?(path || "")

          local = locality(host)
          return nil if local.nil?
          return nil if scheme == "http" && !local

          new(url: value, scheme: scheme, host: host, port: port ? Integer(port, 10) : default_port(scheme),
              local: local)
        end

        # The node URL `url` begins with: its scheme and authority (`<scheme>://<host>[:<port>]`) a
        # node URL's, the rest anything (a path, as the explorer asks it). Nil when it is not so. What
        # the gem's HTTP and WebSocket clients check before they ask in clear (`http`, `ws`): a local
        # host only.
        def self.origin_of(url)
          match = %r{\A(https?|wss?)://([^/?#]*)}.match(url.to_s)
          return nil unless match

          scheme = match[1].sub(/\Aws/, "http")
          parse("#{scheme}://#{match[2]}")
        end

        def self.default_port(scheme) = scheme == "https" ? 443 : 80

        def self.ipv4?(host) = IPV4.match?(host)

        # Whether `host` is local (true), of the Internet (false), or no node's host (nil).
        def self.locality(host)
          octets = IPV4.match(host)&.captures&.map { |octet| Integer(octet, 10) }
          if octets
            # Never the machine itself, nor "this network".
            return nil if octets[0].zero? || octets[0] == 127

            return local_ipv4?(octets)
          end
          return nil unless name?(host)

          host.end_with?(".local")
        end

        # Whether an IPv4 address is of a local range: 10/8, 172.16/12, 192.168/16, 100.64/10 (the
        # shared address space of RFC 6598, which Tailscale uses).
        def self.local_ipv4?(octets)
          a, b = octets
          a == 10 || (a == 172 && b.between?(16, 31)) || (a == 192 && b == 168) || (a == 100 && b.between?(64, 127))
        end

        # Whether `host` is a name: 2 labels or more, the last starting with a letter, no `localhost`.
        def self.name?(host)
          return false if host.length > MAX_NAME_LENGTH

          labels = host.split(".", -1)
          return false unless labels.size >= 2 && labels.all? { |label| LABEL.match?(label) }

          labels.last.match?(/\A[a-z]/) && labels.last != "localhost"
        end

        # Whether `path` (after the authority, empty when absent) is a node URL's: visible ASCII
        # already; never `?`, `#`, `@` nor `\`; not `/` alone, no trailing `/`, no `/api` at the end
        # (the node's URL, not its API's).
        def self.path?(path)
          return true if path.empty?
          return false if path.match?(/[?#@\\]/)

          !path.end_with?("/") && !path.match?(%r{/api\z}i)
        end

        private_class_method :default_port, :locality, :local_ipv4?, :name?, :path?
      end

      # When the nodes a call read failed a read, by node URL (the client's clock, Unix seconds): of
      # one call alone (create_invoice, get_status, one wait_for_payment), shared by its reads and
      # its WebSocket, never kept between calls. Thread-safe.
      class NodeFailures
        def initialize
          @mutex = Mutex.new
          @at = {}
        end

        def [](url) = @mutex.synchronize { @at[url] }

        def []=(url, time)
          @mutex.synchronize { @at[url] = time }
        end
      end

      # The explorer of a call (SPEC.md §31, "Explorers"): mempool.space, or the channel's node
      # (BitcoinNodes::Node, valid) with its fallback. Each read follows the fallback on its own; a
      # node that fails is remembered in the call's NodeFailures, so that for 60 s it is asked after
      # mempool.space. `now`: the client's clock (Unix seconds).
      class CallExplorer
        # An explorer a read may ask: :node or :mempool, its REST URL (`<explorer>`) and its
        # WebSocket's.
        Source = Data.define(:name, :rest, :web_socket) do
          def node? = name == :node
        end

        MEMPOOL = Source.new(name: :mempool, rest: Protocol::MEMPOOL_URL, web_socket: Protocol::MEMPOOL_WEBSOCKET_URL)

        # The channel's node (nil: mempool.space).
        attr_reader :node

        def initialize(node, failures, now)
          at = node && NodeUrl.parse(node.url)
          @node = at && node
          @source = at && Source.new(name: :node, rest: at.rest, web_socket: at.web_socket)
          @failures = failures
          @now = now
        end

        # The explorers the next read asks, in order (BitcoinNodes.explorers_to_ask).
        def sources
          return [MEMPOOL] unless @node

          failed_at = @failures[@node.url]
          recently = !failed_at.nil? && @now.call - failed_at < Protocol::NODE_FAILED_RECENTLY_SECONDS
          BitcoinNodes.explorers_to_ask(@node.fallback, recently).map { |name| name == :node ? @source : MEMPOOL }
        end

        # The node failed a read (or its WebSocket a connection): remembered for the call.
        def node_failed
          @failures[@node.url] = @now.call if @node
        end

        # One read of the explorer: the block with the `<explorer>` URL of each explorer of sources(),
        # in order, and an HTTP context of that explorer's own (`http` with a stop of its own, which
        # allows `http` to a local node alone: Http), until one answers. Each is stopped once it
        # failed: what the block asked of it at the same time (the chain's height with the address's
        # transactions) ends then, and the whole read is asked again of the next one, never part of
        # it. NetworkError when every one failed; a cancellation (Cancelled) is raised as it is.
        def read(http)
          failures = []
          sources.each do |source|
            attempt = http.stop.child
            begin
              return yield(source.rest, http.with(stop: attempt, node: source.node?))
            rescue NetworkError => e
              http.stop.check!
              node_failed if source.node?
              failures << e
            ensure
              attempt.stop
            end
          end
          raise failures.first if failures.size == 1

          raise NetworkError.new("Neither the merchant's Bitcoin node nor mempool.space answered " \
                                 "(#{failures.map(&:message).join("; ")})"), cause: failures.last
        end
      end
    end
  end
end
