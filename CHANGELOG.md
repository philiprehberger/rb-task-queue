# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2026-03-12

### Added

- `on_error` callback for handling task failures
- `stats` method returning completed, failed, and pending task counts
- `drain(timeout:)` method to wait for task completion without shutting down

## [0.1.0] - 2026-03-10

### Added

- Initial release
- In-process async job queue with configurable concurrency
- Thread-safe task enqueuing with `push` / `<<`
- Graceful shutdown with timeout support
- Auto-starting worker threads on first push
