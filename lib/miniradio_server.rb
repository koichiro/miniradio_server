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

# --- Server Startup ---

# Only run server startup logic if the script is executed directly
if __FILE__ == $PROGRAM_NAME || 'bin/miniradio_server' == $PROGRAM_NAME || 'miniradio_server' == $PROGRAM_NAME
  logger = Logger.new(STDOUT)
  # Ensure directories exist before starting the app
  # Use constants defined within the module
  MiniradioServer.ensure_directories_exist(
    [MiniradioServer::MP3_SRC_DIR, MiniradioServer::HLS_CACHE_DIR],
    logger
  )

  logger.level = Logger::INFO

  # Check encoding settings, especially for non-ASCII filenames
  Encoding.default_external = Encoding::UTF_8 if Encoding.default_external != Encoding::UTF_8
  # Encoding.default_internal = Encoding::UTF_8 # Set internal encoding if needed

  # Use constants defined within the module
  app = MiniradioServer::App.new(
    MiniradioServer::MP3_SRC_DIR,
    MiniradioServer::HLS_CACHE_DIR,
    MiniradioServer::FFMPEG_COMMAND,
    MiniradioServer::HLS_SEGMENT_DURATION,
    logger
  )

  puts "Starting HLS conversion and streaming server on port #{MiniradioServer::SERVER_PORT}..."
  puts "MP3 Source Directory: #{MiniradioServer::MP3_SRC_DIR}"
  puts "HLS Cache Directory: #{MiniradioServer::HLS_CACHE_DIR}"
  puts "Default External Encoding: #{Encoding.default_external}" # For confirmation log
  puts "Using Handler: Rackup::Handler::WEBrick" # For confirmation log
  puts "Example Streaming URL: http://localhost:#{MiniradioServer::SERVER_PORT}/stream/{mp3_filename_without_extension}/playlist.m3u8"
  puts "e.g., If mp3_files/ contains my_music.mp3 -> http://localhost:#{MiniradioServer::SERVER_PORT}/stream/my_music/playlist.m3u8"
  puts "Press Ctrl+C to stop."

  begin
    # Use Rackup::Handler::WEBrick, recommended for Rack 3+
    Rackup::Handler::WEBrick.run(
      app,
      Port: MiniradioServer::SERVER_PORT,
      Logger: logger,       # Share logger with WEBrick
      AccessLog: []       # Disable WEBrick's own access log (logging handled by Rack app)
      # , :DoNotReverseLookup => true # Disable DNS reverse lookup for faster responses (optional)
    )
  rescue Interrupt # When stopped with Ctrl+C
    puts "\nShutting down server."
  rescue Errno::EADDRINUSE # Port already in use
    puts "Error: Port #{MiniradioServer::SERVER_PORT} is already in use."
    exit(1)
  rescue LoadError => e
    # Error handling if rackup/handler/webrick is not found
    if e.message.include?('rackup/handler/webrick')
      puts "Error: Rackup WEBrick handler not found."
      puts "Please install the rackup gem by running: `gem install rackup`"
    else
      puts "Library load error: #{e.message}"
    end
    exit(1)
  rescue => e
    puts "Server startup error: #{e.message}"
    puts e.backtrace.join("\n")
    exit(1)
  end
end
