# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # The explorer's WebSocket (SPEC.md §31, "Waiting for an on-chain payment"): while
      # wait_for_payment waits, the explorer (mempool.space, or the merchant's Bitcoin node) pushes
      # what changes for the address (a transaction entering the mempool, confirmed, or leaving it)
      # and each new block (one more confirmation).
      # Only a signal to check the on-chain part again: what it pushes is never trusted, the check
      # asks the explorer.
      class Watch
        # The messages that say something changed for the address, or for its confirmations.
        CHANGES = %w[address-transactions block-transactions address-removed-transactions block].freeze

        # Watches `address` on the explorer's WebSocket (through `websocket`, the handshake bounded
        # by `timeout` seconds) until #close, in a thread of its own: `on_change` is called (in that
        # thread: quick) at each connection (what happened before was not pushed) and at each
        # message about the address or a new block. Each connection tries the WebSockets of
        # `explorer`'s sources in order (CallExplorer#sources): one that fails, or is lost before
        # any message, goes to the next at once (the node's to mempool.space's with `fallback`
        # "mempool", SPEC.md §31), a node's failure told to `explorer` (CallExplorer#node_failed).
        # A lost socket connects again after 1 s, doubled at each failure (of the last one tried)
        # up to 30 s; a connection lost before it received a message is a failure, so that a server
        # that accepts and drops each connection (each one starts a check) is connected to less and
        # less often. `wait` (seconds → whether it was closed meanwhile) waits between two
        # connections: for tests.
        def initialize(websocket, explorer, address, timeout, wait: nil, &on_change)
          @websocket = websocket
          @explorer = explorer
          @address = address
          @timeout = timeout
          @on_change = on_change
          @closed = Cancellation.new
          @wait = wait || ->(seconds) { @closed.wait(seconds) }
          @mutex = Mutex.new
          @socket = nil
          @thread = Thread.new { run }
          @thread.name = "sattleme-checkout explorer socket"
          @thread.report_on_exception = false
        end

        # Closes the socket, for good, and waits until the thread ended (STOP_GRACE_SECONDS at most:
        # a WebSocket client of the integrator's may not stop when it is told).
        def close
          @closed.cancel
          socket = @mutex.synchronize { @socket.tap { @socket = nil } }
          begin
            socket&.close
          rescue StandardError
            nil
          end
          Internal.join(@thread, STOP_GRACE_SECONDS)
          nil
        end

        private

        def run
          delay = Protocol::RECONNECT_FIRST_MS
          until @closed.cancelled?
            # The explorer answered: the next loss waits 1 s again.
            delay = Protocol::RECONNECT_FIRST_MS if heard_from_sources?
            break if @closed.cancelled? || @wait.call(delay / 1000.0)

            delay = [delay * 2, Protocol::RECONNECT_MAX_MS].min
          end
        end

        # One connection to each of the explorer's sources in turn, until one received a message
        # (then lost) or every one failed: whether one received a message.
        def heard_from_sources?
          @explorer.sources.each do |source|
            return false if @closed.cancelled?
            return true if watch_once(source)

            # Failed, or lost before any message: the next one at once.
            @explorer.node_failed if source.node? && !@closed.cancelled?
          end
          false
        end

        # One connection to `source`'s WebSocket, until it is lost: whether it received a message.
        def watch_once(source)
          heard = false
          socket = @websocket.connect(source.web_socket,
                                      timeout: @timeout, headers: { "User-Agent" => Protocol::USER_AGENT },
                                      cancellation: @closed)
          kept = @mutex.synchronize { @closed.cancelled? ? false : (@socket = socket) }
          return false unless kept

          begin
            socket.send_text(Json.generate({ "action" => "want", "data" => ["blocks"] }))
            socket.send_text(Json.generate({ "track-address" => @address }))
          rescue StandardError
            return false
          end
          @on_change.call
          while (text = socket.receive)
            heard = true
            text = Text.decode_utf8(text) unless Text.well_formed?(text)
            message = text && Json.parse_or(text)
            @on_change.call if message.is_a?(Hash) && CHANGES.any? { |key| message.key?(key) }
          end
          heard
        rescue StandardError
          heard
        ensure
          @mutex.synchronize { @socket = nil if @socket.equal?(socket) }
          begin
            socket&.close
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
