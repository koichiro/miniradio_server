# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "standard/rake"

Minitest::TestTask.create do |task|
  task.framework = 'require "test_helper"'
end

desc "Test browser playback logic with Node.js (18 or later)"
task :test_player do
  sh "node", "--test", "test/player_test.js"
end

desc "Check Ruby style with Standard"
task lint: :standard

desc "Run lint, Ruby coverage checks, and player tests"
task check: [:lint, :test, :test_player]

task default: :check
