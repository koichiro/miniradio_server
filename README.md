# Miniradio Server

A small Ruby/Rack server that streams existing MP3 files via HTTP Live Streaming
(HLS). FFmpeg converts each track on its first request; later requests reuse a
persistent disk cache. This is a VOD server, not a live radio broadcaster.

The web player uses one audio element and loads streams only when selected.
It supports continuous playback, play/pause, previous/next, repeat track, and
shuffle. Safari uses native HLS; other compatible browsers use hls.js.

## Requirements

- Ruby 3.1 or later. CI covers Ruby 3.1, 3.4, and 4.0.
- FFmpeg on `PATH` (`brew install ffmpeg` or `apt install ffmpeg`).
- Internet access for the web player's Pico CSS and hls.js CDN assets.
- Node.js 18 or later for player development tests; not needed to run the server.

## Install and run

```sh
gem install miniradio_server
mkdir -p mp3_files
# Copy your .mp3 files into mp3_files, then:
miniradio_server
```

Open <http://localhost:9292/>. Both `mp3_files` and `hls_cache` are created at
startup in the current working directory. Spaces, Japanese text, and other
non-ASCII filenames are supported; generated stream links are URL-encoded.
Only `.mp3` files directly inside the source directory are listed.

The packaged command and options described here are available in the upcoming
0.0.4 release. The currently published 0.0.3 gem predates these changes; use the
source checkout below to run this development version.

```sh
miniradio_server --mp3-dir /path/to/music --cache-dir /path/to/cache --port 9393
miniradio_server --ffmpeg /path/to/ffmpeg
miniradio_server --help
miniradio_server --version
```

The server stays in the foreground; press Ctrl+C to stop it. Defaults are port
9292, `ffmpeg`, and a target HLS segment duration of 10 seconds. Custom Ruby
applications can instantiate `MiniradioServer::App` with their own directories,
FFmpeg command, segment duration, and logger. Requiring the library does not
start a server.

## Playback

- **Play all** starts at the first track and can restart a finished playlist.
- Each row has a keyboard-accessible play button.
- **Previous** wraps from the first track to the last. **Next** stops at the end
  of the list when shuffle is off.
- **Repeat track** repeats the current track when it ends; it does not loop the
  entire playlist. Manual previous/next still select another track.
- **Shuffle** chooses a different random track when there is more than one
  track, and continues until paused. Repeat track takes precedence on track end.
- The native audio controls provide seeking and volume where the browser supports them.

The first play of a track may take a few seconds while FFmpeg creates its cache.
An overlapping request for the same conversion receives HTTP 503 with
`retry-after: 5`. If playback fails, the page displays a message; select the track
again to retry loading, or press Play if the browser blocked playback.

## Direct streams and cache

```text
http://localhost:9292/stream/{URL-encoded-filename-without-extension}/playlist.m3u8
```

For `my song.mp3`, use `/stream/my%20song/playlist.m3u8`. HLS-compatible players
can request the playlist and the segment URLs it contains directly.

FFmpeg copies the audio codec without re-encoding. Each track gets a cache
subdirectory containing `playlist.m3u8` and `segmentNNN.mp3` files. Despite their
extension, the segments use FFmpeg's default HLS MPEG-TS container. The cache
persists across restarts. Failed conversions are cleaned up and can be retried.
When a source MP3 changes, manually remove its cache subdirectory while the
server is stopped; automatic invalidation is not implemented.

## Development

```sh
git clone https://github.com/koichiro/miniradio_server.git
cd miniradio_server
bin/setup
bin/miniradio_server
bundle exec exe/miniradio_server --help
```

```sh
bundle exec rake test         # Ruby, Rack, cache, CLI, and packaging tests
bundle exec rake test_player  # Player logic tests using Node.js
bundle exec rake check        # Both suites
bundle exec rake build        # Build pkg/miniradio_server-0.0.4.gem
```

The Ruby suite runs real HLS conversion tests when FFmpeg is installed, and
skips those tests otherwise. CI installs FFmpeg so conversion tests always run.
Player tests cover control behavior and native/HLS.js readiness using simulated
DOM/media APIs. Before releasing, also check actual playback in Safari and
Chrome: initial play, rapid track changes, next-track autoplay, pause/resume,
repeat, shuffle, seeking, and empty libraries.

For a local installed-gem check, run `gem install --local pkg/miniradio_server-0.0.4.gem`
and invoke `miniradio_server --version` from outside the checkout. To release,
review the version in `lib/miniradio_server/version.rb`, complete the browser
checks, and use `bundle exec rake release`. Release pushes commits/tags and
publishes to RubyGems; it is a separate action from building or opening a PR.

## Limitations and next work

- VOD only; no live input, authentication, or authorization.
- The server is intended for trusted local use. WEBrick binds to its default
  interface; restrict access with your network configuration when needed.
- Conversion is synchronous per request. Locks are per process, not shared
  between multiple server processes.
- Directory traversal and symlink escapes are rejected, and track metadata is
  rendered as text. Source/cache directories should remain under your control.
- No automatic cache invalidation, size limit, or eviction policy.
- Corrupt or unsupported MP3 metadata can prevent the index from rendering.
- Remaining work includes browser playback checks, cache lifecycle management,
  and improved recovery from conversion/player errors.

## Contributing and license

Bug reports and pull requests are welcome on
[GitHub](https://github.com/koichiro/miniradio_server).
Licensed under MIT; see [LICENSE.txt](LICENSE.txt).
