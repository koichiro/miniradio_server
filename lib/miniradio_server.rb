# frozen_string_literal: true

require 'logger'
require 'pathname'
require 'fileutils'

require_relative "miniradio_server/version"

module MiniradioServer
  class Error < StandardError; end

  # --- Configuration ---
  # Directory containing the original MP3 files
  MP3_SRC_DIR = File.expand_path('./mp3_files')
  # Directory to cache the HLS converted content
  HLS_CACHE_DIR = File.expand_path('./hls_cache')
  # Port the server will listen on
  SERVER_PORT = 9292
  # Path to the ffmpeg command (usually just 'ffmpeg' if it's in the system PATH)
  FFMPEG_COMMAND = 'ffmpeg'
  # HLS segment duration in seconds
  HLS_SEGMENT_DURATION = 10
  # ---

  # --- Helper Methods ---

  # Ensures that the necessary directories exist, creating them if they don't.
  # @param dirs [Array<String>] An array of directory paths to check and create.
  # @param logger [Logger] Logger instance for outputting information.
  def self.ensure_directories_exist(dirs, logger)
    dirs.each do |dir|
      unless Dir.exist?(dir)
        logger.info("Creating directory: #{dir}")
        FileUtils.mkdir_p(dir)
      end
    end
  end
end

require_relative "miniradio_server/app"
