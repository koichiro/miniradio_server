# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "fileutils"
require "digest"

source = Gem::Package.new(File.expand_path(ARGV.fetch(0)))
output = File.expand_path(ARGV.fetch(1))
spec = source.spec
raise "Unexpected gem: #{spec.name}" unless spec.name == "miniradio_server"

spec.metadata["allowed_push_host"] = "https://rubygems.pkg.github.com/koichiro"
spec.metadata["github_repo"] = "ssh://github.com/koichiro/miniradio_server"
FileUtils.mkdir_p(File.dirname(output))

Dir.mktmpdir("miniradio-github-package") do |directory|
  source_dir = File.join(directory, "source")
  source.extract_files(source_dir)
  Dir.chdir(source_dir) { Gem::Package.build(spec, false, false, output) }

  # The registry metadata differs; every packaged file must stay identical to
  # the release artifact already published to RubyGems.org.
  target = Gem::Package.new(output)
  target_dir = File.join(directory, "target")
  target.extract_files(target_dir)
  raise "Packaged file list changed" unless source.contents.sort == target.contents.sort
  source.contents.each do |path|
    next if File.directory?(File.join(source_dir, path))
    original = Digest::SHA256.file(File.join(source_dir, path)).hexdigest
    repackaged = Digest::SHA256.file(File.join(target_dir, path)).hexdigest
    raise "Packaged file changed: #{path}" unless original == repackaged
  end
end

puts "GitHub Packages artifact verified: #{output}"
