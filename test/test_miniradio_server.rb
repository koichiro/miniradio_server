# frozen_string_literal: true

require "test_helper"

class TestMiniradioServer < Minitest::Test
  # Create a temporary directory before running tests
  def setup
    @tmp_dir = File.expand_path('../tmp_test_dirs', __dir__)
    FileUtils.mkdir_p(@tmp_dir)
    # Point constants to the temporary directory (keep original values)
    @original_mp3_src_dir = MiniradioServer.send(:remove_const, :MP3_SRC_DIR) if defined?(MiniradioServer::MP3_SRC_DIR)
    @original_hls_cache_dir = MiniradioServer.send(:remove_const, :HLS_CACHE_DIR) if defined?(MiniradioServer::HLS_CACHE_DIR)
    MiniradioServer.const_set(:MP3_SRC_DIR, File.join(@tmp_dir, 'mp3_files'))
    MiniradioServer.const_set(:HLS_CACHE_DIR, File.join(@tmp_dir, 'hls_cache'))
    @dummy_logger = Logger.new(IO::NULL)
  end

  # Delete the temporary directory after running tests and restore constants
  def teardown
    FileUtils.rm_rf(@tmp_dir)
    # Restore constants
    MiniradioServer.send(:remove_const, :MP3_SRC_DIR)
    MiniradioServer.send(:remove_const, :HLS_CACHE_DIR)
    MiniradioServer.const_set(:MP3_SRC_DIR, @original_mp3_src_dir) if @original_mp3_src_dir
    MiniradioServer.const_set(:HLS_CACHE_DIR, @original_hls_cache_dir) if @original_hls_cache_dir
  end

  def test_that_it_has_a_version_number
    refute_nil ::MiniradioServer::VERSION
  end

  def test_constants_are_defined
    # Whether they are defined is evaluated at require time, so here we check the values after redefinition
    assert_equal File.join(@tmp_dir, 'mp3_files'), MiniradioServer::MP3_SRC_DIR
    assert_equal File.join(@tmp_dir, 'hls_cache'), MiniradioServer::HLS_CACHE_DIR
    # Other constants are not changed in setup/teardown, so check them as they are
    assert defined?(MiniradioServer::SERVER_PORT)
    assert defined?(MiniradioServer::FFMPEG_COMMAND)
    assert defined?(MiniradioServer::HLS_SEGMENT_DURATION)
  end

  def test_directories_are_created_if_not_exist
    # Confirm that the directories do not exist
    refute Dir.exist?(MiniradioServer::MP3_SRC_DIR), "MP3_SRC_DIR should not exist before test"
    refute Dir.exist?(MiniradioServer::HLS_CACHE_DIR), "HLS_CACHE_DIR should not exist before test"

    # Call the refactored method directly
    # Use a dummy logger to suppress log output during tests
    MiniradioServer.ensure_directories_exist(
      [MiniradioServer::MP3_SRC_DIR, MiniradioServer::HLS_CACHE_DIR],
      @dummy_logger
    )

    assert Dir.exist?(MiniradioServer::MP3_SRC_DIR), "MP3_SRC_DIR should be created by ensure_directories_exist"
    assert Dir.exist?(MiniradioServer::HLS_CACHE_DIR), "HLS_CACHE_DIR should be created by ensure_directories_exist"
  end

  def test_generete_index
    MiniradioServer.ensure_directories_exist(
      [MiniradioServer::MP3_SRC_DIR, MiniradioServer::HLS_CACHE_DIR],
      @dummy_logger
    )

    # Copy sample mp3
    FileUtils.cp(Dir.glob("#{__dir__}/sample/*.mp3"), File.join(@tmp_dir, 'mp3_files'))

    app = MiniradioServer::App.new(
      MiniradioServer::MP3_SRC_DIR,
      MiniradioServer::HLS_CACHE_DIR,
      MiniradioServer::FFMPEG_COMMAND,
      MiniradioServer::HLS_SEGMENT_DURATION,
      @dummy_logger
    )
    assert_equal app.index, <<EOS.chomp
<!DOCTYPE html><html><head><meta charset=\"UTF-8\" /><meta content=\"width=device-width, initial-scale=1.0\" name=\"viewport\" /><title>Miniradio Server</title><link href=\"https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css\" rel=\"stylesheet\" type=\"text/css\" /><link href=\"style/main.css\" rel=\"stylesheet\" type=\"text/css\" /><script src=\"https://cdn.jsdelivr.net/npm/hls.js@1\"></script></head><body><h1>Straming List</h1><table class=\"compact striped\"><thead><tr><th scope=\"col\">Play</th><th scope=\"col\">Title</th><th scope=\"col\">Artist</th><th scope=\"col\">Album</th></tr></thead><tbody><tr><td><audio controls=\"\" id=\"audio-1\"></audio></td><td>eine 01</td><td></td><td></td></tr><tr><td><audio controls=\"\" id=\"audio-2\"></audio></td><td>eine</td><td></td><td></td></tr><tr><td><audio controls=\"\" id=\"audio-3\"></audio></td><td>アイネクライネ</td><td></td><td></td></tr></tbody></table><script>function setupHLS(audioElementId, streamUrl) {
    const audio = document.getElementById(audioElementId);

    if (Hls.isSupported()) {
        const hls = new Hls();
        hls.loadSource(streamUrl);
        hls.attachMedia(audio);
        hls.on(Hls.Events.MANIFEST_PARSED, function () {
            console.log(`${audioElementId} loaded`);
        });
    } else if (audio.canPlayType('application/vnd.apple.mpegurl')) {
        // HLS native support browser. ex.Safari
        audio.src = streamUrl;
    } else {
        console.error('This browser cannot play HLS.');
    }
}
var mp3s = [{\"title\":null,\"artist\":null,\"album\":null,\"file\":\"eine 01\"},{\"title\":null,\"artist\":null,\"album\":null,\"file\":\"eine\"},{\"title\":null,\"artist\":null,\"album\":null,\"file\":\"アイネクライネ\"}];
for (let i = 0; i < mp3s.length; i++) {
    setupHLS(`audio-${i+1}`, `/stream/${mp3s[i].file}/playlist.m3u8`);
}</script><hr /><p>Miniradio ver 0.0.3</p></body></html>
EOS
  end
end
