# Changelog

All notable changes to this gem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-04-04

### Added
- `on_complete(&block)` callback that fires after each successful task completion with the task result

## [0.2.11] - 2026-03-31

### Added
- Add GitHub issue templates, dependabot config, and PR template

## [0.2.10] - 2026-03-31

### Changed
- Standardize README badges, support section, and license format

## [0.2.9] - 2026-03-26

### Changed
- Add Sponsor badge to README
- Fix License section format
- Sync gemspec summary with README


## [0.2.8] - 2026-03-24

### Fixed
- Align README one-liner with gemspec summary

## [0.2.7] - 2026-03-23

### Fixed
- Standardize README/CHANGELOG to match template guide

## [0.2.6] - 2026-03-22

### Changed
- Expand test coverage with ordering, high concurrency, drain, and error path tests

## [0.2.5] - 2026-03-22

### Changed
- Expand test coverage

## [0.2.4] - 2026-03-20

### Fixed
- Fix README description trailing period
- Fix CHANGELOG header wording

## [0.2.3] - 2026-03-20

### Changed
- Expand README with detailed API documentation and usage examples

## [0.2.2] - 2026-03-18

### Fixed
- Fix RuboCop Style/StringLiterals violations in gemspec

## [0.2.1] - 2026-03-16

### Added
- Add License badge to README
- Add bug_tracker_uri to gemspec
- Add Development section to README
- Add Requirements section to README

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
