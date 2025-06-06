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
    FileUtils.cp("#{__dir__}/sample/eine.mp3", File.join(@tmp_dir, 'mp3_files'))

    app = MiniradioServer::App.new(
      MiniradioServer::MP3_SRC_DIR,
      MiniradioServer::HLS_CACHE_DIR,
      MiniradioServer::FFMPEG_COMMAND,
      MiniradioServer::HLS_SEGMENT_DURATION,
      @dummy_logger
    )
    assert_equal app.index, "<!DOCTYPE html><html><body><ul><li><a href=\"/stream/eine/playlist.m3u8\">eine.mp3</a> </li></ul></body></html>"
  end
end
