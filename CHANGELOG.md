# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-10

### Added

- Initial release
- In-process async job queue with configurable concurrency
- Thread-safe task enqueuing with `push` / `<<`
- Graceful shutdown with timeout support
- Auto-starting worker threads on first push
