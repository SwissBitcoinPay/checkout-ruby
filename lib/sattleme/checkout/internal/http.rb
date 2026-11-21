# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # HTTP as every implementation asks it (SPEC.md §15): a GET asking for JSON, with the
      # User-Agent of every implementation, through the client given (the platform's by default,
      # HttpClient). An https URL only, but for the merchant's Bitcoin node (a context whose `node`
      # is true: the explorer reading a URL of a node URL, CallExplorer), whose URL follows a rule of
      # its own (NodeUrl: `http` for a local host): every other rule holds for it too. No redirect is
      # followed: each URL is checked before it is asked, a redirect
      # would skip the check, so a redirect is no answer. The body is read up to 1 MiB, one leading
      # byte order mark ignored. The whole request is bounded by its timeout, and stopped with its
      # call: each runs in a thread of its own, given up when its time runs out or its call stops
      # (the client is told: its cancellation), then waited for until it ended, STOP_GRACE_SECONDS
      # at most: a client that does not stop when it is told is left behind, never the call.
      module Http
        # The way to the network: the client, each request's timeout (milliseconds), the call's stop,
        # and whether it asks the merchant's Bitcoin node (`http` allowed to a local one).
        Context = Data.define(:client, :timeout_ms, :stop, :node) do
          def initialize(client:, timeout_ms:, stop:, node: false)
            super
          end

          def with_stop(stop) = with(stop: stop)
        end

        # An answer: its HTTP status, and its body read as JSON (nil when it is not JSON in UTF-8).
        Answer = Data.define(:status, :body) do
          def ok? = status.between?(200, 299)
        end

        # An answer whose body is text (an explorer's height): nil when it is not UTF-8.
        TextAnswer = Data.define(:status, :text) do
          def ok? = status.between?(200, 299)
        end

        # The body was larger than MAX_HTTP_BODY_BYTES.
        class TooLarge < StandardError; end

        BOM = "\xEF\xBB\xBF".b

        module_function

        # GET `url` asking for JSON: its status and its body as JSON (nil when it is not JSON in
        # UTF-8). NetworkError when there is no answer in time, a redirect or a body too large.
        def get_json(url, context, headers = {})
          status, bytes = get_bytes(url, context, headers)
          text = Text.decode_utf8(bytes)
          Answer.new(status: status, body: text && Json.parse_or(text))
        end

        # GET `url` as get_json does, for the one plain-text answer (an explorer's height).
        def get_text(url, context, headers = {})
          status, bytes = get_bytes(url, context, headers)
          TextAnswer.new(status: status, text: Text.decode_utf8(bytes))
        end

        def get_bytes(url, context, headers)
          stop = context.stop
          stop.check!
          # Checked before (an https URL, SPEC.md §15; the node's own rule, SPEC.md §31), and again
          # here whatever the client: an https URL, or, read by the explorer, a URL under a node URL
          # (in clear HTTP to a local node alone).
          unless askable?(url, context.node)
            raise NetworkError, "No answer from #{Urls.host_of(url)}: it cannot be asked"
          end

          timeout = context.timeout_ms / 1000.0
          deadline = Clock.now + timeout
          request = Cancellation.new
          all_headers = headers.merge("Accept" => "application/json", "User-Agent" => Protocol::USER_AGENT)
          future = Future.spawn("sattleme-checkout http", call: false) do
            ask(context.client, url, all_headers, timeout, request)
          end
          answered = begin
            future.wait(stop, deadline)
          ensure
            # Stopped, out of time or cancelled: the client's request with it. Either way, its thread
            # has ended when the call goes on.
            request.cancel unless future.settled?
            Internal.join(future.thread, STOP_GRACE_SECONDS)
          end
          raise NetworkError, "No answer from #{Urls.host_of(url)} in time" unless answered

          state, result = future.outcome
          if state == :error
            stop.check!
            raise NetworkError.new("No answer from #{Urls.host_of(url)}"), cause: result
          end
          if result == :too_large
            raise NetworkError, "#{Urls.host_of(url)} answered more than #{Protocol::MAX_HTTP_BODY_BYTES} bytes"
          end

          status, bytes = result
          raise NetworkError, "#{Urls.host_of(url)} answered a redirect (HTTP #{status})" if status.between?(300, 399)

          # One byte order mark is ignored, as WHATWG's UTF-8 decode (and so fetch) ignores it.
          [status, bytes.start_with?(BOM) ? bytes.byteslice(3..) : bytes]
        end

        # Whether `url` may be asked: an https URL (Urls.https_url), or, of the merchant's Bitcoin node
        # (`node`), a URL whose scheme and authority are a node URL's (NodeUrl.origin_of).
        def askable?(url, node)
          return true if Urls.https_url(url)

          node && url.match?(%r{\Ahttps?://}) && !NodeUrl.origin_of(url).nil?
        end

        # The client's answer: [status, body], or :too_large.
        def ask(client, url, headers, timeout, cancellation)
          chunks = []
          size = 0
          status = client.get(url, headers: headers, timeout: timeout, cancellation: cancellation) do |chunk|
            size += chunk.bytesize
            raise TooLarge if size > Protocol::MAX_HTTP_BODY_BYTES

            chunks << chunk.b
          end
          raise TypeError, "An HTTP client's get gives the status, an Integer" unless status.is_a?(Integer)

          [status, chunks.join]
        rescue TooLarge
          :too_large
        end
      end
    end
  end
end
