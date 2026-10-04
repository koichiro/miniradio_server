require "rack"
require "open3" # Used in convert_to_hls
require "tilt/slim"
require "mp3info"
require "json"
require "uri"
require "uri/rfc2396_parser"

# Required to use the handler from Rack 3+
# You might need to run: gem install rackup
require "rackup/handler/webrick"

# Rack application class
module MiniradioServer
  class App
    MAX_ARTWORK_BYTES = 5 * 1024 * 1024
    URL_PARSER = URI::RFC2396_Parser.new
    private_constant :URL_PARSER

    def initialize(mp3_dir, cache_dir, ffmpeg_cmd, segment_duration, logger)
      @mp3_dir = Pathname.new(mp3_dir).realpath
      @cache_dir = Pathname.new(cache_dir).realpath
      @ffmpeg_cmd = ffmpeg_cmd
      @segment_duration = segment_duration
      @logger = logger
      # For managing locks during conversion processing (using Mutex per file)
      @conversion_locks = Hash.new { |h, k| h[k] = Mutex.new } # Mutex is built-in, no require needed
      @locks_mutex = Mutex.new
    end

    def call(env)
      request_path = env["PATH_INFO"]
      @logger.info "Request received: #{request_path}"

      # Root URL
      match = request_path.match(%r{^/$|^/index(\.html)$})
      if match
        return response(200, index, "text/html")
      end

      if (artwork = request_path.match(%r{^/artwork/([^/]+)$}))
        _basename, source, error = mp3_source(artwork[1])
        return error if error
        return serve_artwork(source)
      end

      # Path pattern: /stream/{mp3_basename}/{playlist or segment}
      # mp3_basename is the filename without the extension
      match = request_path.match(%r{^/stream/([^/]+)/(.+\.(m3u8|mp3))$})

      unless match
        @logger.warn "Invalid request path format: #{request_path}"
        return not_found_response("Not Found (Invalid Path Format)")
      end

      mp3_basename, original_mp3_path, error = mp3_source(match[1])
      return error if error
      requested_filename = match[2] # e.g., "playlist.m3u8" or "segment001.mp3"
      extension = match[3].downcase # "m3u8" or "mp3"
      return not_found_response if extension == "m3u8" && requested_filename != "playlist.m3u8"

      # --- Build cache paths ---
      cache_subdir = @cache_dir.join(mp3_basename)
      hls_playlist_path = cache_subdir.join("playlist.m3u8")
      requested_cache_file_path = cache_subdir.join(requested_filename)

      # Check lexical paths and resolved ancestors, including symlinks.
      unless within_directory?(cache_subdir, @cache_dir) && within_directory?(requested_cache_file_path, cache_subdir)
        @logger.warn "Attempted access outside cache directory: #{requested_cache_file_path}"
        return forbidden_response("Access denied.")
      end

      # --- Process based on request type ---
      if extension == "m3u8"
        # M3U8 request: Check if conversion is needed, convert if necessary, and serve
        ensure_hls_converted(original_mp3_path, cache_subdir, hls_playlist_path) do |status, message|
          case status
          when :ok, :already_exists
            return serve_file(hls_playlist_path)
          when :converting
            # Another process/thread is converting
            return service_unavailable_response("Conversion in progress. Please try again shortly.")
          when :error
            return internal_server_error_response(message || "HLS conversion failed.")
          end
        end
      elsif extension == "mp3"
        # MP3 segment request: Serve from cache (404 if not found)
        # Normally, the m3u8 is requested first, so the cache should exist
        if requested_cache_file_path.exist? && requested_cache_file_path.file?
          serve_file(requested_cache_file_path)
        else
          # Segment request might come before m3u8, or an invalid request after conversion failure
          @logger.warn "Segment file not found (cache not generated or invalid request?): #{requested_cache_file_path}"
          # For simplicity, return 404. A more robust check might verify parent conversion status.
          not_found_response("Not Found (Segment)")
        end
      else
        # Should not reach here
        @logger.error "Unexpected file extension: #{extension}"
        internal_server_error_response
      end
    rescue SystemCallError => e # File access related errors (ENOENT, EACCES, etc.)
      @logger.error "File access error: #{e.message}"
      # Return 404 or 500 depending on the context
      not_found_response("Resource not found or access denied")
    rescue => e
      @logger.error "Unexpected error occurred: #{e.message}"
      @logger.error e.backtrace.join("\n")
      internal_server_error_response
    end

    def get_mp3_list
      r = []
      @mp3_dir.glob("*.mp3").each do |file|
        next unless file.file? && within_directory?(file, @mp3_dir)
        name = file.basename(".mp3").to_s
        encoded_file = URL_PARSER.escape(name, /[^a-zA-Z0-9\-._~]/)
        mp3 = {file: name, title: nil, artist: nil, album: nil,
               url: "/stream/#{encoded_file}/playlist.m3u8", artwork_url: "/artwork/#{encoded_file}"}
        begin
          Mp3Info.open(file) do |mp3info|
            mp3[:title] = mp3info.tag.title
            mp3[:artist] = mp3info.tag.artist
            mp3[:album] = mp3info.tag.album
          end
        rescue => e
          @logger.warn "Unable to read metadata for #{name}: #{e.message}"
        end
        r << mp3
      end
      r
    end

    def index
      template = Tilt::SlimTemplate.new("#{__dir__}/templ/index.html.slim")
      # JSON is data, but HTML still recognizes closing script tags inside it.
      tracks_json = JSON.generate(get_mp3_list).gsub("<", '\\u003c').gsub(">", '\\u003e').gsub("&", '\\u0026')
      template.render(self, tracks_json: tracks_json)
    end

    private

    # The stream and artwork routes share the same source validation.
    def mp3_source(encoded_name)
      name = URL_PARSER.unescape(encoded_name).force_encoding(Encoding::UTF_8)
      if !name.valid_encoding? || name.include?("\0") || name.include?("..") || name.include?("/") || name.include?("\\")
        return [nil, nil, forbidden_response("Invalid filename.")]
      end
      path = @mp3_dir.join("#{name}.mp3")
      return [nil, nil, forbidden_response("Access denied.")] unless within_directory?(path, @mp3_dir)
      return [nil, nil, not_found_response("Not Found (Original MP3)")] unless path.file?

      [name, path, nil]
    end

    def serve_artwork(source)
      Mp3Info.open(source) do |mp3|
        mp3.tag2.pictures.each do |_name, data|
          next unless data.is_a?(String) && data.bytesize <= MAX_ARTWORK_BYTES
          data = data.b
          mime = if data.start_with?("\x89PNG\r\n\x1a\n".b)
            "image/png"
          elsif data.start_with?("\xff\xd8\xff".b)
            "image/jpeg"
          end
          next unless mime

          return [200, {"content-type" => mime, "content-length" => data.bytesize.to_s,
                        "cache-control" => "no-store", "x-content-type-options" => "nosniff"}, [data]]
        end
      end
      not_found_response("No supported artwork")
    rescue => e
      @logger.warn "Unable to read artwork: #{e.message}"
      not_found_response("No supported artwork")
    end

    # Resolve existing ancestors as well as files, so symlinks cannot escape a
    # configured directory before conversion or when serving cached segments.
    def within_directory?(path, directory)
      return false unless path.to_s.start_with?(directory.to_s + File::SEPARATOR) || path == directory

      ancestor = path
      ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
      resolved = ancestor.realpath.join(path.relative_path_from(ancestor))
      root = directory.exist? ? directory.realpath : directory
      resolved == root || resolved.to_s.start_with?(root.to_s + File::SEPARATOR)
    end

    # Check if HLS conversion is needed and execute if necessary (with lock)
    # Yields the status (:ok, :already_exists, :converting, :error) and an optional message to the block
    def ensure_hls_converted(input_mp3_path, output_dir, playlist_path)
      mp3_basename = input_mp3_path.basename(".mp3").to_s
      lock = @locks_mutex.synchronize { @conversion_locks[mp3_basename] }

      # Check if the converted file already exists (check outside lock for speed)
      if playlist_path.exist?
        yield(:already_exists, nil)
        return
      end

      # Use Mutex for exclusive control of conversion processing
      if lock.try_lock # If the lock is acquired, execute the conversion process
        begin
          # After acquiring the lock, check file existence again (another thread might have just finished)
          if playlist_path.exist?
            yield(:already_exists, nil)
            return
          end

          @logger.info "[#{mp3_basename}] Starting HLS conversion..."
          success, error_msg = convert_to_hls(input_mp3_path, output_dir)

          if success
            @logger.info "[#{mp3_basename}] HLS conversion completed."
            yield(:ok, nil)
          else
            @logger.error "[#{mp3_basename}] HLS conversion failed. Error: #{error_msg}"
            yield(:error, error_msg)
          end
        ensure
          lock.unlock # Always release the lock
        end
      else
        # Failed to acquire lock = another thread is converting
        @logger.info "[#{mp3_basename}] is currently being converted by another request."
        yield(:converting, nil)
      end
    end

    # Convert MP3 file to HLS format (execute ffmpeg)
    # Returns: [Boolean (success/failure), String (error message or nil)]
    def convert_to_hls(input_mp3_path, output_dir)
      # Create the output directory
      FileUtils.mkdir_p(output_dir) unless output_dir.exist?

      playlist_path = output_dir.join("playlist.m3u8")
      segment_path_template = output_dir.join("segment%03d.mp3") # %03d is replaced by ffmpeg with sequence number

      # Build the ffmpeg command (using an array is safer for paths with spaces)
      cmd = [
        @ffmpeg_cmd,
        "-y",                               # Overwrite existing files (just in case)
        "-i", input_mp3_path.to_s,
        "-c:a", "copy",                     # Copy audio codec (no re-encoding)
        "-f", "hls",
        "-hls_time", @segment_duration.to_s,
        "-hls_list_size", "0",              # VOD (include all segments in the list)
        "-hls_playlist_type", "vod",        # Specify VOD playlist type
        "-hls_segment_filename", segment_path_template.to_s,
        playlist_path.to_s
      ]

      @logger.info "Executing command: #{cmd.join(" ")}"

      # Execute command (capture standard output, standard error, and status)
      _stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        error_message = "ffmpeg exited with status #{status.exitstatus}. Stderr: #{stderr.strip}"
        @logger.error "ffmpeg command execution failed. #{error_message}"
        # If failed, attempt to delete potentially incomplete cache directory
        begin
          FileUtils.rm_rf(output_dir.to_s) if output_dir.exist?
        rescue => e
          @logger.error "Error occurred while deleting cache directory: #{output_dir}, Error: #{e.message}"
        end
        return [false, error_message]
      end

      # Log warnings from stderr even on success (if necessary), ignoring common deprecation warnings
      unless stderr.empty? || stderr.strip.downcase.include?("deprecated")
        @logger.warn "ffmpeg stderr (on success): #{stderr.strip}"
      end

      [true, nil]
    rescue Errno::ENOENT => e # Command not found, etc.
      error_message = "Error occurred during ffmpeg command preparation: #{e.message}"
      @logger.error error_message
      [false, error_message]
    rescue => e # Catch other exceptions around ffmpeg execution
      error_message = "Unexpected error occurred during ffmpeg execution: #{e.message}"
      @logger.error error_message
      # Attempt to clean up cache dir on unexpected error too
      begin
        FileUtils.rm_rf(output_dir.to_s) if output_dir.exist?
      rescue => e_rm
        @logger.error "Error occurred while deleting cache directory: #{output_dir}, Error: #{e_rm.message}"
      end
      [false, error_message]
    end

    # Serve the file
    def serve_file(file_path)
      extension = file_path.extname.downcase
      content_type = case extension
      when ".m3u8"
        "application/vnd.apple.mpegurl" # Or 'audio/mpegurl'
      when ".mp3"
        "audio/mpeg"
      else
        @logger.warn "Serving attempt: Unsupported file type: #{file_path}"
        return forbidden_response("Unsupported file type.")
      end

      # Re-check file existence and type (just before serving)
      unless file_path.exist? && file_path.file?
        @logger.warn "File to serve not found (serve_file): #{file_path}"
        return not_found_response("Not Found (Serving File)")
      end

      # Get file size (with error handling)
      begin
        file_size = file_path.size
      rescue Errno::ENOENT
        @logger.error "Failed to get file size (file disappeared?): #{file_path}"
        return not_found_response("Not Found (File disappeared)")
      rescue SystemCallError => e # Other file access errors
        @logger.error "Failed to get file size: #{file_path}, Error: #{e.message}"
        return internal_server_error_response("Failed to get file size")
      end

      headers = {
        "content-type" => content_type,
        "content-length" => file_size.to_s,
        "access-control-allow-origin" => "*", # CORS header
        # For HLS, it's often safer not to cache (especially for live streams)
        # For VOD, caching might be okay, but we'll disable it here for simplicity
        "cache-control" => "no-cache, no-store, must-revalidate",
        "pragma" => "no-cache",
        "expires" => "0"
      }

      @logger.info "Serving: #{file_path} (#{content_type}, #{file_size} bytes)"

      # Return the File object as the response body (Rack handles streaming efficiently)
      begin
        # Open in binary mode
        file_body = file_path.open("rb")
        [200, headers, file_body]
      rescue SystemCallError => e # Error during file opening
        @logger.error "Failed to open file: #{file_path}, Error: #{e.message}"
        # Rack should handle closing the file even if opened, so no explicit close needed here
        internal_server_error_response("Failed to open file")
      end
    end

    # --- HTTP Status Code Response Methods ---
    def response(status, message, content_type = "text/plain", extra_headers = {})
      headers = {
        "content-type" => content_type,
        "access-control-allow-origin" => "*"
      }.merge(extra_headers)
      # Returning the body as an array is the Rack specification
      [status, headers, [message + "\n"]]
    end

    def not_found_response(message = "Not Found")
      response(404, message)
    end

    def forbidden_response(message = "Forbidden")
      response(403, message)
    end

    def internal_server_error_response(message = "Internal Server Error")
      response(500, message)
    end

    def service_unavailable_response(message = "Service Unavailable")
      # Add Retry-After header suggesting a retry after 5 seconds
      response(503, message, "text/plain", {"retry-after" => "5"})
    end
  end
end
