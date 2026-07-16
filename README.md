# philiprehberger-task_queue

[![Tests](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/philiprehberger-task_queue.svg)](https://rubygems.org/gems/philiprehberger-task_queue)
[![Last updated](https://img.shields.io/github/last-commit/philiprehberger/rb-task-queue)](https://github.com/philiprehberger/rb-task-queue/commits/main)

![philiprehberger-task_queue](https://raw.githubusercontent.com/philiprehberger/rb-task-queue/main/package-card.webp)

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
# => { completed: 0, failed: 2, pending: 0, in_flight: 0, retried: 0 }
```

### Retries and backoff

Failing tasks can be retried automatically. Pass `max_retries:` (default `0`, no retries) and a `retry_backoff:` policy (`:none`, `:fixed`, or `:exponential`) with a `retry_base_delay:` in seconds. A task that raises a `StandardError` is requeued up to `max_retries` times before being counted as `failed`. The `on_error` callback fires on every failed attempt and receives the attempt number as its third argument. The number of retry attempts is tracked in `stats[:retried]`.

```ruby
queue = Philiprehberger::TaskQueue.new(
  concurrency: 4,
  max_retries: 3,
  retry_backoff: :exponential,  # :none | :fixed | :exponential
  retry_base_delay: 0.5         # seconds; grows 0.5, 1.0, 2.0 for :exponential
)

queue.on_error do |exception, task, attempt|
  warn "[TaskQueue] attempt #{attempt} failed: #{exception.message}"
end

attempts = 0
queue.push do
  attempts += 1
  raise "transient failure" if attempts < 3
  puts "succeeded on attempt #{attempts}"
end

queue.drain(timeout: 30)
puts queue.stats[:retried]  # number of retry attempts made
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
puts "Completed:   #{stats[:completed]}"
puts "Failed:      #{stats[:failed]}"
puts "Pending:     #{stats[:pending]}"
puts "In-flight:   #{stats[:in_flight]}"
puts "Concurrency: #{queue.concurrency}"
# Completed:   19
# Failed:      1
# Pending:     0
# In-flight:   0
# Concurrency: 4
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

### Reset counters

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 4)
10.times { queue.push { do_work } }
queue.drain
queue.stats_reset!
queue.stats[:completed] # => 0
```

### Task priorities

Give tasks a `priority:` (default `0`) to have them dequeued ahead of lower-priority work. Higher priorities run first; tasks that share a priority preserve FIFO (insertion) order. The `<<` alias always enqueues at priority `0`.

```ruby
queue = Philiprehberger::TaskQueue.new(concurrency: 1)
queue.pause

queue.push(priority: 0)  { puts "low" }
queue.push(priority: 10) { puts "high" }
queue.push(priority: 5)  { puts "medium" }

queue.resume
queue.drain(timeout: 5)
# high
# medium
# low
```

### FIFO ordering guarantees

Tasks are stored in an internal array and dequeued in priority-then-FIFO order. With the default priority of `0`, ordering is pure FIFO. When `concurrency` is `1`, equal-priority tasks execute strictly in the order they were pushed. With higher concurrency, dequeue order is still priority-then-FIFO but tasks may complete out of order depending on individual execution time.

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
| `.new(concurrency:, max_retries:, retry_backoff:, retry_base_delay:)` | `concurrency` — max worker threads (Integer, default `4`); `max_retries` — retries before a task counts as failed (Integer, default `0`); `retry_backoff` — `:none`/`:fixed`/`:exponential` (default `:none`); `retry_base_delay` — base delay in seconds (Numeric, default `0.1`) | `Queue` | Create a new queue; raises `ArgumentError` on a negative `max_retries` or unknown `retry_backoff` |
| `#push(&block)` | `priority` — dequeue priority, higher runs first (Integer, default `0`); `&block` — the task to execute | `self` | Enqueue a block for async execution; raises `ArgumentError` if no block given, raises `RuntimeError` if the queue is shut down |
| `#<<(callable)` | `callable` — any object responding to `#call` | `self` | Alias for `#push`; convenient for lambdas and procs |
| `#size` | _(none)_ | `Integer` | Number of pending (not yet started) tasks |
| `#empty?` | _(none)_ | `Boolean` | Whether there are no pending tasks waiting to be started |
| `#busy?` | _(none)_ | `Boolean` | Whether the queue has any pending tasks or in-flight tasks |
| `#running?` | _(none)_ | `Boolean` | Whether the queue is accepting new tasks |
| `#shutdown(timeout:)` | `timeout` — seconds to wait for workers (Numeric, default `30`) | `nil` | Signal workers to stop, drain remaining tasks, join threads up to `timeout` seconds |
| `#on_complete(&block)` | `&block` — callback receiving `(result)` | `self` | Register a callback invoked after each successful task completion with the task's return value |
| `#on_error(&block)` | `&block` — callback receiving `(exception, task, attempt)` | `self` | Register an error callback invoked on every failed attempt when a task raises a `StandardError`; `attempt` is the 1-based attempt number |
| `#stats` | _(none)_ | `Hash` | Returns `{ completed:, failed:, pending:, in_flight:, retried: }` with Integer counts (`retried` is the total number of retry attempts made) |
| `#drain(timeout:)` | `timeout` — seconds to wait (Numeric, default `30`) | `nil` | Block until all pending and in-flight tasks complete without shutting down |
| `#pause` | _(none)_ | `self` | Suspend task consumption; in-flight tasks finish but no new tasks are picked up |
| `#resume` | _(none)_ | `self` | Resume a paused queue, waking workers to continue processing |
| `#paused?` | _(none)_ | `Boolean` | Whether the queue is currently paused |
| `#clear` | _(none)_ | `Integer` | Remove all pending tasks and return the number cleared |
| `#stats_reset!` | _(none)_ | `self` | Atomically zero the `completed` and `failed` counters while leaving pending, in-flight, workers, and callbacks untouched |
| `#concurrency` | _(none)_ | `Integer` | Returns the configured maximum number of concurrent worker threads |

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
