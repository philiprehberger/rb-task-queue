# frozen_string_literal: true

require_relative 'lib/philiprehberger/task_queue/version'

Gem::Specification.new do |spec|
  spec.name = 'philiprehberger-task_queue'
  spec.version = Philiprehberger::TaskQueue::VERSION
  spec.authors = ['Philip Rehberger']
  spec.email = ['me@philiprehberger.com']

  spec.summary = 'In-process async job queue with concurrency control for Ruby'
  spec.description = 'A lightweight, zero-dependency, thread-safe in-process async job queue ' \
                     'with configurable concurrency for Ruby applications.'
  spec.homepage = 'https://philiprehberger.com/open-source-packages/ruby/philiprehberger-task_queue'
  spec.license = 'MIT'

  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/philiprehberger/rb-task-queue'
  spec.metadata['changelog_uri'] = 'https://github.com/philiprehberger/rb-task-queue/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/philiprehberger/rb-task-queue/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']
end
