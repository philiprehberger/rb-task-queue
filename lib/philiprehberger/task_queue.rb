# frozen_string_literal: true

require_relative 'task_queue/version'
require_relative 'task_queue/queue'

module Philiprehberger
  module TaskQueue
    # Base error class for all TaskQueue-specific errors.
    class Error < StandardError; end

    # Convenience constructor.
    #
    # @param options [Hash] forwarded to {Queue#initialize}
    # @return [Queue]
    def self.new(**options)
      Queue.new(**options)
    end
  end
end
