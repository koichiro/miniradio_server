# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "simplecov"
require "simplecov_json_formatter"

SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new([
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::JSONFormatter
])

SimpleCov.start do
  root File.expand_path("..", __dir__)
  add_filter "/test/"
  # Bundler loads this declarative metadata before coverage instrumentation.
  add_filter "/lib/miniradio_server/version.rb"
  track_files "lib/**/*.rb"
  use_merging false
  minimum_coverage 90
  minimum_coverage_by_file 90
end

require "miniradio_server"

require "minitest/autorun"
