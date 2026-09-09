# discord-mpv-rpc

<p align="center">
  <a href="https://discord.com/"><img src="assets/discord-logo.svg" alt="Discord" height="40"></a>&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://www.themoviedb.org/"><img src="assets/tmdb-logo.svg" alt="TMDb" height="40"></a>
</p>

Show what you are watching in [mpv](https://mpv.io/) as Discord Rich Presence. Add a free [TMDb](https://www.themoviedb.org/) API key for official titles, posters, episode names, and episode stills.

<p align="center">
  <img src="assets/preview-1.png" alt="Discord Rich Presence showing Dragon Ball DAIMA" width="48%">
  <img src="assets/preview-2.png" alt="Discord Rich Presence showing The Boy And The Heron" width="48%">
</p>

## Highlights

- Displays **Watching `<title>`** with play, pause, buffering, and idle states
- Shows a speed-aware Discord progress bar
- Cleans common release tags from filenames before matching
- Supports common movie, TV, scene, and anime filename formats
- Displays episodes as `04 of 20: Chatty` when TMDb has the data
- Uses movie posters, show posters, and episode stills from TMDb
- Reconnects automatically when Discord restarts
- Caches metadata across mpv sessions
- Optionally uses a local TMDb title index to reduce online searches
- Updates only when playback state changes; there is no constant presence polling

## Requirements

- [mpv](https://mpv.io/)
- Discord desktop with **Settings > Activity Privacy > Display current activity as a status message** enabled
- [`curl`](https://curl.se/) on `PATH` for TMDb metadata and artwork
- A free [TMDb API key](https://www.themoviedb.org/settings/api) for TMDb features

LuaJIT is recommended and is required on Windows for background Discord disconnect detection and automatic local-index maintenance. Without a TMDb key, basic Rich Presence still works.

You do not need a Discord bot, OAuth flow, or install link.

## Installation

Copy this structure into mpv's configuration directory:

```text
scripts/
+-- discord-mpv-rpc/
    |-- main.lua
    |-- modules/
    |-- db/
    +-- tools/

script-opts/
+-- discord-mpv-rpc.conf
```

| OS | mpv configuration directory |
|---|---|
| Windows | `%APPDATA%\mpv` |
| Linux / macOS | `~/.config/mpv` |
| Portable Windows | `<mpv_dir>\portable_config` |

Keep the complete `modules/`, `db/`, and `tools/` folders beside `main.lua`.

## Quick setup

Open `script-opts/discord-mpv-rpc.conf` and add your TMDb key:

```ini
tmdb_api_key=your_tmdb_key_here
```

Then start Discord, open a video in mpv, and the activity should appear automatically. Press `D` to toggle Rich Presence.

The included Discord Application ID is used when `client_id` is empty. To use your own application, create one in the [Discord Developer Portal](https://discord.com/developers/applications), copy its Application ID, and set:

```ini
client_id=your_application_id
```

With a custom application, optionally upload square Rich Presence assets named `mpv`, `play`, and `pause`, or change the corresponding asset keys in the configuration.

## Configuration

| Option | Default | Purpose |
|---|---|---|
| `client_id` | built in | Custom Discord Application ID; leave empty to use the default |
| `tmdb_api_key` | empty | Enables TMDb titles, episode data, links, and artwork |
| `tmdb_language` | `en-US` | Language for TMDb searches and metadata |
| `tmdb_episode_lookup` | `yes` | Looks up the exact parsed season and episode |
| `tmdb_local_index` | `yes` | Enables the local TMDb index and automatic maintenance |
| `tmdb_index_mpv_path` | empty | Optional path to a LuaJIT-enabled mpv for the index worker |
| `tmdb_positive_cache_days` | `60` | Days before successful TMDb metadata is refreshed |
| `cache_path` | empty | Persistent metadata-cache path; empty stores it beside `main.lua` |
| `key_toggle` | `D` | Toggles Rich Presence for the current session |
| `key_toggle_db` | `Ctrl+d` | Toggles local-index lookup for the current session |
| `large_image` | `mpv` | Fallback large-image asset key |
| `large_text` | `mpv` | Fallback image hover text |
| `small_image_playing` | `play` | Playing badge asset key; empty hides it |
| `small_image_paused` | `pause` | Paused/buffering badge asset key; empty hides it |
| `small_image_idle` | `mpv` | Idle badge asset key; empty hides it |
| `poster_fit` | `contain` | `contain` letterboxes artwork through wsrv.nl; `raw` uses the TMDb URL directly |
| `enabled` | `yes` | Enables Rich Presence at startup |

Restart mpv after editing the configuration file. The old `update_interval` option has no effect because updates are event-driven.

## What Discord displays

The title is selected in this order:

1. Official TMDb title
2. File `metadata/title`
3. Cleaned filename
4. mpv `media-title`

For TV episodes, the state line uses the TMDb episode title and season total when available:

```text
Dragon Ball DAIMA
04 of 20: Chatty
```

If the total is unavailable, it shows `04: Chatty`. If no TMDb episode title is found, a meaningful chapter title or the current playback state is used. Missing episodes are never guessed or remapped to another season.

While playing, Discord receives timestamps calculated from the current position, duration, and playback speed. Timestamps are removed while paused or buffering and recalculated after resuming or seeking.

## Filename matching

Common formats are recognized automatically:

```text
Movie.Name.2026.1080p.BluRay.mkv
Show.Name.S02E05.mkv
Show.Name.2x05.mkv
Show Name Season 2 Episode 5.mkv
[Judas] Dragon Ball Daima - S01E04v2.mkv
[SubsPlease] Show - 04 [1080p].mkv
```

The parser removes bracketed metadata and common trailing source, resolution, codec, audio, bit-depth, and release-group tags. It can also use a parent folder such as `Show Name (2026)` for title and year context.

Parsing is heuristic. For a bad match, check the cleaned-title log entry and simplify unusual filenames or folder names.

## Optional local TMDb index

The bundled index is built from [TMDb daily ID exports](https://developer.themoviedb.org/docs/daily-id-exports). It helps resolve exact movie and TV titles locally before falling back to the normal online TMDb search. A TMDb API key is still required to retrieve metadata and artwork.

When `tmdb_local_index=yes`, a detached mpv worker performs quick index checks at startup and hourly. Full checksums are limited to once per day unless corruption is detected. It downloads and rebuilds only when the index is:

- missing
- corrupted
- at least seven days old

The updater is pure Lua and uses mpv, LuaJIT, and the existing `curl` executable; no Python, database engine, or unzip tool is required. Playback, cached results, and online TMDb searches continue while maintenance runs. Completed indexes are picked up automatically. Downloaded exports and inactive index generations are removed after successful validation.

Set `tmdb_local_index=no` to disable both lookup and automatic maintenance. `Ctrl+D` toggles them for the current session without rewriting the configuration; it does not stop a worker already running.

Automatic builds can use several hundred MB of memory and require the script directory to be writable. Failed builds leave the active index unchanged and retry no more than once per hour.

To run the same validation/update manually from the installed script directory:

```sh
mpv --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tools/update_tmdb_index.lua
```

Generated index files stay in `db/tmdb/`.

## Cache and network use

Metadata is cached in `discord-mpv-rpc-posters.json` beside `main.lua` in the script directory by default. Set `cache_path` to override it; mpv path prefixes such as `~~/` are supported. Successful metadata is refreshed periodically according to `tmdb_positive_cache_days`; missing results use shorter retry windows. Close mpv and delete the cache file when you intentionally want to retest matching from a clean cache.

TMDb requests are paced, coalesced, cached, cancelled when stale, and backed off after HTTP 429 responses. The local index does bounded disk lookups rather than loading the full database into memory during playback.

With `poster_fit=contain`, the TMDb image URL is sent to [wsrv.nl](https://wsrv.nl/) to fit portrait artwork into Discord's square image area. Use `poster_fit=raw` to avoid that third-party image proxy; Discord may crop the image.

## Troubleshooting

| Problem | Check |
|---|---|
| No Discord activity | Start Discord, enable Activity Privacy, and verify a custom `client_id` if used |
| No TMDb artwork or titles | Set `tmdb_api_key`, ensure `curl` is on `PATH`, and inspect mpv's logs |
| Wrong movie or show | Check the `cleaned title` and `TMDb selected` log entries; clear the cache when retesting |
| No episode title | TMDb may not contain that exact season/episode, or `tmdb_episode_lookup` may be disabled |
| No `of <total>` text | The season count is unavailable or smaller than the current episode number |
| Poster is cropped | Set `poster_fit=contain` |
| Do not want wsrv.nl | Set `poster_fit=raw` |
| Discord restarted after mpv | Reconnection is automatic; background detection on Windows requires LuaJIT |
| Local index does not build | Use LuaJIT-enabled mpv, verify `curl`, and make the script directory writable |

Run mpv from a terminal or enable verbose logging for more detail.

## Tests

Run the pure-Lua checks from the installed script directory:

```sh
lua tests/run.lua
```

## Credits

Movie and TV metadata and artwork are provided by TMDb. The pure-Lua index updater includes [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) under its original zlib license. Discord is a trademark of Discord Inc. This project is not affiliated with or endorsed by Discord or TMDb.

## License

[MIT](https://opensource.org/licenses/MIT)
