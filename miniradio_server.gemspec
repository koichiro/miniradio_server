# frozen_string_literal: true

require_relative "lib/miniradio_server/version"

Gem::Specification.new do |spec|
  spec.name = "miniradio_server"
  spec.version = MiniradioServer::VERSION
  spec.authors = ["Koichiro Ohba"]
  spec.email = ["koichiro.ohba@gmail.com"]

  spec.summary = "Miniradio Server is Simple Ruby HLS Server for MP3s."
  spec.description = <<-EOS
    This is a basic HTTP Live Streaming (HLS) server written in Ruby using the Rack interface. It serves MP3 audio files by converting them on-the-fly into HLS format (M3U8 playlist and MP3 segment files) using `ffmpeg`. Converted files are cached for subsequent requests.
    This server is designed for simplicity and primarily targets Video on Demand (VOD) scenarios where you want to stream existing MP3 files via HLS without pre-converting them.
  EOS
  spec.homepage = "https://github.com/koichiro/miniradio_server"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/koichiro/miniradio_server.git"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Package runtime files even when building from a source archive without Git.
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "irb"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "standard", "~> 1.0"
  spec.add_development_dependency "simplecov", "~> 1.3"
  spec.add_development_dependency "bundler-audit", "~> 0.9"

  spec.add_dependency "rack", ">= 3.1", "< 4"
  spec.add_dependency "rackup", "~> 2.2"
  spec.add_dependency "webrick"
  spec.add_dependency "open3"
  spec.add_dependency "logger"
  spec.add_dependency "tilt"
  spec.add_dependency "slim"
  spec.add_dependency "mp3info"
end
