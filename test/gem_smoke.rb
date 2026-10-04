# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "open3"

package = File.expand_path(ARGV.fetch(0))
spec = Gem::Package.new(package).spec

def run!(env, *command, **options)
  out, err, status = Open3.capture3(env, *command, **options)
  raise "#{command.join(" ")} failed:\n#{out}\n#{err}" unless status.success?
  out
end

Dir.mktmpdir("miniradio-installed-gem") do |directory|
  gem_home = File.join(directory, "gems")
  env = {
    "GEM_HOME" => gem_home,
    "GEM_PATH" => ([gem_home] + Gem.path).join(File::PATH_SEPARATOR),
    "RUBYOPT" => nil,
    "RUBYLIB" => nil,
    "BUNDLE_GEMFILE" => nil
  }
  # Runtime dependencies are supplied by bundle install; install the artifact
  # locally so this check needs neither RubyGems credentials nor network access.
  run!(env, Gem.ruby, "-S", "gem", "install", package,
    "--local", "--ignore-dependencies", "--no-document", chdir: directory)
  executable = File.join(gem_home, "bin", "miniradio_server")
  version = run!(env, Gem.ruby, executable, "--version", chdir: directory).strip
  raise "Expected #{spec.version}, got #{version}" unless version == spec.version.to_s
  help = run!(env, Gem.ruby, executable, "--help", chdir: directory)
  raise "Missing CLI help" unless help.include?("--mp3-dir")

  probe = <<~'RUBY'
    require "miniradio_server/cli"
    require "rack/mock"
    installed = File.realpath(Gem.loaded_specs.fetch("miniradio_server").full_gem_path)
    raise "Loaded gem outside temporary installation: #{installed}" unless installed.start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
    raise "Requiring the library created data directories" if Dir.exist?("mp3_files") || Dir.exist?("hls_cache")

    # Exercise CLI wiring and packaged assets without binding a network port.
    handler = Rackup::Handler::WEBrick
    def handler.run(app, **options)
      request = Rack::MockRequest.new(app)
      {
        "/" => "Miniradio ver #{MiniradioServer::VERSION}",
        "/player.js" => "Hls",
        "/style/main.css" => "{"
      }.each do |path, content|
        response = request.get(path)
        raise "Packaged #{path} failed" unless response.status == 200 && response.body.include?(content)
      end
      raise "Missing source directory" unless Dir.exist?("mp3_files")
      raise "Missing cache directory" unless Dir.exist?("hls_cache")
    end

    raise "CLI failed" unless MiniradioServer::CLI.run([]) == 0
  RUBY
  run!(env, Gem.ruby, "-", stdin_data: probe, chdir: directory)
end

puts "Installed #{spec.name} #{spec.version}: CLI, templates, and assets passed."
