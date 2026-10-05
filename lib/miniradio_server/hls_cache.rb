# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "fileutils"
require "securerandom"

module MiniradioServer
  # Only whole, validated VOD caches are visible to the HTTP application.
  class HlsCache
    class AccessDenied < StandardError; end
    class InvalidOutput < StandardError; end

    SEGMENT_NAME = /\Asegment[0-9]{3,}\.mp3\z/
    JOB_NAME = /\Ajob-[0-9a-f]{32}\z/
    TRASH_NAME = /\Acache-[0-9a-f]{32}\z/
    Job = Struct.new(:directory, :output, :lease)
    Entry = Struct.new(:directory, :segments) do
      def file(name)
        directory.join(name) if name == "playlist.m3u8" || segments.key?(name)
      end
    end

    def initialize(cache_dir, logger)
      @cache_dir = Pathname.new(cache_dir).realpath
      @root = @cache_dir.join(".miniradio-hls-v1")
      @ready = @root.join("ready")
      @jobs = @root.join("jobs")
      @trash = @root.join("trash")
      @logger = logger
      [@root, @ready, @jobs, @trash].each do |directory|
        check_path!(directory)
        directory.mkdir(0o700) unless directory.exist?
      end
      cleanup
    end

    def directory(name)
      check_path!(@ready.join(Digest::SHA256.hexdigest(name)))
    end

    # Missing or damaged caches are misses. Unsafe paths are never regenerated
    # or removed: the application reports them as access denied instead.
    def fetch(name)
      path = directory(name)
      return unless path.exist?

      check_tree!(path)
      metadata = JSON.parse(path.join("complete.json").read)
      playlist, segments = validate_output(path)
      unless metadata.is_a?(Hash) && metadata["schema_version"] == 1 &&
          metadata["track_key"] == path.basename.to_s &&
          valid_settings?(metadata["settings"]) &&
          metadata["playlist_sha256"] == Digest::SHA256.hexdigest(playlist) &&
          metadata["segments"] == segments
        raise InvalidOutput, "Completion record does not match output"
      end
      Entry.new(path, segments)
    rescue InvalidOutput, JSON::ParserError, Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR => e
      @logger.warn "Invalid HLS cache: #{e.message}"
      nil
    end

    def discard_invalid(name)
      path = directory(name)
      return unless path.exist?

      check_tree!(path)
      target = check_path!(@trash.join("cache-#{SecureRandom.hex(16)}"))
      File.rename(path, target)
      clean_cache(target)
    end

    def with_job
      path = check_path!(@jobs.join("job-#{SecureRandom.hex(16)}"))
      path.mkdir(0o700)
      lease = File.open(path.join("lease.lock"), File::RDWR | File::CREAT | File::EXCL, 0o600)
      lease.flock(File::LOCK_EX)
      output = path.join("output")
      output.mkdir(0o700)
      yield Job.new(path, output, lease)
    ensure
      # Do not LOCK_UN: an orphaned child may still hold this open description.
      lease&.close
      clean_job(path) if path
    end

    def publish(name, job, settings)
      playlist, segments = validate_output(job.output)
      metadata = {
        schema_version: 1, track_key: Digest::SHA256.hexdigest(name),
        settings: settings, playlist_sha256: Digest::SHA256.hexdigest(playlist),
        segments: segments
      }
      completion = check_path!(job.output.join("complete.json"))
      File.open(completion, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(metadata))
      end
      target = directory(name)
      raise InvalidOutput, "Publication target already exists" if target.exist?

      # No copy fallback: all files become visible in one filesystem rename.
      File.rename(job.output, target)
      Entry.new(target, segments)
    end

    def cleanup
      @jobs.children.each { |path| clean_job(path) }
      @trash.children.each do |path|
        if JOB_NAME.match?(path.basename.to_s)
          clean_job(path)
        else
          clean_cache(path)
        end
      end
    end

    private

    def valid_settings?(settings)
      settings.is_a?(Hash) && settings["ffmpeg"].is_a?(String) &&
        settings["segment_duration"].is_a?(Numeric) && settings["segment_duration"] > 0 &&
        settings["audio_codec"] == "copy"
    end

    # Reject even in-root symlinks in the private namespace. Configured root
    # symlinks have already been resolved, preserving existing source policy.
    def check_path!(path)
      relative = path.relative_path_from(@cache_dir)
      raise AccessDenied, "Path outside cache" if relative.each_filename.include?("..")

      current = @cache_dir
      relative.each_filename do |part|
        current = current.join(part)
        raise AccessDenied, "Symlink in HLS cache" if current.symlink?
      end
      path
    end

    def check_tree!(path)
      check_path!(path)
      if path.directory?
        path.children.each { |child| check_tree!(child) }
      elsif !path.file?
        raise InvalidOutput, "Not a regular file or directory"
      end
    end

    def validate_output(path)
      check_tree!(path)
      playlist = path.join("playlist.m3u8").read
      names = playlist_segments(playlist)
      segments = names.to_h do |name|
        file = check_path!(path.join(name))
        raise InvalidOutput, "Missing or empty segment" unless file.file? && file.size > 0

        [name, file.size]
      end
      [playlist, segments]
    end

    # A deliberately small parser for the media playlists generated here.
    # Unknown tags are rejected, including KEY, MAP, BYTERANGE and master tags.
    def playlist_segments(playlist)
      raise InvalidOutput, "Invalid playlist encoding" unless playlist.valid_encoding?

      lines = playlist.lines.map(&:strip).reject(&:empty?)
      unless lines.first == "#EXTM3U" && lines.last == "#EXT-X-ENDLIST"
        raise InvalidOutput, "Incomplete playlist"
      end
      headers = {}
      segments = {}
      duration = nil
      lines[1...-1].each do |line|
        if (match = line.match(/\A#EXTINF:([0-9]+(?:\.[0-9]+)?),[^\r\n]*\z/))
          raise InvalidOutput, "Invalid EXTINF" if duration

          duration = Float(match[1])
          unless duration.finite? && duration > 0 && headers["PLAYLIST-TYPE"] == "VOD" && headers["TARGETDURATION"]
            raise InvalidOutput, "Missing VOD headers or invalid duration"
          end
        elsif SEGMENT_NAME.match?(line)
          unless duration && duration.round <= headers["TARGETDURATION"].to_i && !segments.key?(line)
            raise InvalidOutput, "Invalid segment entry"
          end
          segments[line] = true
          duration = nil
        elsif (match = line.match(/\A#EXT-X-(PLAYLIST-TYPE|TARGETDURATION|VERSION|MEDIA-SEQUENCE|ALLOW-CACHE):(.+)\z/))
          tag, value = match.captures
          valid = case tag
          when "PLAYLIST-TYPE" then value == "VOD"
          when "ALLOW-CACHE" then %w[YES NO].include?(value)
          when "MEDIA-SEQUENCE" then /\A[0-9]+\z/.match?(value)
          else /\A[1-9][0-9]*\z/.match?(value)
          end
          unless valid && !headers.key?(tag) && segments.empty? && !duration
            raise InvalidOutput, "Invalid playlist header"
          end
          headers[tag] = value
        else
          raise InvalidOutput, "Unsupported playlist entry"
        end
      end
      raise InvalidOutput, "No segments or unfinished EXTINF" if segments.empty? || duration

      segments.keys
    end

    def clean_job(path)
      unless JOB_NAME.match?(path.basename.to_s)
        @logger.warn "HLS job cleanup skipped: unknown job #{path.basename}"
        return
      end
      return unless path.exist? || path.symlink?

      check_tree!(path)
      unless path.directory? && (path.children.map { |p| p.basename.to_s } - %w[lease.lock output]).empty?
        @logger.warn "HLS job cleanup skipped: unknown job structure"
        return
      end

      lease_path = check_path!(path.join("lease.lock"))
      unless lease_path.file?
        @logger.warn "HLS job cleanup skipped: missing lease"
        return
      end

      File.open(lease_path, File::RDWR | File::NOFOLLOW) do |lease|
        next unless lease.flock(File::LOCK_EX | File::LOCK_NB)

        target = check_path!(@trash.join(path.basename))
        File.rename(path, target) unless path.parent == @trash
        FileUtils.remove_entry(target)
      end
    rescue => e
      @logger.warn "HLS job cleanup skipped: #{e.message}"
    end

    def clean_cache(path)
      unless TRASH_NAME.match?(path.basename.to_s)
        @logger.warn "HLS trash cleanup skipped: unknown target #{path.basename}"
        return
      end

      check_tree!(path)
      FileUtils.remove_entry(path)
    rescue => e
      @logger.warn "HLS trash cleanup skipped: #{e.message}"
    end
  end
end
