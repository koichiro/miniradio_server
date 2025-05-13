# frozen_string_literal: true

require_relative "lib/miniradio_server/version"

Gem::Specification.new do |spec|
  spec.name = "miniradio_server"
  spec.version = MiniradioServer::VERSION
  spec.authors = ["Koichiro Ohba"]
  spec.email = ["koichiro.ohba@gmail.com"]

  spec.summary = "Miniradio Server is Simple Ruby HLS Server for MP3s."
  spec.description =<<-EOS
    This is a basic HTTP Live Streaming (HLS) server written in Ruby using the Rack interface. It serves MP3 audio files by converting them on-the-fly into HLS format (M3U8 playlist and MP3 segment files) using `ffmpeg`. Converted files are cached for subsequent requests.
    This server is designed for simplicity and primarily targets Video on Demand (VOD) scenarios where you want to stream existing MP3 files via HLS without pre-converting them.
  EOS
  spec.homepage = "https://github.com/koichiro/miniradio_server"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  #spec.metadata["allowed_push_host"] = "Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/koichiro/miniradio_server.git"
  # spec.metadata["changelog_uri"] = "Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"
  spec.add_development_dependency "irb"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.16"

  spec.add_dependency "rackup"
  spec.add_dependency "webrick"
  spec.add_dependency "open3"
  spec.add_dependency "logger"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
