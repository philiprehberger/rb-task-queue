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
          task = nil

          @mutex.synchronize do
            @condition.wait(@mutex) while @queue.empty? && @running
            break unless @running || !@queue.empty?

            task = @queue.shift
          end

          break unless task

          begin
            task.call
          rescue StandardError
            # Swallow exceptions to keep the worker alive.
            # In a future version this could be routed to an error handler.
          end
        end
      end
    end
  end
end
