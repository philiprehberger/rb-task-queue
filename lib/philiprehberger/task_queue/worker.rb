# frozen_string_literal: true

module Philiprehberger
  module TaskQueue
    # Worker processes tasks from the queue in a dedicated thread.
    class Worker
      attr_reader :thread

      def initialize(queue, mutex, condition)
        @queue = queue
        @mutex = mutex
        @condition = condition
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
        end
      end

      def next_task
        @mutex.synchronize do
          @condition.wait(@mutex) while @queue.empty? && @running
          return nil unless @running || !@queue.empty?

          @queue.shift
        end
      end

      def execute(task)
        task.call
      rescue StandardError
        # Swallow exceptions to keep the worker alive.
      end
    end
  end
end
