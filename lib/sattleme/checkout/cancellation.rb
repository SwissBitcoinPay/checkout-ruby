# frozen_string_literal: true

module Sattleme
  module Checkout
    # A call cancelled by its Cancellation: it stopped its requests (SPEC.md §4). Never an Error of
    # SPEC.md §5: a program tells a cancellation from a failure.
    class Cancelled < StandardError
      # What the cancellation was given (`Cancellation#cancel(reason)`), nil when nothing.
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super(reason.is_a?(String) ? reason : "The call was cancelled")
      end
    end

    # The cancellation of one or more calls: every method takes one (`cancellation:`), and stops
    # once it is cancelled, raising Cancelled. Thread-safe: cancel it from any thread.
    #
    #   cancellation = Sattleme::Checkout::Cancellation.new
    #   Thread.new { sleep 5; cancellation.cancel("the customer left") }
    #   client.wait_for_payment(invoice, cancellation: cancellation)
    #
    #   # Or bounded in time:
    #   client.wait_for_payment(invoice, cancellation: Sattleme::Checkout::Cancellation.after(600))
    class Cancellation
      # A cancellation that cancels itself `seconds` from now (with `reason`), unless it was before.
      # One thread of the gem waits for every such deadline of the process, while one is pending:
      # a cancellation cancelled before its time is forgotten at once.
      def self.after(seconds, reason = "Timed out")
        raise ArgumentError, "seconds: a number of seconds" unless seconds.is_a?(Numeric) && seconds >= 0

        cancellation = new
        Timer.schedule(cancellation, Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds, reason)
        cancellation
      end

      # The deadlines of Cancellation.after: one thread cancels each in its time, the earliest first,
      # and ends once none is left (it starts again with the next one).
      module Timer
        @mutex = Mutex.new
        @changed = ConditionVariable.new
        # Each cancellation waiting for its time: [its deadline (the monotonic clock), its reason].
        @pending = {}.compare_by_identity
        @thread = nil

        class << self
          def schedule(cancellation, deadline, reason)
            @mutex.synchronize do
              @pending[cancellation] = [deadline, reason]
              @thread = start unless @thread&.alive?
              @changed.signal
            end
            # Cancelled otherwise: nothing left to wait for.
            cancellation.on_cancel { forget(cancellation) }
          end

          private

          def forget(cancellation)
            @mutex.synchronize do
              @pending.delete(cancellation)
              @changed.signal
            end
          end

          def start
            thread = Thread.new { run }
            thread.name = "sattleme-checkout timer"
            thread.report_on_exception = false
            thread
          end

          def run
            while (passed = due)
              passed.each { |cancellation, reason| cancellation.cancel(reason) }
            end
          end

          # Waits until a deadline passed, then forgets those that passed and gives them with their
          # reasons; nil once none is left, and the thread ends.
          def due
            @mutex.synchronize do
              loop do
                if @pending.empty?
                  @thread = nil
                  return nil
                end
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                passed = @pending.select { |_, (deadline, _)| deadline <= now }
                unless passed.empty?
                  passed.each_key { |cancellation| @pending.delete(cancellation) }
                  return passed.map { |cancellation, (_, reason)| [cancellation, reason] }
                end
                @changed.wait(@mutex, @pending.each_value.map(&:first).min - now)
              end
            end
          end
        end
      end
      private_constant :Timer

      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @cancelled = false
        @reason = nil
        @callbacks = {}
        @next = 0
      end

      # Cancels the calls that take this cancellation, with `reason` (a String becomes the
      # message of their Cancelled). Idempotent: only the first reason counts.
      def cancel(reason = nil)
        callbacks = @mutex.synchronize do
          return self if @cancelled

          @cancelled = true
          @reason = reason
          @condition.broadcast
          @callbacks.values.tap { @callbacks.clear }
        end
        callbacks.each do |callback|
          callback.call
        rescue StandardError
          # The gem's own callbacks wake a wait or close a socket: none of them is the caller's
          # concern, nor may it stop the others.
          nil
        end
        self
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      # The reason it was cancelled with; nil before (or when none was given).
      def reason
        @mutex.synchronize { @reason }
      end

      # Raises Cancelled when it is cancelled.
      def raise_if_cancelled
        raise Cancelled, reason if cancelled?
      end

      # Waits until it is cancelled, `seconds` at most (nil: for ever): whether it is.
      def wait(seconds = nil)
        deadline = seconds && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)
        @mutex.synchronize do
          until @cancelled
            left = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
            break if left && left <= 0

            @condition.wait(@mutex, left)
          end
          @cancelled
        end
      end

      # Runs `block` once this is cancelled, in the thread that cancels it (at once, here, when it
      # is already): a handle that #remove forgets. For the gem's own waits.
      def on_cancel(&block)
        handle = @mutex.synchronize do
          next nil if @cancelled

          @next += 1
          @callbacks[@next] = block
          @next
        end
        block.call if handle.nil?
        handle
      end

      # Forgets a callback #on_cancel gave the handle of.
      def remove(handle)
        @mutex.synchronize { @callbacks.delete(handle) } if handle
        nil
      end

      def inspect
        "#<#{self.class.name}#{" cancelled" if cancelled?}>"
      end
      alias to_s inspect

      # Never cancelled: the cancellation of a call given none.
      NONE = new.tap do |none|
        def none.cancel(_reason = nil) = raise(FrozenError, "Cancellation::NONE is never cancelled")

        # Nothing to remember: it never runs a callback.
        def none.on_cancel = nil
      end
    end
  end
end
