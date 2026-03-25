# philiprehberger-task_queue

[![Tests](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/philiprehberger-task_queue.svg)](https://rubygems.org/gems/philiprehberger-task_queue)
[![License](https://img.shields.io/github/license/philiprehberger/rb-task-queue)](LICENSE)

In-process async job queue with concurrency control

## Requirements

- Ruby >= 3.1

## Installation

Add to your Gemfile:

```ruby
gem "philiprehberger-task_queue"
```

Or install directly:

```bash
gem install philiprehberger-task_queue
```

## Usage

```ruby
require "philiprehberger/task_queue"

queue = Philiprehberger::TaskQueue.new(concurrency: 4)

10.times do |i|
  queue.push { puts "Processing job #{i}" }
end

puts queue.size      # number of pending tasks
puts queue.running?  # => true

queue.shutdown(timeout: 30)
```

### Using the `<<` alias

```ruby
queue << -> { puts "Hello from a task!" }
```

### Error handling

Register a callback to handle exceptions raised inside tasks. The callback receives the exception and the original task (callable) that failed. Unhandled errors are silently swallowed when no callback is registered.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 2)

queue.on_error do |exception, task|
  warn "[TaskQueue] #{exception.class}: #{exception.message}"
  warn exception.backtrace.first(5).join("\n")
end

queue.push { Integer("not_a_number") }
queue.push { File.read("/nonexistent") }

queue.drain(timeout: 5)
puts queue.stats
# => { completed: 0, failed: 2, pending: 0 }
```

### Statistics

`stats` returns a snapshot of completed, failed, and pending counts. All counters are thread-safe and updated atomically after each task finishes.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)

20.times { |i| queue.push { sleep(0.01); raise "boom" if i == 5 } }
queue.drain(timeout: 10)

stats = queue.stats
puts "Completed: #{stats[:completed]}"
puts "Failed:    #{stats[:failed]}"
puts "Pending:   #{stats[:pending]}"
# Completed: 19
# Failed:    1
# Pending:   0
```

### FIFO ordering guarantees

Tasks are stored in an internal array and dequeued in FIFO order. When `concurrency` is `1`, tasks execute strictly in the order they were pushed. With higher concurrency, dequeue order is still FIFO but tasks may complete out of order depending on individual execution time.

```ruby
results = Queue.new  # stdlib thread-safe queue for collecting output
queue = Philiprehberger::TaskQueue.new(concurrency: 1)

5.times { |i| queue.push { results << i } }
queue.drain(timeout: 5)

puts results.size.times.map { results.pop }
# => [0, 1, 2, 3, 4]
```

### Graceful shutdown

`shutdown` signals all worker threads to stop accepting new tasks, lets in-flight tasks finish, then drains any remaining enqueued tasks before joining threads. The `timeout` parameter caps total wait time; workers that exceed the deadline are abandoned.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)

100.times { |i| queue.push { sleep(0.05) } }

queue.shutdown(timeout: 10)
puts queue.running?  # => false
# queue.push { ... } would now raise "queue is shut down"
```

### Draining

`drain` blocks the calling thread until all pending and in-flight tasks finish, but keeps the queue running so new tasks can still be pushed afterwards.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)

10.times { |i| queue.push { process(i) } }
queue.drain(timeout: 10)  # waits for all tasks to finish
puts queue.running?        # => true — still accepting new tasks

queue.push { process(:extra) }
queue.shutdown(timeout: 5)
```

## API

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `.new(concurrency:)` | `concurrency` — max worker threads (Integer, default `4`) | `Queue` | Create a new queue with the given concurrency limit |
| `#push(&block)` | `&block` — the task to execute | `self` | Enqueue a block for async execution; raises `ArgumentError` if no block given, raises `RuntimeError` if the queue is shut down |
| `#<<(callable)` | `callable` — any object responding to `#call` | `self` | Alias for `#push`; convenient for lambdas and procs |
| `#size` | _(none)_ | `Integer` | Number of pending (not yet started) tasks |
| `#running?` | _(none)_ | `Boolean` | Whether the queue is accepting new tasks |
| `#shutdown(timeout:)` | `timeout` — seconds to wait for workers (Numeric, default `30`) | `nil` | Signal workers to stop, drain remaining tasks, join threads up to `timeout` seconds |
| `#on_error(&block)` | `&block` — callback receiving `(exception, task)` | `self` | Register an error callback invoked when a task raises a `StandardError` |
| `#stats` | _(none)_ | `Hash` | Returns `{ completed:, failed:, pending: }` with Integer counts |
| `#drain(timeout:)` | `timeout` — seconds to wait (Numeric, default `30`) | `nil` | Block until all pending and in-flight tasks complete without shutting down |


## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
