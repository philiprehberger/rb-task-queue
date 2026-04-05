# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Philiprehberger::TaskQueue do
  describe '.new' do
    it 'returns a Queue instance' do
      queue = described_class.new
      expect(queue).to be_a(Philiprehberger::TaskQueue::Queue)
      queue.shutdown(timeout: 5)
    end
  end

  describe Philiprehberger::TaskQueue::Queue do
    subject(:queue) { described_class.new(concurrency: concurrency) }

    let(:concurrency) { 2 }

    after { queue.shutdown(timeout: 5) }

    describe '#push' do
      it 'enqueues and executes a task' do
        result = []
        mutex = Mutex.new

        queue.push do
          mutex.synchronize { result << :done }
        end

        sleep 0.1
        expect(result).to include(:done)
      end

      it 'raises ArgumentError when no block is given' do
        expect { queue.push }.to raise_error(ArgumentError, 'a block is required')
      end

      it 'raises when queue is shut down' do
        queue.shutdown(timeout: 5)
        expect { queue.push { nil } }.to raise_error(RuntimeError, 'queue is shut down')
      end
    end

    describe '#<<' do
      it 'is an alias for push' do
        results = []
        mutex = Mutex.new

        queue << proc {
          mutex.synchronize { results << :aliased }
        }

        sleep 0.1
        expect(results).to include(:aliased)
      end
    end

    describe '#size' do
      it 'returns 0 for an empty queue' do
        expect(queue.size).to eq(0)
      end
    end

    describe '#running?' do
      it 'returns true before shutdown' do
        expect(queue.running?).to be true
      end

      it 'returns false after shutdown' do
        queue.shutdown(timeout: 5)
        expect(queue.running?).to be false
      end
    end

    describe '#shutdown' do
      it 'waits for in-flight tasks to complete' do
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

      it 'is idempotent' do
        queue.shutdown(timeout: 5)
        expect { queue.shutdown(timeout: 5) }.not_to raise_error
      end
    end

    describe 'concurrency control' do
      it 'limits the number of concurrent workers' do
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

    describe 'error handling' do
      it 'continues processing after a task raises an error' do
        results = []
        mutex = Mutex.new

        queue.push { raise 'boom' }
        queue.push { mutex.synchronize { results << :after_error } }

        sleep 0.2
        expect(results).to include(:after_error)
      end
    end

    describe '#on_error' do
      it 'invokes the callback when a task raises' do
        errors = []
        mutex = Mutex.new

        queue.on_error { |e, _task| mutex.synchronize { errors << e.message } }
        queue.push { raise 'callback boom' }

        sleep 0.2
        expect(errors).to include('callback boom')
      end

      it 'receives both the exception and the task' do
        received = []
        mutex = Mutex.new
        failing_task = proc { raise 'task error' }

        queue.on_error { |e, task| mutex.synchronize { received << [e, task] } }
        queue << failing_task

        sleep 0.2
        expect(received.size).to eq(1)
        expect(received.first[0]).to be_a(RuntimeError)
        expect(received.first[0].message).to eq('task error')
        expect(received.first[1]).to eq(failing_task)
      end
    end

    describe '#stats' do
      it 'returns correct completed count' do
        3.times { queue.push { nil } }

        sleep 0.2
        expect(queue.stats[:completed]).to eq(3)
      end

      it 'returns correct failed count' do
        2.times { queue.push { raise 'fail' } }
        queue.push { nil }

        sleep 0.2
        expect(queue.stats[:failed]).to eq(2)
        expect(queue.stats[:completed]).to eq(1)
      end
    end

    describe '#drain' do
      it 'blocks until all tasks complete' do
        results = []
        mutex = Mutex.new

        5.times do |i|
          queue.push do
            sleep 0.05
            mutex.synchronize { results << i }
          end
        end

        queue.drain(timeout: 10)
        expect(results.sort).to eq([0, 1, 2, 3, 4])
      end

      it 'does not shut down the queue' do
        queue.push { nil }
        queue.drain(timeout: 5)

        expect(queue.running?).to be true

        result = []
        mutex = Mutex.new
        queue.push { mutex.synchronize { result << :after_drain } }

        sleep 0.1
        expect(result).to include(:after_drain)
      end
    end

    # --- Expanded tests ---

    describe '#push returns self for chaining' do
      it 'returns the queue from push' do
        result = queue.push { nil }
        expect(result).to eq(queue)
      end
    end

    describe '#on_complete' do
      it 'invokes the callback with the task result on success' do
        results = []
        mutex = Mutex.new

        queue.on_complete { |result| mutex.synchronize { results << result } }
        queue.push { 42 }
        queue.push { :hello }

        queue.drain(timeout: 5)
        expect(results.sort_by(&:to_s)).to contain_exactly(42, :hello)
      end

      it 'does not invoke the callback when a task raises' do
        results = []
        mutex = Mutex.new

        queue.on_complete { |result| mutex.synchronize { results << result } }
        queue.push { raise 'boom' }
        queue.push { :ok }

        queue.drain(timeout: 5)
        expect(results).to eq([:ok])
      end

      it 'returns self for chaining' do
        result = queue.on_complete { |_r| nil }
        expect(result).to eq(queue)
      end

      it 'receives the return value of the task' do
        received = nil
        mutex = Mutex.new

        queue.on_complete { |r| mutex.synchronize { received = r } }
        queue.push { { status: 'done', count: 5 } }

        queue.drain(timeout: 5)
        expect(received).to eq({ status: 'done', count: 5 })
      end
    end

    describe '#on_error returns self for chaining' do
      it 'returns the queue from on_error' do
        result = queue.on_error { |_e, _t| nil }
        expect(result).to eq(queue)
      end
    end

    describe 'multiple tasks with errors' do
      it 'tracks all failures in stats' do
        errors = []
        mutex = Mutex.new

        queue.on_error { |e, _t| mutex.synchronize { errors << e.message } }

        5.times { |i| queue.push { raise "error_#{i}" } }

        sleep 0.3
        expect(queue.stats[:failed]).to eq(5)
        expect(errors.size).to eq(5)
      end
    end

    describe 'concurrent push operations' do
      it 'handles rapid pushes without losing tasks' do
        counter = 0
        mutex = Mutex.new

        20.times do
          queue.push do
            mutex.synchronize { counter += 1 }
          end
        end

        queue.drain(timeout: 10)
        expect(counter).to eq(20)
      end
    end

    describe 'single worker concurrency' do
      it 'processes tasks sequentially with concurrency 1' do
        single_queue = described_class.new(concurrency: 1)
        order = []
        mutex = Mutex.new

        5.times do |i|
          single_queue.push do
            mutex.synchronize { order << i }
          end
        end

        single_queue.shutdown(timeout: 10)
        expect(order).to eq([0, 1, 2, 3, 4])
      end
    end

    describe 'stats pending count' do
      it 'returns pending count' do
        stats = queue.stats
        expect(stats).to have_key(:pending)
        expect(stats[:pending]).to eq(0)
      end
    end

    describe 'stats initial state' do
      it 'starts with zero counts' do
        stats = queue.stats
        expect(stats[:completed]).to eq(0)
        expect(stats[:failed]).to eq(0)
        expect(stats[:pending]).to eq(0)
      end
    end

    describe 'drain with no tasks' do
      it 'returns immediately when queue is empty' do
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue.drain(timeout: 5)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        expect(elapsed).to be < 1
      end
    end

    describe 'drain after errors' do
      it 'completes drain even with failed tasks' do
        results = []
        mutex = Mutex.new

        queue.push { raise 'fail' }
        queue.push { mutex.synchronize { results << :success } }

        queue.drain(timeout: 5)
        expect(results).to include(:success)
      end
    end

    describe 'shutdown prevents new tasks' do
      it 'raises on push after shutdown' do
        queue.shutdown(timeout: 5)
        expect { queue.push { nil } }.to raise_error(RuntimeError, /shut down/)
      end

      it 'raises on << after shutdown' do
        queue.shutdown(timeout: 5)
        expect { queue << proc {} }.to raise_error(RuntimeError, /shut down/)
      end
    end

    describe 'task ordering with single worker' do
      it 'processes tasks in FIFO order' do
        fifo_queue = described_class.new(concurrency: 1)
        order = []
        mutex = Mutex.new

        10.times do |i|
          fifo_queue.push { mutex.synchronize { order << i } }
        end

        fifo_queue.shutdown(timeout: 10)
        expect(order).to eq((0..9).to_a)
      end
    end

    describe 'high concurrency' do
      it 'handles concurrency of 8 workers' do
        high_queue = described_class.new(concurrency: 8)
        counter = 0
        mutex = Mutex.new

        50.times do
          high_queue.push { mutex.synchronize { counter += 1 } }
        end

        high_queue.shutdown(timeout: 10)
        expect(counter).to eq(50)
      end
    end

    describe 'stats after drain' do
      it 'reflects all completed tasks after drain' do
        10.times { queue.push { nil } }
        queue.drain(timeout: 10)
        expect(queue.stats[:completed]).to eq(10)
        expect(queue.stats[:pending]).to eq(0)
      end
    end

    describe 'mixed success and failure stats' do
      it 'tracks both completed and failed accurately' do
        3.times { queue.push { nil } }
        2.times { queue.push { raise 'fail' } }
        queue.drain(timeout: 10)
        stats = queue.stats
        expect(stats[:completed]).to eq(3)
        expect(stats[:failed]).to eq(2)
      end
    end

    describe 'error handler not set' do
      it 'does not crash when error handler is nil and task fails' do
        queue.push { raise 'no handler' }
        queue.drain(timeout: 5)
        expect(queue.stats[:failed]).to eq(1)
      end
    end

    describe 'push after drain' do
      it 'allows pushing more tasks after drain completes' do
        queue.push { nil }
        queue.drain(timeout: 5)

        result = []
        mutex = Mutex.new
        queue.push { mutex.synchronize { result << :second_batch } }
        queue.drain(timeout: 5)
        expect(result).to include(:second_batch)
      end
    end

    describe 'version' do
      it 'has a version number' do
        expect(Philiprehberger::TaskQueue::VERSION).not_to be_nil
      end
    end
  end
end
