# Miniradio Server

A small Ruby/Rack server that streams existing MP3 files via HTTP Live Streaming
(HLS). FFmpeg converts each track on its first request; later requests reuse a
persistent disk cache. This is a VOD server, not a live radio broadcaster.

The web player uses one audio element and loads streams only when selected.
It supports continuous playback, play/pause, previous/next, repeat track, and
shuffle. All compatible browsers, including Safari, use hls.js for HLS playback.

## Requirements

- Ruby 3.4 or later. The repository uses Ruby **4.0.7** via `.ruby-version`;
  CI also checks the supported minimum Ruby 3.4 series.
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

The player loads hls.js 1.x from the CDN and requires Media Source Extensions
(MSE) or Managed Media Source (MMS) with support for the stream's audio codec.
According to [hls.js compatibility documentation](https://github.com/video-dev/hls.js#compatibility),
Safari targets include macOS Safari 10+ (macOS 10.11+), iPadOS Safari 13+,
and iOS Safari 17.1+ (MMS requires hls.js 1.5.0+). These are library targets;
actual MP3 playback must also be checked on the target device. Older iPhones
without MMS cannot use this player, even if they support native HLS.
The player checks `Hls.isSupported()` and displays an error if hls.js is
unsupported or fails to load; there is no native HLS fallback.
Remote playback (including AirPlay) is disabled to allow
[Safari MMS playback without a native alternative](https://webkit.org/blog/14735/webkit-features-in-safari-17-1/).

- The shared player above the track list shows the selected track's title,
  artist, album, embedded artwork, playback state, and elapsed/total time.
  Missing tags use the filename or an information-unavailable label; missing
  artwork uses a placeholder. Selecting a row updates this shared player.
- The seek bar changes playback position once the duration and seekable range
  are available. Volume and mute stay unchanged when selecting another track;
  devices that cannot change volume from the page show a device-control hint.
- **Play all** starts at the first track and can restart a finished playlist.
- Each row has a keyboard-accessible play button.
- **Previous** wraps from the first track to the last. **Next** stops at the end
  of the list when shuffle is off.
- **Repeat track** repeats the current track when it ends; it does not loop the
  entire playlist. Manual previous/next still select another track.
- **Shuffle** chooses a different random track when there is more than one
  track, and continues until paused. Repeat track takes precedence on track end.
- Playback controls are grouped in the shared player; rows only select tracks.
  When the playlist finishes, the last selected track stays visible. **Play**
  restarts that track, while **Play all** restarts from the first track.

The first play of a track may take a few seconds while FFmpeg creates its cache.
An overlapping request for the same conversion receives HTTP 503 with
`retry-after: 5`. If playback fails, the page displays a message; select the track
again or press **Retry** to reload it, or press **Play** if the browser blocked
playback. Track information stays visible when playback is paused or fails.

### Artwork

Only the selected track's artwork is requested, via
`/artwork/{URL-encoded-filename-without-extension}`. The server returns the
first eligible embedded JPEG or PNG (up to 5 MiB), with a MIME type determined
from the binary signature. It does not fetch external covers, search neighboring
image files, convert images, or create an artwork disk cache. Missing,
unsupported, oversized, or unreadable artwork returns 404 and shows a placeholder
without interrupting playback. The size limit bounds the served image, not the
MP3 parser's memory usage. Unreadable track metadata falls back to the filename
so one bad tag does not prevent the library from displaying.

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
bundle exec rake lint         # Standard Ruby style checks
bundle exec standardrb --fix  # Apply Standard's automatic formatting
bundle exec rake test         # Ruby tests and the 90% coverage gate
bundle exec rake test_player  # Player logic tests using Node.js
bundle exec rake check        # Lint and both test suites (also the default rake task)
bundle exec rake audit        # Update the advisory database and audit locked gems
bundle exec rake build        # Build pkg/miniradio_server-0.0.4.gem
```

The Ruby suite runs real HLS conversion tests when FFmpeg is installed, and
skips those tests otherwise. CI installs FFmpeg so conversion tests always run.
Standard checks Ruby source, tests, executables, and project configuration using
Ruby 3.4 syntax as the supported minimum; no style violations are grandfathered.
SimpleCov measures Ruby **line coverage** and fails the test command if the
overall coverage or any measured source file falls below **90%**. All runtime
Ruby files under `lib/` are tracked, including files not loaded by tests; only
the declarative `version.rb` metadata loaded by Bundler before instrumentation
is excluded. Reports contain the current run only, without merging earlier runs.
Open `coverage/index.html` for the HTML report or read `coverage/coverage.json`
for machine-readable results. GitHub Actions runs the same lint/coverage checks
on Ruby 3.4 and 4.0.7 and uploads each coverage report as an artifact, including
when tests or the coverage threshold fail.
Player tests cover control behavior, hls.js readiness, native-capable browsers,
unavailable hls.js, and URL-encoded Japanese filenames using simulated DOM/media
APIs. Before releasing, also check actual playback in Safari and Chrome: initial play, rapid track changes, next-track autoplay, pause/resume,
repeat, shuffle, seeking, and empty libraries. Include Japanese filenames and
check macOS Safari and iOS/iPadOS Safari on actual devices; simulated player
tests do not verify decoding or browser autoplay policies.

For a local installed-gem check, run `gem install pkg/miniradio_server-0.0.4.gem`
and invoke `miniradio_server --version` from outside the checkout. To release,
review the version in `lib/miniradio_server/version.rb`, complete the browser
checks, and use `bundle exec rake release`. Release pushes commits/tags and
publishes to RubyGems; it is a separate action from building or opening a PR.

## Dependency security

Dependabot checks Bundler dependencies and GitHub Actions every Monday at 09:00
Asia/Tokyo and opens update PRs. The existing quality checks and the dependency
security workflow run on those PRs too. Updates are reviewed and merged manually.

The `Dependency security` workflow runs `bundle exec rake audit` on every PR,
push to `main`, manual dispatch, and daily at approximately 06:17 Asia/Tokyo.
Each run refreshes [Ruby Advisory Database](https://github.com/rubysec/ruby-advisory-db)
and checks the entire `Gemfile.lock`, including runtime, development, and
transitive gems. Known vulnerabilities, insecure gem sources, or a failed
database refresh cause the job to fail; advisories are not ignored. Local audits
also require network access to refresh the database. Results appear in the
Actions job logs. Scheduled audits catch new advisories even without code changes.

Dependabot **alerts** and **security updates** are separate GitHub repository
settings; `dependabot.yml` enables version update PRs but cannot enable those
settings. Under **Settings → Advanced Security** (or **Code security and
analysis**), enable the dependency graph, Dependabot alerts, and Dependabot
security updates to receive advisory alerts and automatic security fix PRs.
See [GitHub's Dependabot documentation](https://docs.github.com/en/code-security/dependabot).
The Actions audit works independently of those settings. It audits locked Ruby
gems; browser CDN assets and FFmpeg are not part of `Gemfile.lock`.

## Limitations and next work

- VOD only; no live input, authentication, or authorization.
- The server is intended for trusted local use. WEBrick binds to its default
  interface; restrict access with your network configuration when needed.
- Conversion is synchronous per request. Locks are per process, not shared
  between multiple server processes.
- Directory traversal and symlink escapes are rejected, and track metadata is
  rendered as text. Source/cache directories should remain under your control.
- No automatic cache invalidation, size limit, or eviction policy.
- Corrupt or unsupported audio may still fail playback even when its filename
  is listed using the metadata fallback.
- Remaining work includes browser playback checks, cache lifecycle management,
  and improved recovery from conversion/player errors.

## Contributing and license

Bug reports and pull requests are welcome on
[GitHub](https://github.com/koichiro/miniradio_server).
Licensed under MIT; see [LICENSE.txt](LICENSE.txt).
