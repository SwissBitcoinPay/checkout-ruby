# frozen_string_literal: true

module Sattleme
  module Checkout
    # The gem's own workings: none of it is API, any of it may change in any version.
    module Internal
      # A wait ended by an internal stop: a read that went on without this relay, a part that is no
      # longer needed. Never escapes a call. An Exception, not a StandardError, so that no
      # `rescue StandardError` takes it for a failure.
      class Stopped < Exception # rubocop:disable Lint/InheritException
      end

      # How long, once it stopped what a client runs for it (an HTTP request, a WebSocket), the gem
      # waits for that thread to end: a client that stops when it is told (its cancellation, its
      # socket closed), as the gem's own do, has ended by then; one that does not is left behind,
      # never the call.
      STOP_GRACE_SECONDS = 0.5

      # The monotonic clock, in seconds: every timeout (never the injected `now`, the protocol's
      # dates).
      module Clock
        module_function

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Seconds left until `deadline` (nil: no deadline), never below 0.
        def left(deadline)
          deadline && [deadline - now, 0.0].max
        end
      end

      # What stops a task: the cancellation of its call (the caller's, which makes every wait raise
      # Cancelled), and the stops of the tasks it runs within (which make it raise Stopped). Each
      # wait of the gem watches one; a task's own work ends with #release.
      class Stop
        attr_reader :cancellation

        def initialize(cancellation, parent = nil)
          @cancellation = cancellation
          @own = Cancellation.new
          @links = []
          link(cancellation)
          link(parent.token) if parent
        end

        # A stop that stops with this one, and on its own.
        def child
          Stop.new(@cancellation, self)
        end

        # Stops what waits on it (and its children).
        def stop
          @own.cancel
          release
        end

        def stopped?
          @own.cancelled?
        end

        # Whether the call was cancelled (a wait then raises Cancelled).
        def cancelled?
          @cancellation.cancelled?
        end

        def on_stop(&)
          @own.on_cancel(&)
        end

        def remove(handle)
          @own.remove(handle)
        end

        # Runs the block with a Cancellation that is cancelled once this stops (with the call's
        # reason, when the call was cancelled): what code of the integrator's knows of a stop.
        def as_cancellation
          cancellation = Cancellation.new
          handle = on_stop { cancellation.cancel(@cancellation.reason) }
          begin
            yield cancellation
          ensure
            remove(handle)
          end
        end

        # Raises Cancelled when the call was cancelled, else Stopped.
        def raise!
          raise Cancelled, @cancellation.reason if @cancellation.cancelled?

          raise Stopped
        end

        # Raises as #raise! does when it is stopped.
        def check!
          raise! if stopped? || cancelled?
        end

        # Forgets its links to its parents (its work is done): a long-lived cancellation of the
        # caller never piles up callbacks.
        def release
          links = @links
          @links = []
          links.each { |token, handle| token.remove(handle) }
        end

        protected

        def token
          @own
        end

        private

        def link(token)
          handle = token.on_cancel { @own.cancel }
          @links << [token, handle] if handle
        end
      end

      # The threads of one call (SPEC.md §4, §13): every thread the gem starts while the call runs,
      # from any thread of the call (Internal.thread), is one of them, and the call waits for each
      # to end before it returns: once it returned, nothing it started runs on. Only the relays of a
      # publication past its majority (Relay::Pool, the publication's tail) may finish their own
      # request after it, each within its timeout: their threads are no call's.
      class CallThreads
        KEY = :sattleme_checkout_call_threads
        private_constant :KEY

        # The threads of the call this thread runs for; nil outside a call.
        def self.current
          Thread.current[KEY]
        end

        # Runs the block for the call whose threads are `threads` (nil: for none).
        def self.within(threads)
          previous = Thread.current[KEY]
          Thread.current[KEY] = threads
          begin
            yield
          ensure
            Thread.current[KEY] = previous
          end
        end

        def initialize
          @mutex = Mutex.new
          @threads = []
        end

        def <<(thread)
          @mutex.synchronize { @threads << thread }
          self
        end

        # Waits until each of its threads ended, those they start meanwhile too.
        def wait
          loop do
            running = @mutex.synchronize { @threads = @threads.select(&:alive?) }
            return if running.empty?

            running.each { |thread| Internal.join(thread) }
          end
        end
      end

      # The result of a task running in a thread of its own, settled once: its value or its error,
      # which #value raises in the thread that waits.
      class Future
        # Runs `block` in a new thread (Internal.thread: one of its call's, unless `call` is false);
        # its value, or the exception it raised, settles the future.
        def self.spawn(name = "sattleme-checkout", call: true, &block)
          future = new
          future.thread = Internal.thread(name, call: call) do
            future.fulfill(block.call)
          rescue Exception => e # rubocop:disable Lint/RescueException -- carried to the waiter
            future.reject(e)
          end
          future
        end

        # A future already settled with `value`.
        def self.resolved(value)
          new.tap { |future| future.fulfill(value) }
        end

        attr_accessor :thread

        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @state = :pending
          @result = nil
          @waiters = []
        end

        def fulfill(value)
          settle(:ok, value)
        end

        def reject(error)
          settle(:error, error)
        end

        def settled?
          @mutex.synchronize { @state != :pending }
        end

        # Waits until it is settled, `deadline` (Clock) passed, or `stop` stopped (then raises as
        # Stop#raise! does): whether it is settled.
        def wait(stop, deadline = nil)
          handle = stop&.on_stop { @mutex.synchronize { @condition.broadcast } }
          @mutex.synchronize do
            while @state == :pending
              stop&.raise! if stop&.stopped?
              left = Clock.left(deadline)
              return false if left&.zero?

              @condition.wait(@mutex, left)
            end
            true
          end
        ensure
          stop&.remove(handle)
        end

        # Its value, once settled; raises its error.
        def value(stop)
          wait(stop)
          state, result = outcome
          raise result if state == :error

          result
        end

        # [:ok, value] or [:error, error]; nil while pending.
        def outcome
          @mutex.synchronize { @state == :pending ? nil : [@state, @result] }
        end

        # Calls `block` with the outcome once settled (at once when it is), in the settling thread.
        def on_settle(&block)
          now = @mutex.synchronize do
            next true unless @state == :pending

            @waiters << block
            false
          end
          block.call(*outcome) if now
        end

        private

        # Settles it once: a later outcome is dropped.
        def settle(state, result)
          waiters = @mutex.synchronize do
            next [] unless @state == :pending

            @state = state
            @result = result
            @condition.broadcast
            @waiters.tap { @waiters = [] }
          end
          waiters.each { |waiter| waiter.call(state, result) }
          nil
        end
      end

      # A queue of messages between threads, popped with a deadline and a stop.
      class Inbox
        # Pushed when a stop wakes the waiter.
        WAKE = Object.new.freeze
        # What #pop gives when the deadline passed.
        TIMEOUT = Object.new.freeze

        def initialize
          @queue = Thread::Queue.new
        end

        def push(message)
          @queue << message
        end
        alias << push

        # The next message; TIMEOUT once `deadline` (Clock, nil: none) passed; raises as Stop#raise!
        # does once `stop` stopped (nil: none).
        def pop(stop, deadline = nil)
          handle = stop&.on_stop { @queue << WAKE }
          loop do
            stop&.raise! if stop&.stopped?
            left = Clock.left(deadline)
            return TIMEOUT if left&.zero?

            message = @queue.pop(timeout: left)
            return TIMEOUT if message.nil? && deadline
            next if message.equal?(WAKE) || message.nil?

            return message
          end
        ensure
          stop&.remove(handle)
        end
      end

      # One holder at a time per key (an order's reference…), within one client; the wait for it
      # ends with the caller's cancellation.
      class KeyedLocks
        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @held = {}
        end

        # Runs `block` holding the lock of `key`.
        def synchronize(key, stop)
          acquire(key, stop)
          begin
            yield
          ensure
            release(key)
          end
        end

        private

        def acquire(key, stop)
          handle = stop.on_stop { @mutex.synchronize { @condition.broadcast } }
          @mutex.synchronize do
            while @held.key?(key)
              stop.raise! if stop.stopped?
              @condition.wait(@mutex)
            end
            stop.raise! if stop.stopped?
            @held[key] = true
          end
        ensure
          stop.remove(handle)
        end

        def release(key)
          @mutex.synchronize do
            @held.delete(key)
            @condition.broadcast
          end
        end
      end

      # The outcome of a part (SPEC.md §31: a part that fails is its error, never the check's): its
      # value, or the error it failed with.
      Settled = Data.define(:value, :error) do
        def self.ok(value) = new(value: value, error: nil)
        def self.failed(error) = new(value: nil, error: error)
        def ok? = error.nil?
      end

      module_function

      # Runs `block` in a thread named `name`: a thread of the call this thread runs for
      # (CallThreads), which waits for it to end before it returns; with `call` false, of no call
      # (one whose end is waited for otherwise, or a publication's tail), nor are the threads it
      # starts.
      def thread(name, call: true, &block)
        threads = call ? CallThreads.current : nil
        thread = Thread.new { CallThreads.within(threads, &block) }
        thread.name = name
        thread.report_on_exception = false
        threads&.<<(thread)
        thread
      end

      # Waits until `thread` ended, `seconds` at most (nil: for as long as it runs); what it raised
      # is for whoever waits for its outcome, never for this.
      def join(thread, seconds = nil)
        thread.join(seconds)
      rescue Exception # rubocop:disable Lint/RescueException -- its outcome is not the joiner's
        nil
      end

      # The outcome of `future`, waited for with `stop`, as a Settled; a cancellation (Cancelled) or
      # an internal stop (Stopped) is raised, never settled.
      def settle(future, stop)
        future.wait(stop)
        state, result = future.outcome
        return Settled.ok(result) if state == :ok
        raise result if result.is_a?(Cancelled) || result.is_a?(Stopped)

        Settled.failed(result)
      end

      # Runs `block` in a thread of its own, its outcome settled: the Future of a Settled.
      def settled(name = "sattleme-checkout part", &block)
        Future.spawn(name) do
          Settled.ok(block.call)
        rescue Cancelled, Stopped
          raise
        rescue StandardError => e
          Settled.failed(e)
        end
      end

      # The values of `futures`, as Promise.all gives them: raises the first error (the first in
      # time), as soon as one fails.
      def all(futures, stop)
        inbox = Inbox.new
        futures.each_with_index do |future, index|
          future.on_settle { |state, result| inbox << [index, state, result] }
        end
        values = Array.new(futures.size)
        futures.size.times do
          index, state, result = inbox.pop(stop)
          raise result if state == :error

          values[index] = result
        end
        values
      end

      # The results of `futures`, each waited for with `stop`: [:ok, value] or [:error, error].
      def settle_all(futures, stop)
        futures.map do |future|
          future.wait(stop)
          future.outcome
        end
      end

      # `run` on each of `items`, `limit` at a time, each in a thread: their outcomes, in order.
      def settle_each(items, limit, stop, &run)
        outcomes = Array.new(items.size)
        queue = Thread::Queue.new
        items.each_with_index { |item, index| queue << [item, index] }
        queue.close
        workers = Array.new([limit, items.size].min) do
          Future.spawn("sattleme-checkout check") do
            while (job = queue.pop)
              item, index = job
              outcomes[index] = begin
                [:ok, run.call(item)]
              rescue StandardError, Cancelled => e
                [:error, e]
              end
            end
          end
        end
        workers.each { |worker| worker.value(stop) }
        outcomes
      end
    end
  end
end
