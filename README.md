# Miniradio Server is Simple Ruby HLS Server for MP3s
This is a basic HTTP Live Streaming (HLS) server written in Ruby using the Rack interface. It serves MP3 audio files by converting them on-the-fly into HLS format (M3U8 playlist and MP3 segment files) using `ffmpeg`. Converted files are cached for subsequent requests.
This server is designed for simplicity and primarily targets Video on Demand (VOD) scenarios where you want to stream existing MP3 files via HLS without pre-converting them.

## Prerequisites
Before running the server, ensure you have the following installed:
1.  **Ruby:** Version 3.1 or later (tested on 3.4).
2.  **Dependency Gems:** Install using `bundle`.
3.  **FFmpeg:** A recent version of `ffmpeg` must be installed and accessible in your system's PATH. You can download it from [ffmpeg.org](https://ffmpeg.org/) or install it via your system's package manager (e.g., `apt install ffmpeg`, `brew install ffmpeg`).
## Setup
1.  **Install Gems:**
    ```bash
    gem install miniradio_server
    ```
2.  **Create MP3 Directory:** Create a directory named `mp3_files` in the same location as the script.
    ```bash
    mkdir mp3_files
    ```
    *(Alternatively, change the `MP3_SRC_DIR` constant in the script).*
3.  **Add MP3 Files:** Place the MP3 files you want to stream into the `mp3_files` directory.
    *   **Important:** Use simple, URL-safe filenames for your MP3s (e.g., letters, numbers, underscores, hyphens). Spaces or special characters might cause issues. Example: `my_cool_song.mp3`, `podcast_episode_1.mp3`.
4.  **Cache Directory:** The script will automatically create a `hls_cache` directory (or the directory specified by `HLS_CACHE_DIR`) when the first conversion occurs. Ensure the script has write permissions in its parent directory.

## Running the Server
Navigate to the directory containing the script in your terminal and run:

```bash
bin/miniradio_server
Info: ffmpeg found.
Starting HLS conversion and streaming server on port 9292...
MP3 Source Directory: /path/to/your/project/mp3_files
HLS Cache Directory: /path/to/your/project/hls_cache
Default External Encoding: UTF-8
Using Handler: Rackup::Handler::WEBrick
Example Streaming URL: http://localhost:9292/stream/{mp3_filename_without_extension}/playlist.m3u8
e.g., If mp3_files/ contains my_music.mp3 -> http://localhost:9292/stream/my_music/playlist.m3u8
Press Ctrl+C to stop.
```

The server will run in the foreground. Press Ctrl+C to stop it.

## Usage: Accessing the Index Page

You can access the index page listing available MP3 files by navigating to `http://localhost:{SERVER_PORT}/` in your web browser.

## Usage: Accessing Streams

Once the server is running, you can access the HLS streams using an HLS-compatible player (like VLC, QuickTime Player on macOS/iOS, Safari, or web players using hls.js).

The URL format is:

http\://localhost:{SERVER\_PORT}/stream/{mp3\_filename\_without\_extension}/playlist.m3u8

**Example:**

If you have an MP3 file named mp3\_files/awesome\_track.mp3 and the server is running on the default port 9292, the streaming URL would be:

http\://localhost:9292/stream/awesome\_track/playlist.m3u8

**Note:** The first time you request a specific stream, the server will run ffmpeg to convert the MP3. This might take a few seconds depending on the file size. Subsequent requests for the same stream will be served instantly from the cache.

## Configuration

You can modify the following constants at the top of the script (miniradio\_server.rb):

- MP3\_SRC\_DIR: Path to the directory containing your original MP3 files.
- HLS\_CACHE\_DIR: Path to the directory where HLS segments and playlists will be cached.
- SERVER\_PORT: The network port the server listens on.
- FFMPEG\_COMMAND: The command used to execute ffmpeg (change if it's not in your PATH).
- HLS\_SEGMENT\_DURATION: The target duration (in seconds) for each HLS segment.

## How it Works

1. A client requests an M3U8 playlist URL (e.g., /stream/my\_song/playlist.m3u8).
2. The server checks if the corresponding HLS files (hls\_cache/my\_song/playlist.m3u8 and segments) exist in the cache directory.
3. If the cache does not exist:
   - It verifies the original mp3\_files/my\_song.mp3 exists.
   - It acquires a lock specific to my\_song to prevent simultaneous conversions.
   - It runs ffmpeg to convert my\_song.mp3 into hls\_cache/my\_song/playlist.m3u8 and hls\_cache/my\_song/segmentXXX.mp3.
   - The lock is released.
4. If the cache does exist (or after successful conversion), the server serves the requested playlist.m3u8 file.
5. The client parses the M3U8 playlist and requests the individual MP3 segment files listed within it (e.g., /stream/my\_song/segment000.mp3, /stream/my\_song/segment001.mp3, etc.).
6. The server serves these segment files directly from the cache directory.

## Limitations

- **VOD Only:** This server is designed for Video on Demand (pre-existing files) and does not support live streaming.
- **Basic Caching:** Cache is persistent but simple. There's no automatic cache invalidation if the source MP3 changes. You would need to manually clear the corresponding subdirectory in hls\_cache.
- **Security:** Basic checks against directory traversal are included, but it's not hardened for production use against malicious requests. No authentication/authorization is implemented.
- **Performance:** Relies on ffmpeg execution per file (first request only). Uses Ruby's WEBrick via rackup, which is single-threaded by default and not ideal for high-concurrency production loads.
- **Error Handling:** Basic error handling is implemented, but complex ffmpeg issues or edge cases might not be handled gracefully.
- **Resource Usage:** Conversion can be CPU-intensive (though -c:a copy helps significantly) and disk I/O intensive during the first request for a file.


## Development

Install from git repository:

```bash
git clone https://github.com/koichiro/miniradio_server.git
cd miniradio_server
bundle
bin/miniradio_server
```

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org/gems/miniradio_server).

## ToDo

* Continuous playback of multiple Music tracks
* :white_check_mark: ~~Use hls.js to support playback in Chrome.~~
* :white_check_mark: ~~Rendering of the Delivered Music list page~~
* :white_check_mark: ~~Multilingual support for file names.~~

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/koichiro/miniradio_server.

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT) - see the LICENSE file for details (or assume MIT if no LICENSE file is present).

