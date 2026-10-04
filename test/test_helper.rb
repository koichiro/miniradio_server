# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "simplecov"
SimpleCov.start do
  formats :html, :json
  root File.expand_path("..", __dir__)
  skip "/test/"
  # Bundler loads this declarative metadata before coverage instrumentation.
  skip "/lib/miniradio_server/version.rb"
  cover "lib/**/*.rb"
  merging false
  coverage :line do
    minimum 90
    minimum 90, per: :file
  end
end

require "miniradio_server"

require "minitest/autorun"
