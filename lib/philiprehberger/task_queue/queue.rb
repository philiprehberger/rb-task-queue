# frozen_string_literal: true

require_relative 'worker'

module Philiprehberger
  module TaskQueue
    # Internal representation of an enqueued task, carrying its priority and the
    # number of attempts made so far (for retry accounting).
    Entry = Struct.new(:callable, :priority, :attempts)

    # In-process async job queue with concurrency control.
    #
    # Tasks are enqueued as blocks or callable objects and executed by a pool of
    # worker threads. The queue is fully thread-safe.
    class Queue
      # Supported retry backoff policies.
      BACKOFF_POLICIES = %i[none fixed exponential].freeze

      # @return [Integer] the maximum number of concurrent worker threads
      attr_reader :concurrency

      # @param concurrency [Integer] maximum number of concurrent worker threads
      # @param max_retries [Integer] how many times a failing task is requeued
      #   before it is counted as failed (default +0+, i.e. no retries)
      # @param retry_backoff [Symbol] delay policy between retries — one of
      #   +:none+, +:fixed+, or +:exponential+
      # @param retry_base_delay [Numeric] base delay in seconds used by the
      #   +:fixed+ and +:exponential+ backoff policies
      # @raise [ArgumentError] if +max_retries+ is negative or +retry_backoff+
      #   is not a recognized policy
      def initialize(concurrency: 4, max_retries: 0, retry_backoff: :none, retry_base_delay: 0.1)
        @concurrency = concurrency
        @max_retries = max_retries
        @retry_backoff = retry_backoff
        @retry_base_delay = retry_base_delay
        validate_retry_options!
        @tasks = []
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @drain_condition = ConditionVariable.new
        @workers = []
        @running = true
        @started = false
        @paused = false
        @pause_condition = ConditionVariable.new
        @error_handler = nil
        @complete_handler = nil
        @stats = { completed: 0, failed: 0, in_flight: 0, retried: 0 }
      end

      # Register a callback invoked when a task raises an exception.
      #
      # The callback receives the exception, the task that raised it, and the
      # attempt number (1 for the first try, incrementing on each retry). It
      # fires on every failed attempt, including the ones that are retried.
      #
      # The callback may be registered at any time — even after tasks have been
      # pushed — and is read live when the task runs.
      #
      # @yield [exception, task, attempt] called on each task failure
      # @return [self]
      def on_error(&block)
        @mutex.synchronize { @error_handler = block }
        self
      end

      # Register a callback invoked after each successful task completion.
      #
      # The callback receives the return value of the completed task.
      #
      # @yield [result] called on task success
      # @return [self]
      def on_complete(&block)
        @mutex.synchronize { @complete_handler = block }
        self
      end

      # Return statistics about processed tasks.
      #
      # @return [Hash{Symbol => Integer}] counts for :completed, :failed,
      #   :pending, :in_flight, and :retried (total retry attempts made)
      def stats
        @mutex.synchronize do
          { completed: @stats[:completed], failed: @stats[:failed], pending: @tasks.size,
            in_flight: @stats[:in_flight], retried: @stats[:retried] }
        end
      end

      # Pause the queue so workers stop dequeuing new tasks.
      #
      # In-flight tasks will finish, but no new tasks will be picked up until
      # +resume+ is called.
      #
      # @return [self]
      def pause
        @mutex.synchronize do
          @paused = true
        end
        self
      end

      # Resume a paused queue, waking workers to continue processing.
      #
      # @return [self]
      def resume
        @mutex.synchronize do
          @paused = false
          @pause_condition.broadcast
        end
        self
      end

      # Whether the queue is currently paused.
      #
      # @return [Boolean]
      def paused?
        @mutex.synchronize { @paused }
      end

      # Remove all pending tasks from the queue.
      #
      # @return [Integer] number of tasks cleared
      def clear
        @mutex.synchronize do
          count = @tasks.size
          @tasks.clear
          count
        end
      end

      # Atomically zero the +completed+ and +failed+ counters.
      #
      # Leaves +pending+, +in_flight+, worker threads, and registered callbacks
      # untouched. Useful for resetting metrics between reporting intervals
      # without shutting down the pool.
      #
      # @return [self]
      def stats_reset!
        @mutex.synchronize do
          @stats[:completed] = 0
          @stats[:failed] = 0
        end
        self
      end

      # Block until all pending tasks are complete without shutting down.
      #
      # @param timeout [Numeric] seconds to wait before returning
      # @return [void]
      def drain(timeout: 30)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @mutex.synchronize do
          while !@tasks.empty? || @stats[:in_flight].positive?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @drain_condition.wait(@mutex, remaining)
          end
        end
        nil
      end

      # Enqueue a task to be processed asynchronously.
      #
      # Higher-priority tasks are dequeued before lower-priority ones; tasks
      # that share a priority run in FIFO (insertion) order. The +<<+ alias
      # always enqueues at the default priority of +0+.
      #
      # @param callable [#call, nil] a callable object (used by +<<+)
      # @param priority [Integer] dequeue priority; higher runs first (default +0+)
      # @yield the block to execute (takes precedence over +callable+)
      # @return [self]
      def push(callable = nil, priority: 0, &block)
        task = block || callable
        raise ArgumentError, 'a block is required' unless task

        @mutex.synchronize do
          raise 'queue is shut down' unless @running

          start_workers unless @started
          @tasks << Entry.new(task, priority, 0)
          @condition.signal
        end

        self
      end

      alias << push

      # Number of pending (not yet started) tasks.
      #
      # @return [Integer]
      def size
        @mutex.synchronize { @tasks.size }
      end

      # Whether there are no pending tasks waiting to be started.
      #
      # In-flight tasks are not considered; use +drain+ to wait for them.
      #
      # @return [Boolean]
      def empty?
        @mutex.synchronize { @tasks.empty? }
      end

      # Whether the queue has any pending tasks or any in-flight tasks.
      #
      # Convenient inverse of "idle" for callers polling without going
      # through +stats+. Equivalent to: +!empty? || in_flight > 0+.
      #
      # @return [Boolean]
      def busy?
        @mutex.synchronize { !@tasks.empty? || @stats[:in_flight].positive? }
      end

      # Whether the queue is accepting new tasks.
      #
      # @return [Boolean]
      def running?
        @mutex.synchronize { @running }
      end

      # Gracefully shut down the queue.
      #
      # Signals all workers to finish their current task and drain remaining
      # tasks, then waits up to +timeout+ seconds for threads to exit.
      #
      # @param timeout [Numeric] seconds to wait for workers to finish
      # @return [void]
      def shutdown(timeout: 30)
        signal_shutdown
        wait_for_workers(timeout)
        nil
      end

      private

      def signal_shutdown
        @mutex.synchronize do
          return unless @running

          @running = false
          @paused = false
          @workers.each(&:stop)
          @condition.broadcast
          @pause_condition.broadcast
        end
      end

      def wait_for_workers(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @workers.each do |worker|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          worker.thread&.join([remaining, 0].max)
        end
      end

      def start_workers
        @concurrency.times do
          @workers << Worker.new(
            @tasks, @mutex, @condition,
            context: { stats: @stats,
                       error_handler: -> { @error_handler },
                       complete_handler: -> { @complete_handler },
                       drain_condition: @drain_condition,
                       paused: -> { @paused }, pause_condition: @pause_condition,
                       max_retries: @max_retries, retry_backoff: @retry_backoff,
                       retry_base_delay: @retry_base_delay }
          )
        end
        @started = true
      end

      def validate_retry_options!
        raise ArgumentError, 'max_retries must be >= 0' if @max_retries.negative?
        return if BACKOFF_POLICIES.include?(@retry_backoff)

        raise ArgumentError, "unknown retry_backoff: #{@retry_backoff.inspect} (expected one of #{BACKOFF_POLICIES})"
      end
    end
  end
end
