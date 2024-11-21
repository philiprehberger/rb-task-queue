# frozen_string_literal: true

require_relative 'worker'

module Philiprehberger
  module TaskQueue
    # In-process async job queue with concurrency control.
    #
    # Tasks are enqueued as blocks or callable objects and executed by a pool of
    # worker threads. The queue is fully thread-safe.
    class Queue
      # @param concurrency [Integer] maximum number of concurrent worker threads
      def initialize(concurrency: 4)
        @concurrency = concurrency
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
        @stats = { completed: 0, failed: 0, in_flight: 0 }
      end

      # Register a callback invoked when a task raises an exception.
      #
      # The callback receives the exception and the task that raised it.
      #
      # @yield [exception, task] called on task failure
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
      # @return [Hash{Symbol => Integer}] counts for :completed, :failed, :pending, :in_flight
      def stats
        @mutex.synchronize do
          { completed: @stats[:completed], failed: @stats[:failed], pending: @tasks.size,
            in_flight: @stats[:in_flight] }
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
      # @param callable [#call, nil] a callable object (used by +<<+)
      # @yield the block to execute (takes precedence over +callable+)
      # @return [self]
      def push(callable = nil, &block)
        task = block || callable
        raise ArgumentError, 'a block is required' unless task

        @mutex.synchronize do
          raise 'queue is shut down' unless @running

          start_workers unless @started
          @tasks << task
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
            context: { stats: @stats, error_handler: @error_handler,
                       complete_handler: @complete_handler, drain_condition: @drain_condition,
                       paused: -> { @paused }, pause_condition: @pause_condition }
          )
        end
        @started = true
      end
    end
  end
end
