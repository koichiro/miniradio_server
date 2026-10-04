# Miniradio Server

[![Gem version](https://img.shields.io/gem/v/miniradio_server)](https://rubygems.org/gems/miniradio_server)
[![Gem downloads](https://img.shields.io/gem/dt/miniradio_server)](https://rubygems.org/gems/miniradio_server)

A small Ruby/Rack server that streams existing MP3 files via HTTP Live Streaming
(HLS). FFmpeg converts each track on its first request; later requests reuse a
persistent disk cache. The web player supports continuous playback, seeking,
repeat track, and shuffle. This is a VOD server, not a live radio broadcaster.

## Requirements

- Ruby 3.4 or later.
- FFmpeg on `PATH` (`brew install ffmpeg` or `apt install ffmpeg`).
- Internet access for the web player's Pico CSS and hls.js CDN assets.
- A browser with Media Source Extensions (MSE) or Managed Media Source (MMS)
  and support for the stream's audio codec. The player uses hls.js, including
  on Safari; native HLS alone is not sufficient. AirPlay is disabled.

## Install and run

```sh
gem install miniradio_server
mkdir -p mp3_files
# Copy your .mp3 files into mp3_files, then:
miniradio_server
```

Open <http://localhost:9292/>. Both `mp3_files` and `hls_cache` are created at
startup in the current working directory. Only `.mp3` files directly inside the
source directory are listed. Spaces, Japanese text, and other non-ASCII
filenames are supported. Press Ctrl+C to stop the server.

To choose directories, a port, or an FFmpeg executable:

```sh
miniradio_server --mp3-dir /path/to/music --cache-dir /path/to/cache --port 9393
miniradio_server --ffmpeg /path/to/ffmpeg
miniradio_server --help
miniradio_server --version
```

### GitHub Packages

The gem is also available from
[GitHub Packages](https://github.com/users/koichiro/packages/rubygems/package/miniradio_server).
RubyGems.org is the simplest install source and requires no GitHub token.
For GitHub Packages, configure Bundler with a personal access token (classic)
with `read:packages` as described in the
[GitHub documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-rubygems-registry),
then add this to your project's Gemfile (the version is an example):

```ruby
source "https://rubygems.org"
source "https://rubygems.pkg.github.com/koichiro" do
  gem "miniradio_server", "0.1.0"
end
```

## Playback

Select a track or press **Play all** to start from the first track. The shared
player shows the selected track's title, artist, album, embedded artwork, and
elapsed/total time. Missing metadata falls back to the filename or a placeholder.
Embedded JPEG and PNG artwork up to 5 MiB is supported.

- **Play/Pause**, seeking, volume, and mute control the selected track. On devices
  that cannot adjust volume from the page, use the device's volume controls.
- **Previous** wraps from the first track to the last. **Next** stops at the end
  of the list when shuffle is off.
- **Repeat track** repeats the current track; manual previous/next still work.
- **Shuffle** chooses a different random track and continues until paused.
  Repeat track takes precedence when a track ends.
- After the playlist finishes, **Play** restarts the last selected track;
  **Play all** restarts from the first track.

The first play of a track may take a few seconds while FFmpeg creates its cache.
If playback fails, select the track again or press **Retry** to reload it. Press
**Play** if the browser blocked playback. Unsupported browsers display an error.

## Direct streams and cache

HLS-compatible players can open a track's playlist directly:

```text
http://localhost:9292/stream/{URL-encoded-filename-without-extension}/playlist.m3u8
```

For `my song.mp3`, use `/stream/my%20song/playlist.m3u8`.

FFmpeg copies the audio without re-encoding. Each track gets a cache subdirectory
containing its playlist and segments. The cache persists across restarts. When
a source MP3 changes, stop the server and remove that track's cache subdirectory
to regenerate it. Cache invalidation, size limits, and eviction are manual.

## Limitations

- Intended for trusted local use; there is no authentication or authorization.
  Restrict network access as needed and keep source/cache directories under
  your control.
- Conversion runs synchronously. Concurrent requests for the same conversion
  receive HTTP 503 with `retry-after: 5`; conversion locks are per process.
- Corrupt or unsupported audio may fail playback even if the track is listed.

## Contributing and license

Bug reports and pull requests are welcome on
[GitHub](https://github.com/koichiro/miniradio_server).
See [CHANGELOG.md](CHANGELOG.md) for release history.
Licensed under MIT; see [LICENSE.txt](LICENSE.txt).
