# frozen_string_literal: true

module Philiprehberger
  module TaskQueue
    # Worker processes tasks from the queue in a dedicated thread.
    class Worker
      attr_reader :thread

      def initialize(queue, mutex, condition, stats:, error_handler:, drain_condition:)
        @queue = queue
        @mutex = mutex
        @condition = condition
        @stats = stats
        @error_handler = error_handler
        @drain_condition = drain_condition
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

          @stats[:in_flight] += 1
          @queue.shift
        end
      end

      def execute(task)
        task.call
        @mutex.synchronize do
          @stats[:completed] += 1
          @stats[:in_flight] -= 1
        end
      rescue StandardError => e
        @mutex.synchronize do
          @stats[:failed] += 1
          @stats[:in_flight] -= 1
        end
        @error_handler&.call(e, task)
      end
    end
  end
end
