# Changelog

## Unreleased

- Validate HLS playlists, referenced segments, and completion records before
  serving; publish completed caches from private work directories with a rename.
- Regenerate damaged and legacy caches without deleting legacy output, and
  protect active FFmpeg work with inherited file locks during startup cleanup.

## 0.1.0 — 2026-10-04

- Package the `miniradio_server` command, Slim templates, and player assets for
  installation with RubyGems. Support Ruby 3.4 and later.
- Configure source/cache directories, port, and FFmpeg through CLI options;
  requiring the library does not start the server.
- Stream MP3 files through FFmpeg with persistent HLS caching, safe paths, and
  support for spaces and Japanese filenames.
- Provide a shared hls.js player with track metadata, embedded artwork, seeking,
  volume, previous/next, repeat, and shuffle controls.
- Verify Ruby style, coverage, player behavior, dependency security, and the
  installed gem in CI.
