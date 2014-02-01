# frozen_string_literal: true

require "spec_helper"

RSpec.describe Philiprehberger::TaskQueue do
  describe ".new" do
    it "returns a Queue instance" do
      queue = described_class.new
      expect(queue).to be_a(Philiprehberger::TaskQueue::Queue)
      queue.shutdown(timeout: 5)
    end
  end

  describe Philiprehberger::TaskQueue::Queue do
    subject(:queue) { described_class.new(concurrency: concurrency) }

    let(:concurrency) { 2 }

    after { queue.shutdown(timeout: 5) }

    describe "#push" do
      it "enqueues and executes a task" do
        result = Concurrent::Array.new rescue []
        mutex = Mutex.new

        queue.push do
          mutex.synchronize { result << :done }
        end

        sleep 0.1
        expect(result).to include(:done)
      end

      it "raises ArgumentError when no block is given" do
        expect { queue.push }.to raise_error(ArgumentError, "a block is required")
      end

      it "raises when queue is shut down" do
        queue.shutdown(timeout: 5)
        expect { queue.push { nil } }.to raise_error(RuntimeError, "queue is shut down")
      end
    end

    describe "#<<" do
      it "is an alias for push" do
        results = []
        mutex = Mutex.new

        queue << proc {
          mutex.synchronize { results << :aliased }
        }

        sleep 0.1
        expect(results).to include(:aliased)
      end
    end

    describe "#size" do
      it "returns 0 for an empty queue" do
        expect(queue.size).to eq(0)
      end
    end

    describe "#running?" do
      it "returns true before shutdown" do
        expect(queue.running?).to be true
      end

      it "returns false after shutdown" do
        queue.shutdown(timeout: 5)
        expect(queue.running?).to be false
      end
    end

    describe "#shutdown" do
      it "waits for in-flight tasks to complete" do
        completed = []
        mutex = Mutex.new

        3.times do |i|
          queue.push do
            sleep 0.05
            mutex.synchronize { completed << i }
          end
        end

        queue.shutdown(timeout: 10)
        expect(completed.sort).to eq([0, 1, 2])
      end

      it "is idempotent" do
        queue.shutdown(timeout: 5)
        expect { queue.shutdown(timeout: 5) }.not_to raise_error
      end
    end

    describe "concurrency control" do
      it "limits the number of concurrent workers" do
        concurrent_count = 0
        max_concurrent = 0
        mutex = Mutex.new

        8.times do
          queue.push do
            mutex.synchronize do
              concurrent_count += 1
              max_concurrent = [max_concurrent, concurrent_count].max
            end
            sleep 0.05
            mutex.synchronize { concurrent_count -= 1 }
          end
        end

        queue.shutdown(timeout: 10)
        expect(max_concurrent).to be <= concurrency
      end
    end

    describe "error handling" do
      it "continues processing after a task raises an error" do
        results = []
        mutex = Mutex.new

        queue.push { raise "boom" }
        queue.push { mutex.synchronize { results << :after_error } }

        sleep 0.2
        expect(results).to include(:after_error)
      end
    end
  end
end
