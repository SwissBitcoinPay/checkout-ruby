# frozen_string_literal: true

module Sattleme
  module Checkout
    module Internal
      # Nostr relays (NIP-01, NIP-42; SPEC.md §13), ported from the merchant's app. A call opens one
      # connection per relay, every read and write of the call goes over it, and it is closed once
      # the call is done. Every relay of a list at once, each in a thread of its own; a call goes on
      # as soon as a majority of them answered (any two majorities of one list share a relay).
      # Subscription ids are random: what a relay receives names nothing of the integration.
      module Relay
        # NIP-42 prefix of a refusal that authentication may lift.
        AUTH_REQUIRED = "auth-required:"

        # A request to a relay failed: no answer in time, a connection that failed or closed, a
        # query CLOSED, an event refused.
        class Failure < StandardError; end

        # A relay's refusal of an event (NIP-01 `OK` false), with its reason.
        class Refusal < Failure
          attr_reader :reason

          def initialize(url, reason)
            @reason = reason
            super("#{url} refused the event: #{reason}")
          end
        end

        # What a read keeps of an event a relay sent (SPEC.md §13), as it comes: its `id` (one
        # longer than 64 bytes by its SHA-256), its `created_at` when it is a safe integer, and
        # what the read's `keep` kept of it (`kept` false: nothing, the event dropped there).
        Entry = Data.define(:id, :created_at, :value, :kept)

        # What a read of a list gives: the events of each relay that answered (its read ended), and
        # whether a majority of the list answered (Relay.outcome): else the read is no answer
        # (network), never an absence. On every relay (SPEC.md §13), the pages that a relay still
        # reading had sent are among the events too, and that is all: such a relay has not answered.
        Answers = Data.define(:answers, :answered)

        # What a complete read of a list gives: as Answers, and whether it is complete: a majority
        # of the list read completely (Relay.outcome).
        CompleteAnswers = Data.define(:answers, :answered, :complete)

        # What a read of a list gives once it goes on (Relay.outcome): whether a majority of the
        # list answered, and whether a majority read completely.
        Outcome = Data.define(:answered, :complete)

        # How a read of a list stands (SPEC.md §13): how many relays answered, how many read
        # completely, how many are still reading.
        Tally = Data.define(:answered, :complete, :reading)

        module_function

        # More than half of `count` relays: any two majorities of one list share a relay.
        def majority(count)
          (count / 2) + 1
        end

        # The Tally of a read from the read of each relay: :complete or :incomplete once it ended
        # (of a read that is not a complete read, any read that ended is :incomplete), :failed, or
        # :reading while it goes on. Only a relay whose read ended answered: one still reading has
        # not, whatever pages it sent (SPEC.md §13, "Reads on every relay").
        def tally(states)
          Tally.new(answered: states.count { |state| %i[complete incomplete].include?(state) },
                    complete: states.count(:complete), reading: states.count(:reading))
        end

        # What a read of a list gives once it goes on (SPEC.md §13), from what the read of each relay
        # of the list is then (`states`, as #tally reads them): whether a majority of the list
        # answered (their reads ended, complete or not: a relay still reading never did, whatever
        # pages it sent), else the read is no answer (network); and whether a majority read
        # completely, which makes a complete read complete. The pool's reads give it, and only it.
        def outcome(states)
          needed = majority(states.size)
          counted = tally(states)
          Outcome.new(answered: counted.answered >= needed, complete: counted.complete >= needed)
        end

        # The entry of `value`, a relay's event: its id when it is a string, its date when it is a
        # safe integer, and what `keep` gives of it (nil: nothing kept). `read` holds the ids of the
        # query so far: an event of one of them again (a copy, or a forgery: an id is its event's
        # hash) is counted, never kept nor checked again (SPEC.md §13, Limits).
        def entry_of(value, keep, read = nil)
          fields = value.is_a?(Hash) ? value : {}
          id = fields["id"]
          id = nil unless id.is_a?(String)
          id = "##{Text.hex(Crypto.sha256(id.b))}" if id && id.bytesize > 64
          created_at = Json.safe_integer?(fields["created_at"]) ? fields["created_at"].to_i : nil
          if id && read
            return Entry.new(id: id, created_at: created_at, value: nil, kept: false) if read.key?(id)

            read[id] = true
          end
          kept = keep.call(value)
          Entry.new(id: id, created_at: created_at, value: kept, kept: !kept.nil?)
        end

        # One page of a paged read (SPEC.md §13, "Paged reads"), read: the next page's `until`, or nil
        # when the read ends there. Its events with a string `id` and a safe integer `created_at`
        # page the read, whatever else they hold (one that does not check out pages it all the
        # same): `until` is the oldest such `created_at`, minus 1 when none of them was new to the
        # read. `seen` holds the ids of the read so far; the page's new ones are added to it, and
        # what the read keeps of them to `kept`. An event without these two members is not kept.
        def after_paged_page(answer, seen, kept)
          oldest = nil
          fresh = false
          answer.each do |entry|
            next if entry.id.nil? || entry.created_at.nil?

            oldest = oldest.nil? ? entry.created_at : [oldest, entry.created_at].min
            next if seen.key?(entry.id)

            seen[entry.id] = true
            kept << entry.value if entry.kept
            fresh = true
          end
          return nil if oldest.nil?

          fresh ? oldest : oldest - 1
        end

        # One page of a complete read (SPEC.md §13, "Complete reads"), read: [:until, t], the next
        # page's `until`, or [:complete, whether it is]. `seen` holds the ids of the read so far;
        # the page's new ones are added to it, and the events kept of them to `kept`.
        def after_complete_page(answer, seen, kept, pages_read)
          oldest = nil
          fresh = false
          answer.each do |entry|
            next if entry.id.nil?

            oldest = oldest.nil? ? entry.created_at : [oldest, entry.created_at].min unless entry.created_at.nil?
            next if seen.key?(entry.id)

            seen[entry.id] = true
            kept << entry.value if entry.kept
            # New, dated or not ("no event not seen before"): the next page may hold more.
            fresh = true
          end
          # More than asked: the relay ignored the limit, and what it left out cannot be told.
          return [:complete, false] if answer.size > Protocol::COMPLETE_READ_LIMIT
          return [:complete, true] if answer.size < Protocol::COMPLETE_READ_LIMIT
          # Full: the next page from its oldest second, unless it cannot move on.
          return [:complete, false] if oldest.nil? || !fresh || pages_read >= Protocol::MAX_PAGES

          [:until, oldest]
        end

        # What each relay of a read sent so far, page after page: a read on every relay cut short
        # keeps the pages of the relays still reading. Thread-safe.
        class Sent
          def initialize
            @mutex = Mutex.new
            @values = []
          end

          def <<(value)
            @mutex.synchronize { @values << value }
            self
          end

          def to_a
            @mutex.synchronize { @values.dup }
          end

          def empty?
            @mutex.synchronize { @values.empty? }
          end
        end

        # One connection to one relay, shared by every request of a pool: opened in a thread of its
        # own, which then reads its messages and hands each to the requests listening.
        class Connection
          attr_reader :url

          def initialize(url, websocket, timeout)
            @url = url
            @mutex = Mutex.new
            @changed = ConditionVariable.new
            @state = :connecting
            @socket = nil
            @send_mutex = Mutex.new
            @listeners = {}
            @deaths = {}
            @next = 0
            # NIP-42 answers, by public key and challenge: one AUTH per key per challenge.
            @auths = {}
            @challenge = nil
            @handshake = Cancellation.new
            @thread = Thread.new { run(websocket, timeout) }
            @thread.name = "sattleme-checkout relay"
            @thread.report_on_exception = false
          end

          # Waits until the connection is open: :open, :timeout once `deadline` passed; raises
          # Failure when it failed, as Stop#raise! does once `stop` stopped.
          def wait_open(stop, deadline)
            handle = stop.on_stop { @mutex.synchronize { @changed.broadcast } }
            @mutex.synchronize do
              loop do
                return :open if @state == :open
                raise Failure, "#{@url}: connection failed" if @state == :dead

                stop.raise! if stop.stopped?
                left = Clock.left(deadline)
                return :timeout if left.zero?

                @changed.wait(@mutex, left)
              end
            end
          ensure
            stop.remove(handle)
          end

          # Hears every message of the relay (in the connection's thread: quick) until #unlisten.
          def listen(&listener)
            @mutex.synchronize do
              next nil if @state == :dead

              @next += 1
              @listeners[@next] = listener
              @next
            end
          end

          def unlisten(handle)
            @mutex.synchronize { @listeners.delete(handle) } if handle
          end

          # Hears the end of the connection (at once when it is over already).
          def on_death(&listener)
            handle = @mutex.synchronize do
              next nil if @state == :dead

              @next += 1
              @deaths[@next] = listener
              @next
            end
            listener.call if handle.nil?
            handle
          end

          def remove_death(handle)
            @mutex.synchronize { @deaths.delete(handle) } if handle
          end

          # Sends a message (JSON); a failure to send ends the connection.
          def transmit(message)
            socket = @mutex.synchronize { @state == :open ? @socket : nil }
            return if socket.nil?

            @send_mutex.synchronize { socket.send_text(Json.generate(message)) }
          rescue StandardError
            die
          end

          # Answers the relay's NIP-42 challenge with `auth_key`: whether the relay took it, before
          # `deadline` (:timeout after). One AUTH per key and challenge, shared by the requests that
          # ask for it.
          def authenticate(auth_key, created_at, random, stop, deadline)
            public_key = Events.public_key(auth_key)
            challenge = nil
            created = false
            future = @mutex.synchronize do
              next nil if @state != :open || @challenge.nil?

              challenge = @challenge
              @auths["#{public_key}:#{challenge}"] ||= begin
                created = true
                Future.new
              end
            end
            return false if future.nil?

            send_auth(future, auth_key, challenge, created_at, random) if created
            return :timeout unless future.wait(stop, deadline)

            future.outcome[1] == true
          end

          # Waits until the connection's thread ended, `seconds` at most.
          def join(seconds)
            Internal.join(@thread, seconds)
          end

          # Closes the connection; every request still on it fails.
          def close
            @handshake.cancel
            socket = @mutex.synchronize { @socket }
            die
            begin
              socket&.close
            rescue StandardError
              nil
            end
          end

          private

          def send_auth(future, auth_key, challenge, created_at, random)
            auth = Events.sign(auth_key, random, created_at: created_at, kind: Protocol::AUTH_KIND,
                                                 tags: [["relay", @url], ["challenge", challenge]], content: "")
            listener = listen do |message|
              future.fulfill(message[2] == true) if message[0] == "OK" && message[1] == auth.id
            end
            death = on_death { future.fulfill(false) }
            future.on_settle do
              unlisten(listener)
              remove_death(death)
            end
            transmit(["AUTH", auth.to_h])
          end

          def run(websocket, timeout)
            socket = websocket.connect(@url, timeout: timeout, headers: { "User-Agent" => Protocol::USER_AGENT },
                                             cancellation: @handshake)
            opened = @mutex.synchronize do
              next false if @state == :dead

              @socket = socket
              @state = :open
              @changed.broadcast
              true
            end
            return socket.close unless opened

            while (text = socket.receive)
              dispatch(text)
            end
            die
          rescue StandardError
            die
          end

          def dispatch(text)
            text = Text.decode_utf8(text) unless Text.well_formed?(text)
            message = text && Json.parse_or(text)
            return unless message.is_a?(Array)

            listeners = @mutex.synchronize do
              # The last challenge counts.
              @challenge = message[1] if message[0] == "AUTH" && Text.well_formed?(message[1])
              @listeners.values
            end
            listeners.each { |listener| listener.call(message) }
          end

          def die
            deaths = @mutex.synchronize do
              next [] if @state == :dead

              @state = :dead
              @changed.broadcast
              @listeners.clear
              @deaths.values.tap { @deaths.clear }
            end
            deaths.each(&:call)
          end
        end

        # The relays of one call: one connection per relay, opened at its first request, kept for
        # the call's next requests, closed by #close or #release. Each request (a page of a read, a
        # publication) is bounded by `timeout_ms`, the wait for the connection included.
        class Pool
          def initialize(websocket:, timeout_ms:, stop:, random:, now:)
            @websocket = websocket
            @timeout = timeout_ms / 1000.0
            @stop = stop
            # What a publication's writes wait with: stopped by the call's cancellation alone, not by
            # its end, so that a publication's relays past its majority finish their own request
            # once the call returned (SPEC.md §13), each within its timeout.
            @tail = Stop.new(stop.cancellation)
            @random = random
            @now = now
            @mutex = Mutex.new
            @idle = ConditionVariable.new
            @connections = {}
            # Relays a request to which ran out of time or lost its connection in this call: a read
            # on every relay counts them as failed at once (SPEC.md §13).
            @failed = {}
            # The writes of publications not ended yet, by relay.
            @writes = Hash.new(0)
            @released = false
            @closed = false
          end

          # What every relay of `relays` holds that matches `filter`, at once, page after page when
          # `paged`. Returns as soon as a majority of them answered (the others' reads are dropped),
          # or once every relay answered or failed: Answers, the events kept of each relay that
          # answered, and whether a majority did (Relay.outcome). On every relay (`every_relay`), the
          # others are waited for one timeout more at most, the relays that failed earlier in the
          # call count as failed at once, and the pages of a relay still reading are kept, as events
          # only: it has not answered. Raises only Cancelled.
          def query_relays(relays, filter, auth_key, paged:, keep:, every_relay: false, stop: @stop)
            needed = Relay.majority(relays.size)
            asked = every_relay ? relays.reject { |relay| failed?(relay) } : relays
            states = initial_states(relays, asked)
            sent = asked.to_h { |relay| [relay, Sent.new] }
            answers = {}
            gather(asked, stop) do |inbox, read|
              read.call do |relay, read_stop|
                if paged
                  pages(relay, filter, auth_key, keep, read_stop, sent[relay])
                else
                  query(relay, filter, auth_key, keep, read_stop).filter_map { |entry| entry.value if entry.kept }
                end
              end
              grace = nil
              loop do
                tally = Relay.tally(states.values)
                break if tally.reading.zero?

                if tally.answered >= needed
                  break unless every_relay

                  grace ||= Clock.now + @timeout
                end
                message = inbox.pop(stop, grace)
                break if message.equal?(Inbox::TIMEOUT)

                relay, state, events = message
                answers[relay] = events if state == :ok
                states[relay] = state == :ok ? :incomplete : :failed
              end
            end
            keep_still_reading(answers, sent, states) if every_relay
            Answers.new(answers: answers, answered: Relay.outcome(states.values).answered)
          end

          # A complete read of `filter` on every relay of `relays` at once (SPEC.md §13, "Complete
          # reads"): pages of COMPLETE_READ_LIMIT events, the next one from the oldest second of the
          # last, until a page is not full. Returns as soon as a majority of them read completely
          # (the others' reads are dropped), or once every relay answered, stopped incomplete or
          # failed: CompleteAnswers (Relay.outcome), a relay whose read ended (complete or not)
          # having answered. On every relay, as #query_relays, and no wait once a majority can no
          # longer read completely: a relay still reading then has not answered either, its pages
          # kept as events only. Raises only Cancelled.
          def query_complete(relays, filter, auth_key, keep:, every_relay: false, stop: @stop)
            needed = Relay.majority(relays.size)
            asked = every_relay ? relays.reject { |relay| failed?(relay) } : relays
            states = initial_states(relays, asked)
            sent = asked.to_h { |relay| [relay, Sent.new] }
            answers = {}
            gather(asked, stop) do |inbox, read|
              read.call { |relay, read_stop| complete_pages(relay, filter, auth_key, keep, read_stop, sent[relay]) }
              grace = nil
              loop do
                tally = Relay.tally(states.values)
                break if tally.reading.zero?
                # On every relay, no wait once a majority can no longer read completely.
                break if every_relay && tally.complete + tally.reading < needed

                if tally.complete >= needed
                  break unless every_relay

                  grace ||= Clock.now + @timeout
                end
                message = inbox.pop(stop, grace)
                break if message.equal?(Inbox::TIMEOUT)

                relay, state, read_result = message
                if state == :ok
                  events, whole = read_result
                  answers[relay] = events
                  states[relay] = whole ? :complete : :incomplete
                else
                  states[relay] = :failed
                end
              end
            end
            keep_still_reading(answers, sent, states) if every_relay
            outcome = Relay.outcome(states.values)
            CompleteAnswers.new(answers: answers, answered: outcome.answered, complete: outcome.complete)
          end

          # Publishes `event` to every relay of `relays` at once. Returns once `quorum` relays took
          # it: the others, its tail, go on, each until its own request ends (NIP-42's one
          # authentication and the one write again included), within its timeout, the call returned
          # or not (SPEC.md §13). Raises Failure as soon as they no longer can, as Stop#raise! does
          # once `stop` stops: its writes are then stopped, and over, first.
          def publish_to_quorum(relays, event, auth_key, quorum, stop: @stop)
            publication = @tail.child
            inbox = Inbox.new
            writers = relays.map do |relay|
              # Counted at once: #release keeps the connection of a write, started or not.
              @mutex.synchronize { @writes[relay] += 1 }
              Internal.thread("sattleme-checkout relay write", call: false) do
                publish(relay, event, auth_key, publication)
                inbox << :taken
              rescue Stopped, Cancelled
                inbox << :stopped
              rescue StandardError
                inbox << :failed
              ensure
                written(relay)
              end
            end
            taken = 0
            failures = 0
            loop do
              if taken >= quorum
                writers = nil
                return true
              end
              raise Failure, "Fewer than #{quorum} relays took the event" if relays.size - failures < quorum

              message = inbox.pop(stop)
              message == :taken ? taken += 1 : failures += 1
            end
          ensure
            # It failed, or its call stopped or was cancelled: none of its writes is a tail.
            if writers
              publication.stop
              writers.each { |writer| Internal.join(writer) }
            end
          end

          # Whether a request to `relay` ran out of time or lost its connection in this call.
          def failed?(relay)
            @mutex.synchronize { @failed.key?(relay) }
          end

          # Closes every connection now (their requests fail), and waits until each one's thread
          # ended.
          def close
            connections = @mutex.synchronize do
              @closed = true
              @connections.values.tap { @connections.clear }
            end
            close_all(connections)
            @tail.release
          end

          # The call is done (SPEC.md §13): closes now each connection that no publication's write
          # still uses (the requests still on it fail), the others once those writes are over (the
          # tails of publications, each within its timeout), in a thread of their own: the call
          # returns at once. Nothing new may be asked of the pool but those writes.
          def release
            idle = @mutex.synchronize do
              @released = true
              @connections.select { |url, _| @writes[url].zero? }.each_key { |url| @connections.delete(url) }
            end
            close_all(idle.values)
            return close unless @mutex.synchronize { @writes.values.any?(&:positive?) }

            Internal.thread("sattleme-checkout relay release", call: false) do
              @mutex.synchronize { @idle.wait(@mutex) while @writes.values.any?(&:positive?) }
              close
            end
            nil
          end

          private

          def spawn(name, &)
            Internal.thread(name, call: false, &)
          end

          # Closes `connections`, then waits until each one's thread ended (STOP_GRACE_SECONDS at
          # most: a WebSocket client of the integrator's may not stop when it is told).
          def close_all(connections)
            connections.each(&:close)
            deadline = Clock.now + STOP_GRACE_SECONDS
            connections.each { |connection| connection.join(Clock.left(deadline)) }
          end

          # A write of a publication to `relay` ended.
          def written(relay)
            @mutex.synchronize do
              @writes[relay] -= 1
              @idle.broadcast
            end
          end

          # The read of each relay of `relays` as a read starts (Relay.tally): reading, but those left
          # out of `asked`, which failed earlier in the call.
          def initial_states(relays, asked)
            relays.to_h { |relay| [relay, asked.include?(relay) ? :reading : :failed] }
          end

          # Of a read on every relay, the pages that each relay still reading had sent: kept as
          # events, though it has not answered.
          def keep_still_reading(answers, sent, states)
            sent.each do |relay, events|
              answers[relay] = events.to_a if states[relay] == :reading && !events.empty?
            end
          end

          # Runs the reads of `asked` (each relay in its thread, with a stop of the read) and the
          # block that waits for them; once it returns, every read still running is stopped, and
          # waited for until it ended: when the read goes on, the relays it dropped ask nothing more
          # (no page, no authentication) and draw no random bytes for it (SPEC.md §13).
          def gather(asked, parent)
            stop = parent.child
            inbox = Inbox.new
            readers = []
            read = lambda do |&run|
              asked.each do |relay|
                readers << spawn("sattleme-checkout relay read") do
                  inbox << [relay, :ok, run.call(relay, stop)]
                rescue Stopped, Cancelled
                  nil
                rescue StandardError => e
                  inbox << [relay, :failed, e]
                end
              end
            end
            yield inbox, read
          ensure
            stop.stop
            readers.each(&:join)
          end

          # The stored events of `url` that match `filter`, page after page, as the merchant's app
          # reads them (SPEC.md §13, "Paged reads"); a failure after the first page keeps what was
          # read.
          def pages(url, filter, auth_key, keep, stop, events)
            seen = {}
            until_time = filter["until"]
            Protocol::MAX_PAGES.times do |page|
              begin
                answer = query(url, until_time.nil? ? filter : filter.merge("until" => until_time), auth_key, keep,
                               stop)
              rescue Failure
                raise if page.zero?

                break
              end
              until_time = Relay.after_paged_page(answer, seen, events)
              break if until_time.nil?
            end
            events.to_a
          end

          # The events of `url` that match `filter`, read completely if it can be: [events, whether
          # it was]. Raises when its first page fails (the relay failed); a later failure ends the
          # read incomplete.
          def complete_pages(url, filter, auth_key, keep, stop, events)
            seen = {}
            kept = []
            until_time = filter["until"]
            page = 1
            loop do
              page_filter = filter.merge("limit" => Protocol::COMPLETE_READ_LIMIT)
              page_filter["until"] = until_time unless until_time.nil?
              begin
                answer = query(url, page_filter, auth_key, keep, stop)
              rescue Failure
                raise if page == 1

                return [events.to_a, false]
              end
              before = kept.size
              step, value = Relay.after_complete_page(answer, seen, kept, page)
              kept[before..].each { |event| events << event }
              return [events.to_a, value] if step == :complete

              until_time = value
              page += 1
            end
          end

          # The stored events of `url` that match `filter`, as it sent them: their entries (the
          # event itself only when `keep` takes it), unchecked. At most MAX_EVENTS_PER_QUERY.
          # Authenticates when the relay asks (NIP-42).
          def query(url, filter, auth_key, keep, stop)
            request(url, stop) do |connection, deadline|
              closed, entries = ask(url, connection, filter, keep, stop, deadline)
              if closed&.start_with?(AUTH_REQUIRED) && authenticated?(url, connection, auth_key, stop, deadline)
                closed, entries = ask(url, connection, filter, keep, stop, deadline)
              end
              raise Failure, "#{url} closed the query: #{closed}" unless closed.nil?

              entries
            end
          end

          # One REQ: [nil, entries] once the relay sent EOSE or MAX_EVENTS_PER_QUERY events (then
          # CLOSE), or [reason, entries] when it CLOSED the query.
          def ask(url, connection, filter, keep, stop, deadline)
            # Nothing more once the read went on: not even the random bytes of a subscription id, nor
            # its REQ when it went on while they were drawn.
            stop.check!
            subscription = Text.hex(@random.call(8))
            stop.check!
            inbox = Inbox.new
            entries = []
            # The ids of this query's events so far: the first event of each is the one read.
            read = {}
            ending = nil
            mutex = Mutex.new
            listener = connection.listen do |message|
              next unless message[1] == subscription

              case message[0]
              when "EVENT"
                next if mutex.synchronize { ending }

                # What is kept of the event, as it comes (SPEC.md §13, Limits).
                entry = Relay.entry_of(message[2], keep, read)
                mutex.synchronize do
                  next if ending

                  entries << entry
                  if entries.size >= Protocol::MAX_EVENTS_PER_QUERY
                    ending = [:full]
                    inbox << :end
                  end
                end
              when "EOSE", "CLOSED"
                mutex.synchronize do
                  next if ending

                  ending = if message[0] == "EOSE"
                             [:eose]
                           else
                             [:closed, message[2].is_a?(String) ? message[2] : ""]
                           end
                  inbox << :end
                end
              end
            end
            death = connection.on_death { inbox << :dead }
            connection.transmit(["REQ", subscription, filter])
            outcome = inbox.pop(stop, deadline)
            fail!(url, "#{url}: no answer in time") if outcome.equal?(Inbox::TIMEOUT)
            fail!(url, "#{url}: connection failed") if outcome == :dead

            kind, reason = mutex.synchronize { ending }
            [kind == :closed ? reason : nil, mutex.synchronize { entries.dup }]
          ensure
            # Asked (none when the read went on before):
            if mutex
              connection.unlisten(listener)
              connection.remove_death(death)
              # Over this connection, which stays open for the call's next requests.
              connection.transmit(["CLOSE", subscription]) unless mutex.synchronize { ending }&.first == :closed
            end
          end

          # Publishes `event` to one relay, authenticating when it asks (NIP-42). Raises unless taken.
          def publish(url, event, auth_key, stop)
            request(url, stop) do |connection, deadline|
              accepted, reason = write(url, connection, event, stop, deadline)
              auth = !accepted && reason.start_with?(AUTH_REQUIRED)
              if auth && authenticated?(url, connection, auth_key, stop, deadline)
                accepted, reason = write(url, connection, event, stop, deadline)
              end
              raise Refusal.new(url, reason) unless accepted
            end
          end

          def write(url, connection, event, stop, deadline)
            stop.check!
            inbox = Inbox.new
            listener = connection.listen do |message|
              if message[0] == "OK" && message[1] == event.id
                inbox << [message[2] == true, Text.well_formed?(message[3]) ? message[3] : ""]
              end
            end
            death = connection.on_death { inbox << :dead }
            connection.transmit(["EVENT", event.to_h])
            answer = inbox.pop(stop, deadline)
            fail!(url, "#{url}: no answer in time") if answer.equal?(Inbox::TIMEOUT)
            fail!(url, "#{url}: connection failed") if answer == :dead

            answer
          ensure
            connection.unlisten(listener)
            connection.remove_death(death)
          end

          def authenticated?(url, connection, auth_key, stop, deadline)
            # No authentication once the read went on: neither the clock nor random bytes for it, nor
            # its AUTH when it went on while the clock was read.
            stop.check!
            created_at = @now.call
            stop.check!
            taken = connection.authenticate(auth_key, created_at, @random, stop, deadline)
            fail!(url, "#{url}: no answer in time") if taken == :timeout
            taken
          end

          # Runs the block over the connection to `url` once it is open, within the timeout: what it
          # gives. Raises Failure when the connection fails or the time runs out (the relay then
          # counts as failed in this call), as Stop#raise! does when `stop` stops.
          def request(url, stop)
            deadline = Clock.now + @timeout
            # No request once its read went on, nor once its call was cancelled.
            stop.check!
            connection = connection_for(url)
            begin
              state = connection.wait_open(stop, deadline)
            rescue Failure
              fail!(url, "#{url}: connection failed")
            end
            fail!(url, "#{url}: no answer in time") if state == :timeout
            yield connection, deadline
          end

          # Marks `url` failed in this call, and raises Failure with `message`.
          def fail!(url, message)
            @mutex.synchronize { @failed[url] = true }
            raise Failure, message
          end

          # The pool's connection to `url`, opened at its first request.
          def connection_for(url)
            @mutex.synchronize do
              # Released: only a publication's write still asks (its relay past its majority).
              raise Failure, "#{url}: the pool is closed" if @closed || (@released && @writes[url].zero?)

              @connections[url] ||= Connection.new(url, @websocket, @timeout)
            end
          rescue Failure
            raise
          rescue StandardError
            fail!(url, "#{url}: connection failed")
          end
        end
      end
    end
  end
end
