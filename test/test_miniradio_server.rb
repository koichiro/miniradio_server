# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"
require "rack/lint"
require "timeout"
require "minitest/mock"
require "miniradio_server/cli"

class TestMiniradioServer < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("miniradio-test")
    @mp3_dir = File.join(@tmp_dir, "mp3")
    @cache_dir = File.join(@tmp_dir, "cache")
    @logger = Logger.new(IO::NULL)
    MiniradioServer.ensure_directories_exist([@mp3_dir, @cache_dir], @logger)
    FileUtils.cp(File.join(__dir__, "sample/eine.mp3"), File.join(@mp3_dir, "song.mp3"))
    @app = MiniradioServer::App.new(@mp3_dir, @cache_dir, "ffmpeg", 10, @logger)
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  # Consume every response through Rack::Lint, including streamed file bodies.
  def request(path, app = @app)
    env = {
      "REQUEST_METHOD" => "GET", "SCRIPT_NAME" => "", "PATH_INFO" => path,
      "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9292",
      "SERVER_PROTOCOL" => "HTTP/1.1", "rack.url_scheme" => "http",
      "rack.input" => StringIO.new("".b), "rack.errors" => StringIO.new
    }
    status, headers, body = Rack::Lint.new(app).call(env)
    text = "".b
    body.each { |part| text << part }
    [status, headers, text]
  ensure
    body.close if body.respond_to?(:close)
  end

  def write_cache(name = "song")
    dir = File.join(@cache_dir, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "playlist.m3u8"), "#EXTM3U\nsegment000.mp3\n")
    File.binwrite(File.join(dir, "segment000.mp3"), "\x00\xffsegment".b)
    dir
  end

  def test_directories_are_created
    new_dirs = %w[source nested/cache].map { |name| File.join(@tmp_dir, name) }
    MiniradioServer.ensure_directories_exist(new_dirs, @logger)
    new_dirs.each { |dir| assert Dir.exist?(dir) }
  end

  def test_index_has_current_controls_and_safe_track_data
    status, headers, html = request("/")
    assert_equal 200, status
    assert_equal "text/html", headers["content-type"]
    assert_includes html, "Miniradio ver #{MiniradioServer::VERSION}"
    assert_match(/<audio[^>]*controls=/, html)
    %w[startButton playPauseButton prevButton nextButton loopButton shuffleButton].each do |id|
      assert_includes html, "id=\"#{id}\""
    end
    assert_includes html, 'src="/player.js"'
    tracks = JSON.parse(html.match(/<script[^>]*id="tracks"[^>]*>(.*?)<\/script>/m)[1])
    assert_equal "song", tracks.first["file"]
    assert_equal "/stream/song/playlist.m3u8", tracks.first["url"]
    assert_equal "/artwork/song", tracks.first["artwork_url"]
    %w[currentArtwork artworkPlaceholder currentArtist currentAlbum playbackState seekControl volumeControl muteButton].each do |id|
      assert_includes html, "id=\"#{id}\""
    end
    assert_equal 200, request("/index.html").first
  end

  def test_track_data_cannot_close_the_script_element
    title = "</script><img src=x onerror=alert(1)>"
    tracks = [{title: title, file: "song", url: "/stream/song/playlist.m3u8"}]
    @app.stub(:get_mp3_list, tracks) do
      html = request("/").last
      refute_includes html, title
      assert_includes html, '\\u003c/script\\u003e'
      json = html.match(/<script[^>]*id="tracks"[^>]*>(.*?)<\/script>/m)[1]
      assert_equal title, JSON.parse(json).first["title"]
    end
  end

  def test_filenames_round_trip_without_form_encoding
    %w[eine\ 01 アイネクライネ plus+percent%].each do |name|
      FileUtils.cp(File.join(@mp3_dir, "song.mp3"), File.join(@mp3_dir, "#{name}.mp3"))
      write_cache(name)
      track = @app.get_mp3_list.find { |item| item[:file] == name }
      refute_match(/[ +]/, track[:url])
      assert_equal 200, request(track[:url]).first
    end
  end

  def test_cache_hit_does_not_run_ffmpeg_and_serves_binary_segments
    write_cache
    Open3.stub(:capture3, ->(*) { flunk "Cached requests must not run FFmpeg" }) do
      assert_equal 200, request("/stream/song/playlist.m3u8").first
      status, headers, body = request("/stream/song/segment000.mp3")
      assert_equal 200, status
      assert_equal "audio/mpeg", headers["content-type"]
      assert_equal body.bytesize.to_s, headers["content-length"]
      assert_equal "\x00\xffsegment".b, body
    end
  end

  def test_conversion_runs_once_then_uses_cache
    calls = 0
    converter = lambda do |*cmd|
      calls += 1
      assert_equal "ffmpeg", cmd.first
      assert_equal File.realpath(File.join(@mp3_dir, "song.mp3")), cmd[cmd.index("-i") + 1]
      write_cache
      ["", "", Struct.new(:success?).new(true)]
    end
    Open3.stub(:capture3, converter) do
      2.times { assert_equal 200, request("/stream/song/playlist.m3u8").first }
    end
    assert_equal 1, calls
  end

  def test_failed_conversion_cleans_cache_and_can_retry
    Open3.stub(:capture3, lambda { |*|
      write_cache
      ["", "conversion failed", Struct.new(:success?, :exitstatus).new(false, 1)]
    }) do
      assert_equal 500, request("/stream/song/playlist.m3u8").first
    end
    refute Dir.exist?(File.join(@cache_dir, "song"))
    Open3.stub(:capture3, lambda { |*|
      write_cache
      ["", "", Struct.new(:success?).new(true)]
    }) do
      assert_equal 200, request("/stream/song/playlist.m3u8").first
    end
  end

  def test_concurrent_request_gets_retry_after_and_only_one_conversion
    started = Queue.new
    finish = Queue.new
    worker = nil
    Open3.stub(:capture3, lambda { |*|
      started << true
      finish.pop
      write_cache
      ["", "", Struct.new(:success?).new(true)]
    }) do
      worker = Thread.new { request("/stream/song/playlist.m3u8") }
      Timeout.timeout(5) { started.pop }
      status, headers, = request("/stream/song/playlist.m3u8")
      assert_equal 503, status
      assert_equal "5", headers["retry-after"]
      finish << true
      assert_equal 200, worker.value.first
    end
  ensure
    finish << true if finish
    worker&.join
  end

  def test_missing_ffmpeg_returns_server_error
    Open3.stub(:capture3, ->(*) { raise Errno::ENOENT, "ffmpeg" }) do
      assert_equal 500, request("/stream/song/playlist.m3u8").first
    end
  end

  def test_unexpected_conversion_error_cleans_partial_files_and_releases_lock
    Open3.stub(:capture3, lambda { |*|
      write_cache
      raise IOError, "Unable to read FFmpeg output"
    }) do
      assert_equal 500, request("/stream/song/playlist.m3u8").first
    end
    refute Dir.exist?(File.join(@cache_dir, "song"))
    Open3.stub(:capture3, lambda { |*|
      write_cache
      ["", "", Struct.new(:success?).new(true)]
    }) do
      assert_equal 200, request("/stream/song/playlist.m3u8").first
    end
  end

  def test_corrupt_metadata_keeps_the_library_available
    File.write(File.join(@mp3_dir, "broken.mp3"), "not an MP3")
    status, _headers, body = request("/")
    assert_equal 200, status
    tracks = JSON.parse(body.match(/<script[^>]*id="tracks"[^>]*>(.*?)<\/script>/m)[1])
    assert_equal %w[broken song], tracks.map { |t| t["file"] }.sort
    assert_nil tracks.find { |t| t["file"] == "broken" }["title"]
  end

  def test_embedded_artwork_is_served_without_running_ffmpeg
    ["\xff\xd8\xfftest".b, "\x89PNG\r\n\x1a\ntest".b].zip(%w[image/jpeg image/png]).each do |image, mime|
      Mp3Info.open(File.join(@mp3_dir, "song.mp3")) { |mp3| mp3.tag2.add_picture(image) }
      Open3.stub(:capture3, ->(*) { flunk "Artwork must not invoke FFmpeg" }) do
        status, headers, body = request("/artwork/song")
        assert_equal 200, status
        assert_equal mime, headers["content-type"]
        assert_equal image, body
        assert_equal image.bytesize.to_s, headers["content-length"]
        assert_equal "nosniff", headers["x-content-type-options"]
        assert_equal "no-store", headers["cache-control"]
      end
    end
    assert_empty Dir.children(@cache_dir)
  end

  def test_artwork_selects_first_eligible_image_by_signature
    image = "\x89PNG\r\n\x1a\ndata".b
    pictures = [["untrusted.jpg", "not an image"], ["huge.png", image + "x" * MiniradioServer::App::MAX_ARTWORK_BYTES],
      ["../../wrong.jpg", image], ["later.png", "\xff\xd8\xfflater".b]]
    mp3 = Struct.new(:tag2).new(Struct.new(:pictures).new(pictures))
    Mp3Info.stub(:open, ->(_path, &block) { block.call(mp3) }) do
      status, headers, body = request("/artwork/song")
      assert_equal 200, status
      assert_equal "image/png", headers["content-type"]
      assert_equal image, body
    end
  end

  def test_missing_invalid_or_broken_artwork_falls_back_to_not_found
    assert_equal 404, request("/artwork/song").first
    assert_equal 404, request("/artwork/missing").first
    File.write(File.join(@mp3_dir, "broken.mp3"), "not an MP3")
    assert_equal 404, request("/artwork/broken").first
    mp3 = Struct.new(:tag2).new(Struct.new(:pictures).new([["bad", nil], ["bad", "invalid"]]))
    Mp3Info.stub(:open, ->(_path, &block) { block.call(mp3) }) do
      assert_equal 404, request("/artwork/song").first
    end
  end

  def test_artwork_urls_handle_unicode_and_reject_unsafe_sources
    image = "\x89PNG\r\n\x1a\ndata".b
    Mp3Info.open(File.join(@mp3_dir, "song.mp3")) { |mp3| mp3.tag2.add_picture(image) }
    name = "日本語 +%"
    FileUtils.cp(File.join(@mp3_dir, "song.mp3"), File.join(@mp3_dir, "#{name}.mp3"))
    track = @app.get_mp3_list.find { |item| item[:file] == name }
    assert_equal image, request(track[:artwork_url]).last
    %w[%2E%2E a%2Fb a%5Cb a%00b %FF].each do |basename|
      assert_equal 403, request("/artwork/#{basename}").first
    end
    outside = File.join(@tmp_dir, "outside.mp3")
    FileUtils.cp(File.join(@mp3_dir, "song.mp3"), outside)
    File.symlink(outside, File.join(@mp3_dir, "outside.mp3"))
    assert_equal 403, request("/artwork/outside").first
    File.symlink(File.join(@tmp_dir, "absent.mp3"), File.join(@mp3_dir, "absent.mp3"))
    assert_equal 404, request("/artwork/absent").first
  end

  def test_disappearing_and_unreadable_cache_files_have_valid_responses
    directory = Pathname.new(File.realpath(write_cache))
    playlist = directory.join("playlist.m3u8")
    @app.instance_variable_get(:@cache_dir).stub(:join, directory) do
      directory.stub(:join, playlist) do
        playlist.stub(:size, -> { raise Errno::ENOENT }) do
          assert_equal 404, request("/stream/song/playlist.m3u8").first
        end
        playlist.stub(:size, -> { raise Errno::EACCES }) do
          assert_equal 500, request("/stream/song/playlist.m3u8").first
        end
        playlist.stub(:open, ->(*) { raise Errno::EACCES }) do
          assert_equal 500, request("/stream/song/playlist.m3u8").first
        end
      end
    end
  end

  def test_dangling_source_symlink_returns_not_found
    File.symlink(File.join(@tmp_dir, "missing.mp3"), File.join(@mp3_dir, "missing.mp3"))
    assert_equal 404, request("/stream/missing/playlist.m3u8").first
  end

  def test_invalid_and_missing_paths
    ["/missing", "/stream/missing/playlist.m3u8", "/stream/song/segment999.mp3", "/stream/song/other.m3u8"].each do |path|
      assert_equal 404, request(path).first
    end
    ["/stream/%2E%2E/playlist.m3u8", "/stream/a%2Fb/playlist.m3u8", "/stream/a%00b/playlist.m3u8", "/stream/%FF/playlist.m3u8", "/stream/song/../../outside.mp3"].each do |path|
      assert_equal 403, request(path).first
    end
  end

  def test_symlinks_cannot_escape_source_or_cache
    outside = File.join(@tmp_dir, "outside.mp3")
    FileUtils.cp(File.join(@mp3_dir, "song.mp3"), outside)
    File.symlink(outside, File.join(@mp3_dir, "outside.mp3"))
    assert_equal 403, request("/stream/outside/playlist.m3u8").first
    refute @app.get_mp3_list.any? { |track| track[:file] == "outside" }
    dir = write_cache
    File.unlink(File.join(dir, "segment000.mp3"))
    File.symlink(outside, File.join(dir, "segment000.mp3"))
    assert_equal 403, request("/stream/song/segment000.mp3").first
    File.unlink(File.join(dir, "playlist.m3u8"))
    File.symlink(outside, File.join(dir, "playlist.m3u8"))
    assert_equal 403, request("/stream/song/playlist.m3u8").first
    FileUtils.rm_rf(dir)
    File.symlink(@tmp_dir, dir)
    assert_equal 403, request("/stream/song/playlist.m3u8").first
  end

  def test_static_assets_are_available
    app = Rack::Static.new(@app, urls: ["/style", "/player.js"], root: File.expand_path("../lib/public", __dir__))
    ["/player.js", "/style/main.css"].each { |path| assert_equal 200, request(path, app).first }
  end

  def test_cli_help_and_version_do_not_start_server
    out = StringIO.new
    assert_equal 0, MiniradioServer::CLI.run(["--version"], out: out)
    assert_equal "#{MiniradioServer::VERSION}\n", out.string
    out = StringIO.new
    assert_equal 0, MiniradioServer::CLI.run(["--help"], out: out)
    assert_includes out.string, "--mp3-dir"
    assert_equal 1, MiniradioServer::CLI.run(["--port", "0"], err: StringIO.new)
    assert_equal 1, MiniradioServer::CLI.run(["unexpected"], err: StringIO.new)
  end

  def test_cli_starts_with_configured_directories_port_and_assets
    out = StringIO.new
    runner = lambda do |app, **options|
      assert_equal 9393, options[:Port]
      assert_equal 200, request("/player.js", app).first
      assert_equal 200, request("/", app).first
    end
    Rackup::Handler::WEBrick.stub(:run, runner) do
      assert_equal 0, MiniradioServer::CLI.run(["--mp3-dir", @mp3_dir, "--cache-dir", @cache_dir, "--port", "9393"], out: out)
    end
    assert_includes out.string, "http://localhost:9393"
  end

  def test_cli_interrupt_exits_successfully
    out = StringIO.new
    Rackup::Handler::WEBrick.stub(:run, ->(*) { raise Interrupt }) do
      assert_equal 0, MiniradioServer::CLI.run(["--mp3-dir", @mp3_dir, "--cache-dir", @cache_dir], out: out)
    end
    assert_includes out.string, "Shutting down server."
  end

  def test_gem_requires_ruby_34_or_later
    spec = Gem::Specification.load(File.expand_path("../miniradio_server.gemspec", __dir__))
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.3.9"))
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.4.0"))
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.7"))
  end

  def test_gem_packages_executable_templates_and_assets
    spec = Gem::Specification.load(File.expand_path("../miniradio_server.gemspec", __dir__))
    assert_equal ["miniradio_server"], spec.executables
    %w[exe/miniradio_server lib/miniradio_server/cli.rb lib/miniradio_server/templ/index.html.slim lib/public/player.js lib/public/style/main.css README.md CHANGELOG.md LICENSE.txt].each do |path|
      assert_includes spec.files, path
    end
    refute spec.files.any? { |path| path.start_with?("test/", "bin/") }
  end

  def test_real_ffmpeg_converts_filenames_and_reuses_cache
    skip "FFmpeg is not installed" unless system("ffmpeg", "-version", out: File::NULL, err: File::NULL)
    ["song", "space song", "アイネクライネ", "plus+percent%"].each do |name|
      FileUtils.cp(File.join(@mp3_dir, "song.mp3"), File.join(@mp3_dir, "#{name}.mp3")) unless name == "song"
      url = @app.get_mp3_list.find { |track| track[:file] == name }[:url]
      status, headers, playlist = request(url)
      assert_equal 200, status
      assert_equal "application/vnd.apple.mpegurl", headers["content-type"]
      assert_includes playlist, "#EXT-X-ENDLIST"
      segment = playlist.lines.map(&:strip).find { |line| line.end_with?(".mp3") }
      assert_equal 200, request(url.sub("playlist.m3u8", segment)).first
      path = File.join(@cache_dir, name, "playlist.m3u8")
      mtime = File.mtime(path)
      assert_equal playlist, request(url).last
      assert_equal mtime, File.mtime(path)
    end
  end
end
