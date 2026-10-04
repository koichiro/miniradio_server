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

desc "Build and verify the installed gem outside the checkout"
task smoke_gem: :build do
  dependency_paths = Bundler.load.specs.reject { |spec| spec.name == "miniradio_server" }.map(&:base_dir).uniq.join(File::PATH_SEPARATOR)
  Bundler.with_unbundled_env do
    sh({"GEM_PATH" => dependency_paths}, Gem.ruby, "test/gem_smoke.rb", "pkg/miniradio_server-#{MiniradioServer::VERSION}.gem")
  end
end

desc "Check Ruby style with Standard"
task lint: :standard

desc "Audit locked gems using the latest Ruby advisory database"
task :audit do
  sh "bundle", "exec", "bundle-audit", "check", "--update"
end

desc "Run lint, Ruby coverage checks, and player tests"
task check: [:lint, :test, :test_player]

task default: :check
