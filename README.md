# philiprehberger-task_queue

[![Gem Version](https://badge.fury.io/rb/philiprehberger-task_queue.svg)](https://rubygems.org/gems/philiprehberger-task_queue)
[![CI](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-task-queue/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/philiprehberger/rb-task-queue)](LICENSE)

In-process async job queue with concurrency control for Ruby.

## Requirements

- Ruby >= 3.1

## Installation

Add to your Gemfile:

```ruby
gem "philiprehberger-task_queue"
```

Or install directly:

```sh
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

```ruby
queue = Philiprehberger::TaskQueue.new

queue.on_error do |exception, task|
  puts "Task failed: #{exception.message}"
end

queue.push { raise "oops" }
```

### Statistics

```ruby
queue.stats
# => { completed: 5, failed: 1, pending: 2 }
```

### Draining

```ruby
10.times { |i| queue.push { process(i) } }
queue.drain(timeout: 10)  # waits for all tasks to finish
# queue is still running and accepting new tasks
```

## API

| Method | Description |
|---|---|
| `.new(concurrency: 4)` | Create a new queue with the given max worker count |
| `#push(&block)` | Enqueue a task (block) for async execution |
| `#<< (&block)` | Alias for `#push` |
| `#size` | Number of pending (not yet started) tasks |
| `#running?` | Whether the queue is accepting new tasks |
| `#shutdown(timeout: 30)` | Gracefully stop all workers, waiting up to `timeout` seconds |
| `#on_error(&block)` | Register error callback for failed tasks |
| `#stats` | Returns hash with `:completed`, `:failed`, `:pending` counts |
| `#drain(timeout: 30)` | Block until all pending tasks complete (without shutdown) |


## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE)
