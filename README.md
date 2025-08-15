# philiprehberger-task_queue

[![Tests](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/philiprehberger-task_queue.svg)](https://rubygems.org/gems/philiprehberger-task_queue)
[![Last updated](https://img.shields.io/github/last-commit/philiprehberger/rb-task-queue)](https://github.com/philiprehberger/rb-task-queue/commits/main)

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
# => { completed: 0, failed: 2, pending: 0, in_flight: 0 }
```

### Completion callback

Register a callback to run after each successful task completion. The callback receives the return value of the task.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 2)

queue.on_complete do |result|
  puts "Task finished with: #{result}"
end

queue.push { 42 }
queue.push { { status: "ok" } }

queue.drain(timeout: 5)
# Task finished with: 42
# Task finished with: {:status=>"ok"}
```

### Statistics

`stats` returns a snapshot of completed, failed, pending, and in-flight counts. All counters are thread-safe and updated atomically after each task finishes.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)

20.times { |i| queue.push { sleep(0.01); raise "boom" if i == 5 } }
queue.drain(timeout: 10)

stats = queue.stats
puts "Completed: #{stats[:completed]}"
puts "Failed:    #{stats[:failed]}"
puts "Pending:   #{stats[:pending]}"
puts "In-flight: #{stats[:in_flight]}"
# Completed: 19
# Failed:    1
# Pending:   0
# In-flight: 0
```

### Pause and resume

Temporarily suspend task consumption without shutting down. In-flight tasks will finish, but no new tasks are picked up until the queue is resumed.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)

10.times { |i| queue.push { process(i) } }

queue.pause
puts queue.paused?  # => true

# Tasks already in flight will complete, but pending tasks wait.
queue.resume
puts queue.paused?  # => false

queue.shutdown(timeout: 10)
```

### Clear pending tasks

Discard all pending tasks from the queue. Returns the number of tasks removed.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 2)

100.times { |i| queue.push { process(i) } }
cleared = queue.clear
puts "Cleared #{cleared} tasks"

queue.shutdown(timeout: 5)
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
| `#empty?` | _(none)_ | `Boolean` | Whether there are no pending tasks waiting to be started |
| `#running?` | _(none)_ | `Boolean` | Whether the queue is accepting new tasks |
| `#shutdown(timeout:)` | `timeout` — seconds to wait for workers (Numeric, default `30`) | `nil` | Signal workers to stop, drain remaining tasks, join threads up to `timeout` seconds |
| `#on_complete(&block)` | `&block` — callback receiving `(result)` | `self` | Register a callback invoked after each successful task completion with the task's return value |
| `#on_error(&block)` | `&block` — callback receiving `(exception, task)` | `self` | Register an error callback invoked when a task raises a `StandardError` |
| `#stats` | _(none)_ | `Hash` | Returns `{ completed:, failed:, pending:, in_flight: }` with Integer counts |
| `#drain(timeout:)` | `timeout` — seconds to wait (Numeric, default `30`) | `nil` | Block until all pending and in-flight tasks complete without shutting down |
| `#pause` | _(none)_ | `self` | Suspend task consumption; in-flight tasks finish but no new tasks are picked up |
| `#resume` | _(none)_ | `self` | Resume a paused queue, waking workers to continue processing |
| `#paused?` | _(none)_ | `Boolean` | Whether the queue is currently paused |
| `#clear` | _(none)_ | `Integer` | Remove all pending tasks and return the number cleared |

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Support

If you find this project useful:

⭐ [Star the repo](https://github.com/philiprehberger/rb-task-queue)

🐛 [Report issues](https://github.com/philiprehberger/rb-task-queue/issues?q=is%3Aissue+is%3Aopen+label%3Abug)

💡 [Suggest features](https://github.com/philiprehberger/rb-task-queue/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement)

❤️ [Sponsor development](https://github.com/sponsors/philiprehberger)

🌐 [All Open Source Projects](https://philiprehberger.com/open-source-packages)

💻 [GitHub Profile](https://github.com/philiprehberger)

🔗 [LinkedIn Profile](https://www.linkedin.com/in/philiprehberger)

## License

[MIT](LICENSE)
