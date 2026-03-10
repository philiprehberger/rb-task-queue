# frozen_string_literal: true

require_relative "task_queue/version"
require_relative "task_queue/queue"

module Philiprehberger
  module TaskQueue
    # Convenience constructor.
    #
    # @param options [Hash] forwarded to {Queue#initialize}
    # @return [Queue]
    def self.new(**options)
      Queue.new(**options)
    end
  end
end
