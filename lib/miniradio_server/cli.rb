# frozen_string_literal: true

require 'optparse'
require_relative '../miniradio_server'

module MiniradioServer
  module CLI
    def self.run(argv = ARGV, out: $stdout, err: $stderr)
      options = {
        mp3_dir: MP3_SRC_DIR, cache_dir: HLS_CACHE_DIR,
        port: SERVER_PORT, ffmpeg: FFMPEG_COMMAND,
        segment_duration: HLS_SEGMENT_DURATION
      }
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: miniradio_server [options]'
        opts.on('--mp3-dir PATH', 'Directory containing MP3 files') { |value| options[:mp3_dir] = value }
        opts.on('--cache-dir PATH', 'HLS cache directory') { |value| options[:cache_dir] = value }
        opts.on('--port PORT', Integer, 'HTTP port (default: 9292)') { |value| options[:port] = value }
        opts.on('--ffmpeg PATH', 'FFmpeg executable') { |value| options[:ffmpeg] = value }
        opts.on('--version', 'Print the version') { out.puts(VERSION); return 0 }
        opts.on('-h', '--help', 'Print this help') { out.puts(opts); return 0 }
      end
      remaining = parser.parse(argv)
      raise OptionParser::InvalidArgument, remaining.join(' ') unless remaining.empty?
      raise OptionParser::InvalidArgument, 'port must be between 1 and 65535' unless (1..65535).cover?(options[:port])

      logger = Logger.new(out)
      logger.level = Logger::INFO
      MiniradioServer.ensure_directories_exist([options[:mp3_dir], options[:cache_dir]], logger)
      app = App.new(options[:mp3_dir], options[:cache_dir], options[:ffmpeg], options[:segment_duration], logger)
      out.puts "Starting Miniradio Server #{VERSION} on port #{options[:port]}..."
      out.puts "MP3 Source Directory: #{File.expand_path(options[:mp3_dir])}"
      out.puts "HLS Cache Directory: #{File.expand_path(options[:cache_dir])}"
      out.puts "Server URL: http://localhost:#{options[:port]}"
      out.puts 'Press Ctrl+C to stop.'
      Rackup::Handler::WEBrick.run(
        Rack::Static.new(app, urls: ['/style', '/player.js'], root: File.expand_path('../public', __dir__)),
        Port: options[:port], Logger: logger, AccessLog: []
      )
      0
    rescue Interrupt
      out.puts "\nShutting down server."
      0
    rescue OptionParser::ParseError, SystemCallError => e
      err.puts "Error: #{e.message}"
      1
    end
  end
end
