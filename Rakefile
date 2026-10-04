# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

desc 'Test browser playback logic with Node.js (18 or later)'
task :test_player do
  sh 'node', '--test', 'test/player_test.js'
end

desc 'Run Ruby and player tests'
task check: [:test, :test_player]

task default: :test
