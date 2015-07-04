# frozen_string_literal: true

require_relative "worker"

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
        @workers = []
        @running = true
        @started = false
      end

      # Enqueue a task to be processed asynchronously.
      #
      # @param callable [#call, nil] a callable object (used by +<<+)
      # @yield the block to execute (takes precedence over +callable+)
      # @return [self]
      def push(callable = nil, &block)
        task = block || callable
        raise ArgumentError, "a block is required" unless task

        @mutex.synchronize do
          raise "queue is shut down" unless @running

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
          @workers.each(&:stop)
          @condition.broadcast
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
          @workers << Worker.new(@tasks, @mutex, @condition)
        end
        @started = true
      end
    end
  end
end
