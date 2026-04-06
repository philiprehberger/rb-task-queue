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
        @running = true
        @thread = Thread.new { run }
      end

      def stop
        @running = false
      end

      def alive?
        @thread&.alive? || false
      end

      private

      def run
        loop do
          task = next_task
          break unless task

          execute(task)
          @mutex.synchronize { @drain_condition.broadcast }
        end
      end

      def next_task
        @mutex.synchronize do
          @condition.wait(@mutex) while @queue.empty? && @running
          return nil unless @running || !@queue.empty?

          @pause_condition.wait(@mutex) while @paused&.call && @running
          return nil unless @running || !@queue.empty?

          @stats[:in_flight] += 1
          @queue.shift
        end
      end

      def execute(task)
        result = task.call
        record_completion(result)
      rescue StandardError => e
        record_failure(e, task)
      end

      def record_completion(result)
        @mutex.synchronize do
          @stats[:completed] += 1
          @stats[:in_flight] -= 1
        end
        @complete_handler&.call(result)
      end

      def record_failure(error, task)
        @mutex.synchronize do
          @stats[:failed] += 1
          @stats[:in_flight] -= 1
        end
        @error_handler&.call(error, task)
      end
    end
  end
end
