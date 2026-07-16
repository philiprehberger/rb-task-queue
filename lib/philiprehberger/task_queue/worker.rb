# frozen_string_literal: true

module Philiprehberger
  module TaskQueue
    # Worker processes tasks from the queue in a dedicated thread.
    class Worker
      attr_reader :thread

      def initialize(queue, mutex, condition, context:)
        @queue = queue
        @mutex = mutex
        @condition = condition
        @stats = context[:stats]
        @error_handler = context[:error_handler]
        @complete_handler = context[:complete_handler]
        @drain_condition = context[:drain_condition]
        @paused = context[:paused]
        @pause_condition = context[:pause_condition]
        @max_retries = context[:max_retries]
        @retry_backoff = context[:retry_backoff]
        @retry_base_delay = context[:retry_base_delay]
        @running = true
        @thread = Thread.new { run }
      end

      # Signal the worker to stop after its current task completes.
      #
      # @return [void]
      def stop
        @running = false
        nil
      end

      # Whether the underlying worker thread is still alive.
      #
      # @return [Boolean]
      def alive?
        @thread&.alive? || false
      end

      private

      def run
        loop do
          entry = next_task
          break unless entry

          execute(entry)
          @mutex.synchronize { @drain_condition.broadcast }
        end
      end

      def next_task
        @mutex.synchronize do
          loop do
            @condition.wait(@mutex) while @queue.empty? && @running
            return nil unless @running || !@queue.empty?

            @pause_condition.wait(@mutex) while @paused&.call && @running
            return nil unless @running || !@queue.empty?

            # Another worker may have taken the last task while we waited.
            next if @queue.empty?

            @stats[:in_flight] += 1
            return dequeue
          end
        end
      end

      # Remove and return the highest-priority pending entry. Ties are broken by
      # insertion order (FIFO), so equal-priority tasks keep their arrival order.
      def dequeue
        best = 0
        index = 1
        while index < @queue.size
          best = index if @queue[index].priority > @queue[best].priority
          index += 1
        end
        @queue.delete_at(best)
      end

      def execute(entry)
        result = entry.callable.call
        record_completion(result)
      rescue StandardError => e
        handle_failure(entry, e)
      end

      def record_completion(result)
        @mutex.synchronize do
          @stats[:completed] += 1
          @stats[:in_flight] -= 1
        end
        invoke_complete(result)
      end

      def handle_failure(entry, error)
        entry.attempts += 1
        attempt = entry.attempts
        invoke_error(error, entry.callable, attempt)

        if attempt <= @max_retries
          requeue(entry, attempt)
        else
          record_failure
        end
      end

      def requeue(entry, attempt)
        delay = backoff_delay(attempt)
        sleep(delay) if delay.positive?
        @mutex.synchronize do
          @stats[:in_flight] -= 1
          @stats[:retried] += 1
          @queue << entry
          @condition.signal
        end
      end

      def record_failure
        @mutex.synchronize do
          @stats[:failed] += 1
          @stats[:in_flight] -= 1
        end
      end

      def backoff_delay(attempt)
        case @retry_backoff
        when :fixed then @retry_base_delay
        when :exponential then @retry_base_delay * (2**(attempt - 1))
        else 0
        end
      end

      # User callbacks run outside the stats-accounting path and are each
      # isolated in their own rescue, so a raising callback can neither corrupt
      # the counters nor unwind the worker thread.
      def invoke_complete(result)
        handler = @complete_handler.call
        handler&.call(result)
      rescue StandardError
        nil
      end

      def invoke_error(error, task, attempt)
        handler = @error_handler.call
        handler&.call(error, task, attempt)
      rescue StandardError
        nil
      end
    end
  end
end
