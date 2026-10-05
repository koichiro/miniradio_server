# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"
require "minitest/mock"

class TestHlsCache < Minitest::Test
  PLAYLIST = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:10.0,\nsegment000.mp3\n#EXT-X-ENDLIST\n"
  SETTINGS = {ffmpeg: "ffmpeg", segment_duration: 10, audio_codec: "copy"}.freeze

  def setup
    @tmp = Dir.mktmpdir("hls-cache-test")
    @logger = Logger.new(IO::NULL)
    @cache = MiniradioServer::HlsCache.new(@tmp, @logger)
    @root = Pathname.new(@tmp).join(".miniradio-hls-v1")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def output(job, playlist = PLAYLIST)
    job.output.join("playlist.m3u8").write(playlist)
    job.output.join("segment000.mp3").write("segment data")
  end

  def publish
    @cache.with_job do |job|
      output(job)
      @cache.publish("song", job, SETTINGS)
    end
  end

  def stale_job(id = "a" * 32)
    path = @root.join("jobs", "job-#{id}")
    path.mkdir
    path.join("lease.lock").write("")
    path.join("output").mkdir
    path
  end

  def test_only_completed_referenced_files_are_available_across_restarts
    @cache.with_job do |job|
      output(job)
      job.output.join("segment001.mp3").write("unreferenced")
      assert_nil @cache.fetch("song")
      entry = @cache.publish("song", job, SETTINGS)
      assert_equal PLAYLIST, entry.file("playlist.m3u8").read
      assert_nil entry.file("segment001.mp3")
      assert_nil entry.file("complete.json")
    end
    restarted = MiniradioServer::HlsCache.new(@tmp, @logger)
    assert_equal PLAYLIST, restarted.fetch("song").file("playlist.m3u8").read
    assert_empty @root.join("jobs").children
    assert_empty @root.join("trash").children
  end

  def test_rejects_incomplete_or_unsupported_playlists_before_publication
    malformed = ["", "garbage\n", PLAYLIST.delete_suffix("#EXT-X-ENDLIST\n"),
      PLAYLIST.sub("#EXT-X-PLAYLIST-TYPE:VOD\n", ""), PLAYLIST.sub("VOD", "EVENT"),
      PLAYLIST.sub("TARGETDURATION:10", "TARGETDURATION:0"),
      PLAYLIST.sub("#EXTINF:10.0,\n", ""), PLAYLIST.sub("#EXTINF:10.0,", "#EXTINF:0,"),
      PLAYLIST.sub("#EXTINF:10.0,", "#EXTINF:NaN,"),
      PLAYLIST.sub("#EXTINF:10.0,", "#EXTINF:11.0,"),
      PLAYLIST.sub("#EXTINF:10.0,", "#EXTINF:#{"9" * 400},"),
      PLAYLIST.sub("#EXTINF:10.0,", "#EXTINF:10.0,\n#EXTINF:10.0,"),
      PLAYLIST.sub("#EXT-X-ENDLIST", "#EXTINF:1.0,\n#EXT-X-ENDLIST"),
      PLAYLIST.sub("#EXT-X-ENDLIST", "#EXTINF:1.0,\nsegment000.mp3\n#EXT-X-ENDLIST"),
      PLAYLIST.sub("#EXT-X-VERSION:3", "#EXT-X-VERSION:3\n#EXT-X-VERSION:3"),
      PLAYLIST.sub("segment000.mp3", "segment000.mp3\n#EXT-X-VERSION:3"),
      PLAYLIST.sub("segment000.mp3", "../segment000.mp3"),
      PLAYLIST.sub("segment000.mp3", "/segment000.mp3"),
      PLAYLIST.sub("segment000.mp3", "https://example.test/segment000.mp3"),
      PLAYLIST.sub("segment000.mp3", "segment000.mp3?x=1"),
      PLAYLIST.sub("#EXTINF:10.0,", '#EXT-X-KEY:METHOD=AES-128,URI="key"'),
      PLAYLIST.sub("#EXTINF:10.0,", "#EXT-X-STREAM-INF:BANDWIDTH=128000"),
      PLAYLIST.sub("VOD", "\xff".b.force_encoding("UTF-8"))]
    malformed.each do |playlist|
      @cache.with_job do |job|
        output(job, playlist)
        assert_raises(MiniradioServer::HlsCache::InvalidOutput) { @cache.publish("song", job, SETTINGS) }
        refute @cache.directory("song").exist?
      end
    end
    assert_empty @root.join("jobs").children
  end

  def test_rejects_missing_empty_and_nonregular_segments
    [:missing, :empty, :directory].each do |kind|
      @cache.with_job do |job|
        output(job)
        segment = job.output.join("segment000.mp3")
        segment.delete
        segment.write("") if kind == :empty
        segment.mkdir if kind == :directory
        assert_raises(MiniradioServer::HlsCache::InvalidOutput) { @cache.publish("song", job, SETTINGS) }
      end
    end
  end

  def test_damaged_completion_playlist_and_segments_are_cache_misses
    changes = [
      ->(dir) { dir.join("complete.json").delete },
      ->(dir) { dir.join("complete.json").write("{broken") },
      ->(dir) { dir.join("complete.json").write("[]") },
      ->(dir) { dir.join("complete.json").write('{"schema_version":2}') },
      ->(dir) { dir.join("playlist.m3u8").write(PLAYLIST.sub("VERSION:3", "VERSION:4")) },
      ->(dir) { dir.join("segment000.mp3").delete },
      ->(dir) { dir.join("segment000.mp3").write("changed segment size") }
    ]
    changes.each do |change|
      entry = publish
      change.call(entry.directory)
      assert_nil @cache.fetch("song")
      @cache.discard_invalid("song")
      refute entry.directory.exist?
    end
    publish
    record = @cache.directory("song").join("complete.json")
    metadata = JSON.parse(record.read)
    metadata["settings"] = nil
    record.write(JSON.generate(metadata))
    assert_nil @cache.fetch("song")
  end

  def test_publication_failure_does_not_expose_output_or_replace_existing_cache
    @cache.with_job do |job|
      output(job)
      File.stub(:rename, ->(*) { raise Errno::EXDEV }) do
        assert_raises(Errno::EXDEV) { @cache.publish("song", job, SETTINGS) }
      end
      assert_nil @cache.fetch("song")
      assert job.output.join("complete.json").file?
    end
    entry = publish
    @cache.with_job do |job|
      output(job)
      assert_raises(MiniradioServer::HlsCache::InvalidOutput) { @cache.publish("song", job, SETTINGS) }
    end
    assert_equal PLAYLIST, entry.file("playlist.m3u8").read
  end

  def test_startup_cleans_abandoned_jobs_but_preserves_ready_and_unknown_paths
    publish
    abandoned = stale_job
    abandoned.join("output", "playlist.m3u8").write("partial")
    unknown = @root.join("jobs", "unknown")
    unknown.mkdir
    missing_lease = @root.join("jobs", "job-#{"b" * 32}")
    missing_lease.mkdir
    unexpected_file = stale_job("c" * 32)
    unexpected_file.join("unrecognized").write("keep")
    quarantined = @root.join("trash", "cache-#{"d" * 32}")
    quarantined.mkdir
    quarantined.join("partial").write("abandoned")
    restarted = MiniradioServer::HlsCache.new(@tmp, @logger)
    refute abandoned.exist?
    refute quarantined.exist?
    assert unknown.exist?
    assert missing_lease.exist?
    assert unexpected_file.exist?
    assert restarted.fetch("song")
  end

  def test_cleanup_skips_symlink_trees_and_preserves_external_files
    outside = Pathname.new(@tmp).join("outside")
    outside.mkdir
    outside.join("keep").write("safe")
    job = stale_job
    job.join("output", "link").make_symlink(outside)
    trash = @root.join("trash", "cache-#{"e" * 32}")
    trash.make_symlink(outside)
    @cache.cleanup
    assert job.exist?
    assert trash.symlink?
    assert_equal "safe", outside.join("keep").read
    @cache.with_job do |active|
      MiniradioServer::HlsCache.new(@tmp, @logger)
      assert active.directory.exist?
    end
  end

  def test_namespace_symlinks_and_special_files_are_rejected
    root = Pathname.new(@tmp).join("other")
    root.mkdir
    root.join(".miniradio-hls-v1").make_symlink(@root)
    assert_raises(MiniradioServer::HlsCache::AccessDenied) { MiniradioServer::HlsCache.new(root, @logger) }
    @cache.with_job do |job|
      output(job)
      fifo = job.output.join("fifo")
      assert system("mkfifo", fifo.to_s)
      assert_raises(MiniradioServer::HlsCache::InvalidOutput) { @cache.publish("song", job, SETTINGS) }
      fifo.delete
    end
  end

  def test_inherited_lease_protects_a_child_after_the_owner_closes_it
    reader, writer = IO.pipe
    control_reader, control_writer = IO.pipe
    child = nil
    directory = nil
    @cache.with_job do |job|
      directory = job.directory
      child = Process.spawn(RbConfig.ruby, "-e", 'STDOUT.write("ready\\n"); STDOUT.flush; STDIN.read',
        job.lease.fileno => job.lease, :out => writer, :in => control_reader)
      control_reader.close
      writer.close
      Timeout.timeout(5) { assert_equal "ready\n", reader.gets }
    end
    assert directory.exist?, "A child still owns the job lease"
    MiniradioServer::HlsCache.new(@tmp, @logger)
    assert directory.exist?, "Startup must not remove an orphan's output"
    Process.kill("TERM", child)
    Process.wait(child)
    child = nil
    @cache.cleanup
    refute directory.exist?
  ensure
    if child
      Process.kill("KILL", child)
      Process.wait(child)
    end
    reader&.close
    writer&.close unless writer&.closed?
    control_reader&.close unless control_reader&.closed?
    control_writer&.close
  end

  def test_real_ffmpeg_retains_lease_until_it_exits
    skip "FFmpeg is not installed" unless system("ffmpeg", "-version", out: File::NULL, err: File::NULL)

    reader, writer = IO.pipe
    child = directory = nil
    @cache.with_job do |job|
      directory = job.directory
      child = Process.spawn("ffmpeg", "-loglevel", "error", "-re", "-stream_loop", "-1",
        "-i", File.join(__dir__, "sample/eine.mp3"), "-c:a", "copy", "-f", "hls",
        "-hls_time", "10", "-hls_list_size", "0", "-hls_playlist_type", "vod",
        "-hls_segment_filename", job.output.join("segment%03d.mp3").to_s,
        "-progress", "pipe:1", job.output.join("playlist.m3u8").to_s,
        job.lease.fileno => job.lease, :out => writer, :err => File::NULL)
      writer.close
      Timeout.timeout(10) { assert reader.gets, "FFmpeg should report progress after startup" }
    end
    assert directory.exist?
    MiniradioServer::HlsCache.new(@tmp, @logger)
    assert directory.exist?, "A running FFmpeg must retain its inherited lease"
    assert_nil @cache.fetch("song")
    Process.kill("TERM", child)
    Process.wait(child)
    child = nil
    @cache.cleanup
    refute directory.exist?
  ensure
    if child
      Process.kill("KILL", child)
      Process.wait(child)
    end
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_cleanup_failure_after_publication_keeps_ready_cache_and_can_retry
    FileUtils.stub(:remove_entry, ->(*) { raise Errno::EACCES }) { publish }
    assert @cache.fetch("song")
    refute_empty @root.join("trash").children
    @cache.cleanup
    assert_empty @root.join("trash").children
    assert @cache.fetch("song")
  end

  def test_killed_owner_before_and_after_rename_recovers_on_startup
    code = <<~'RUBY'
      require "miniradio_server"
      root, phase, playlist = ARGV
      cache = MiniradioServer::HlsCache.new(root, Logger.new(IO::NULL))
      original = File.method(:rename)
      File.define_singleton_method(:rename) do |from, to|
        if File.basename(from) == "output"
          original.call(from, to) if phase == "after"
          STDOUT.write("ready\n")
          STDOUT.flush
          STDIN.read
        else
          original.call(from, to)
        end
      end
      cache.with_job do |job|
        job.output.join("playlist.m3u8").write(playlist)
        job.output.join("segment000.mp3").write("segment data")
        cache.publish("song", job, {ffmpeg: "ffmpeg", segment_duration: 10, audio_codec: "copy"})
      end
    RUBY
    owner = reader = writer = control_reader = control_writer = nil
    %w[before after].each do |phase|
      reader, writer = IO.pipe
      control_reader, control_writer = IO.pipe
      owner = Process.spawn(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code,
        @tmp, phase, PLAYLIST, out: writer, in: control_reader)
      writer.close
      control_reader.close
      Timeout.timeout(10) { assert_equal "ready\n", reader.gets }
      assert_equal phase == "after", !!@cache.fetch("song")
      Process.kill("KILL", owner)
      Process.wait(owner)
      owner = nil
      restarted = MiniradioServer::HlsCache.new(@tmp, @logger)
      assert_empty @root.join("jobs").children
      assert_equal phase == "after", !!restarted.fetch("song")
      reader.close
      control_writer.close
    end
  ensure
    if owner
      Process.kill("KILL", owner)
      Process.wait(owner)
    end
    [reader, writer, control_reader, control_writer].each { |io| io&.close unless io&.closed? }
  end
end
