# discord-mpv-rpc
mpv Discord Rich Presence + TMDb posters.

Discord Rich Presence for [mpv](https://mpv.io/) with optional movie/TV posters from [TMDb](https://www.themoviedb.org/).

Displays the current file title, play/pause state, and a progress bar. Friends see **Watching &lt;media title&gt;** (for example Watching Sousou no Frieren), not the Developer Portal application name. When a TMDb API key is set, looks up a poster from the filename and uses it as the large image (falls back to a static Discord asset otherwise).

Search results and poster URLs are **cached on disk** so the same title is not looked up again across sessions.

## Features

- Status line **Watching &lt;media title&gt;** (`status_display_type` = details, not the app name)
- Current media title, play/pause, elapsed and remaining time
- Discord progress bar while playing (timestamps removed while paused so the bar freezes)
- Optional **TMDb** poster lookup via async `curl` (does not block playback)
- **Disk cache** of search results and poster URLs, written after each lookup
- Filename parsing for common movie and TV/anime release names
- Toggle on/off with a key binding (default **D**)
- Supports both standard config (`%APPDATA%\mpv` / `~/.config/mpv`) and **portable_config**
- No Lua library dependencies (uses system `curl` only for posters)

## Requirements

- [mpv](https://mpv.io/) (LuaJIT recommended)
- Discord desktop app running
- [`curl`](https://curl.se/) on your `PATH` (only needed for TMDb posters)
- **Your own** Discord application ID (do not reuse someone else’s)
- (Optional) A free [TMDb API key](https://www.themoviedb.org/settings/api)

## Installation

Install the script in a **subdirectory** of `scripts/` so the poster cache can live next to it.

### Standard config (`%APPDATA%` / XDG)

1. Copy `main.lua` here:

   | OS | Path |
   |----|------|
   | Windows | `%APPDATA%\mpv\scripts\discord-mpv-rpc\main.lua` |
   | Linux / macOS | `~/.config/mpv/scripts/discord-mpv-rpc/main.lua` |

2. Copy `discord-mpv-rpc.conf` into your **script-opts** folder and edit it:

   | OS | Path |
   |----|------|
   | Windows | `%APPDATA%\mpv\script-opts\discord-mpv-rpc.conf` |
   | Linux / macOS | `~/.config/mpv/script-opts/discord-mpv-rpc.conf` |

### Portable config

If you use mpv portable mode (`portable_config` next to `mpv.exe`):

1. Copy `main.lua` to:

   `<mpv_dir>\portable_config\scripts\discord-mpv-rpc\main.lua`

2. Copy `discord-mpv-rpc.conf` to:

   `<mpv_dir>\portable_config\script-opts\discord-mpv-rpc.conf`

mpv auto-loads `scripts/discord-mpv-rpc/main.lua`.

3. Create **your own** application at the [Discord Developer Portal](https://discord.com/developers/applications) (**New Application**). The app name is only a fallback on older Discord clients. Current clients show **Watching &lt;media title&gt;**.

   Do **not** use an Application ID from this repo, a friend, or a screenshot. Each user should have their own app. You do not need a bot, install link, or OAuth for Rich Presence.

4. Open the app → **General Information** → copy **Application ID** into `client_id=` in `discord-mpv-rpc.conf`.

5. (Optional) **Rich Presence → Art Assets**: upload square images named `mpv`, `play`, and `pause` (or match `large_image` / `small_image_*`). Assets belong to *your* app; they are not shared across IDs.

6. (Optional) Get a TMDb API key and set `tmdb_api_key=` for poster images.

7. In Discord: **Settings → Activity Privacy → Display current activity as a status message** — enabled.

## Configuration

All options live in `script-opts/discord-mpv-rpc.conf`:

| Option | Default | Description |
|--------|---------|-------------|
| `client_id` | *(required)* | Discord application ID |
| `tmdb_api_key` | empty | TMDb API key; leave empty to disable posters |
| `tmdb_language` | `en-US` | TMDb language for search/results |
| `update_interval` | `15` | Seconds between background refreshes while playing. Pause, seek, and new-file updates are immediate. |
| `key_toggle` | `D` | Key binding to enable/disable RPC |
| `large_image` | `mpv` | Fallback Discord asset key |
| `large_text` | `mpv` | Hover text for fallback image |
| `small_image_playing` | `play` | Corner badge while playing (upload this asset key) |
| `small_image_paused` | `pause` | Corner badge while paused |
| `small_image_idle` | `mpv` | Corner badge while idle |
| `poster_fit` | `contain` | `contain` letterboxes the poster in a square (no crop). `raw` lets Discord crop it. |
| `enabled` | `yes` | Start with Rich Presence on |

Example:

```ini
client_id=123456789012345678
tmdb_api_key=your_tmdb_key_here
tmdb_language=en-US
update_interval=15
key_toggle=D
large_image=mpv
large_text=mpv
small_image_playing=play
small_image_paused=pause
small_image_idle=mpv
poster_fit=contain
enabled=yes
```

## Cache

Search results and poster URLs are cached next to the script as `discord-mpv-rpc-posters.json`:

| Mode | Script | Cache |
|------|--------|-------|
| Standard (Windows) | `%APPDATA%\mpv\scripts\discord-mpv-rpc\main.lua` | `%APPDATA%\mpv\scripts\discord-mpv-rpc\discord-mpv-rpc-posters.json` |
| Standard (Linux/macOS) | `~/.config/mpv/scripts/discord-mpv-rpc/main.lua` | `~/.config/mpv/scripts/discord-mpv-rpc/discord-mpv-rpc-posters.json` |
| Portable | `<mpv_dir>\portable_config\scripts\discord-mpv-rpc\main.lua` | `<mpv_dir>\portable_config\scripts\discord-mpv-rpc\discord-mpv-rpc-posters.json` |

- Cache key: `movie:title|year` or `tv:title|year`
- Successful poster URLs and confirmed misses are stored
- Transient network errors are **not** cached (will retry next time)
- Cache is written to disk **after each TMDb result**, and again on shutdown

Delete the cache file to force fresh TMDb lookups.

## How updates work

- Presence text (elapsed / remaining) refreshes on a timer **only while playing** (default every 15s, to stay under Discord’s informal presence cap).
- Pause, unpause, seek, new file, and poster arrival always send immediately (`tick(true)`).
- While paused, the timer is stopped and Discord timestamps are omitted so the progress bar does not keep moving.
- `time-pos` is observed **only while paused**, so seeking in pause still updates the text without polling during playback.
- `playback-restart` (seek / resume while playing) updates immediately, debounced to 0.4s so scrubbing does not spam Discord.
- TMDb HTTP 429 triggers an exponential backoff (30s–5min) and is not stored as a cache miss.
- If a wsrv.nl letterbox URL fails, that poster falls back to the raw TMDb image.
- `idle-active` stops the timer when nothing is playing.
- TMDb searches run in a Lua coroutine with `mp.command_native_async`. Playback continues while `curl` runs. A generation counter drops stale results if you open another file before the request finishes. Cache hits skip the network entirely.

## Supported filename patterns

| Example | Parsed as |
|---------|-----------|
| `Happy.Gilmore.2.2025.1080p.WEBRip....mkv` | Movie **Happy Gilmore 2** (2025) |
| `The.Boy.and.the.Heron.2023.1080p.AMZN....mkv` | Movie **The Boy And The Heron** (2023) |
| `Shin Godzilla (2016).1080p.H264....mkv` | Movie **Shin Godzilla** (2016) |
| `[Judas] Dragon Ball Daima - S01E01v2.mkv` | TV **Dragon Ball Daima** |
| `[SubsPlease] Sousou no Frieren S2 - 01 (1080p) [HASH].mkv` | TV **Sousou No Frieren** |

## Usage

- Start mpv with Discord open. Presence should appear after a short delay.
- Press **D** (or your `key_toggle`) to turn Rich Presence on or off.
- Run mpv from a terminal to see log lines such as:
  - `discord-mpv-rpc: connected to Discord`
  - `discord-mpv-rpc: cleaned title="..." year=... tv=...`
  - `discord-mpv-rpc: poster -> https://image.tmdb.org/...`
  - `discord-mpv-rpc: poster cache hit -> ...`

## Troubleshooting

| Problem | What to check |
|---------|----------------|
| No status at all | Discord desktop running; `client_id` correct; Activity Privacy enabled |
| Handshake errors | Valid Application ID; try restarting Discord |
| No posters | `tmdb_api_key` set; `curl` works in a terminal; filename parse in the log |
| Wrong poster | TMDb match is best-effort from the filename; try a cleaner file name |
| Freeze on exit | Shutdown only closes the IPC pipe (no blocking clear) |

Test curl + TMDb manually:

```bash
curl -s "https://api.themoviedb.org/3/search/movie?api_key=YOUR_KEY&query=Happy%20Gilmore%202&year=2025"
```

## License

MIT license.
