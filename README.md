# discord-mpv-rpc

<p align="center">
  <a href="https://discord.com/"><img src="assets/discord-logo.svg" alt="Discord" height="40"></a>&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://www.themoviedb.org/"><img src="assets/tmdb-logo.svg" alt="TMDb" height="40"></a>
</p>

Discord Rich Presence for [mpv](https://mpv.io/) with optional movie/TV artwork and episode metadata from [TMDb](https://www.themoviedb.org/).

The script publishes the current media title to Discord as **Watching `<title>`**, shows play/pause/idle state with optional small assets, and uses Discord timestamps for the playback progress bar. When a TMDb API key is configured, it can resolve movie/TV titles from release filenames, use TMDb artwork as the large image, and display TV episode names/stills when TMDb has the requested episode.

Presence updates are event-driven. There is no periodic elapsed/remaining-time text refresh; Discord animates the progress bar from the timestamps it already has.

## Features

- **Watching `<title>`** Rich Presence instead of the Discord Developer Portal application name
- Title preference:
  1. official TMDb title
  2. file `metadata/title`
  3. cleaned filename
  4. mpv `media-title`
- Event-driven Discord updates on file load, pause/resume, seek/playback restart, chapter changes, idle state, and TMDb result arrival
- Discord progress bar while playing, with timestamps removed while paused so progress does not continue advancing
- TMDb episode title or meaningful chapter title on the state line when available
- Optional play / pause / idle small-image assets
- Optional TMDb movie/TV artwork via asynchronous `curl`
- TV episode stills when the filename contains a recognized season/episode
- Clickable TMDb links on the title/state/large image
- Staged TV search with year-aware matching, directory context, original titles, and alternate-title fallback
- Exact TMDb episode lookup only — the script does **not** remap a missing season/episode to another TMDb season
- Filename parsing for common movie, TV, scene, and anime naming patterns
- Parent-directory year/title context for folders such as `Show Name (2026)`
- Persistent show/episode cache across mpv sessions
- Bounded in-memory request/alias/parser caches
- TMDb request pacing, request coalescing, stale-request cancellation, and 429 backoff
- Optional square/letterboxed poster rendering through [wsrv.nl](https://wsrv.nl/), with automatic fallback to the raw TMDb image
- Automatic Discord IPC reconnect with exponential backoff
- Toggle Rich Presence on/off with a key binding (default: `D`)
- Supports standard mpv config directories and `portable_config`

## Requirements

- [mpv](https://mpv.io/)
- Discord desktop app running
- Your own Discord application ID
- [`curl`](https://curl.se/) on `PATH` if using TMDb artwork/metadata
- Optional: a free [TMDb API key](https://www.themoviedb.org/settings/api)

LuaJIT is recommended. On Unix-like systems without LuaJIT, the fallback Discord IPC transport requires LuaSocket with `socket.unix`.

You do **not** need a Discord bot, OAuth flow, or install link.

## Installation

Install the script in its own subdirectory under mpv's `scripts/` directory. The persistent cache is stored next to the script.

### Standard config

Copy `main.lua` to:

| OS | Script path |
|---|---|
| Windows | `%APPDATA%\mpv\scripts\discord-mpv-rpc\main.lua` |
| Linux / macOS | `~/.config/mpv/scripts/discord-mpv-rpc/main.lua` |

Copy `discord-mpv-rpc.conf` to:

| OS | Config path |
|---|---|
| Windows | `%APPDATA%\mpv\script-opts\discord-mpv-rpc.conf` |
| Linux / macOS | `~/.config/mpv/script-opts/discord-mpv-rpc.conf` |

### Portable config

If `portable_config` is next to `mpv.exe`:

```text
<mpv_dir>\
└── portable_config\
    ├── scripts\
    │   └── discord-mpv-rpc\
    │       └── main.lua
    └── script-opts\
        └── discord-mpv-rpc.conf
```

mpv will auto-load `scripts/discord-mpv-rpc/main.lua`.

## Discord application setup

1. Open the [Discord Developer Portal](https://discord.com/developers/applications).
2. Create a **New Application**.
3. Open **General Information** and copy the **Application ID**.
4. Put that value in `client_id=` in `discord-mpv-rpc.conf`.
5. In Discord, enable **Settings → Activity Privacy → Display current activity as a status message**.

Do not reuse an Application ID from this repository, another person, or a screenshot. Each user should create their own application.

### Optional Discord art assets

Under your Discord application's **Rich Presence → Art Assets**, you can upload square images matching the configured fallback/small-image keys:

- `mpv`
- `play`
- `pause`

These names are configurable. TMDb artwork is loaded remotely and does not need to be uploaded to the Developer Portal.

## TMDb setup

1. Create/get a TMDb API key from [TMDb API settings](https://www.themoviedb.org/settings/api).
2. Set it in:

```ini
tmdb_api_key=your_tmdb_key_here
```

Leave `tmdb_api_key=` empty if you only want Discord Rich Presence without TMDb lookup.

## Configuration

All options live in `script-opts/discord-mpv-rpc.conf`.

| Option | Default | Description |
|---|---|---|
| `client_id` | *(required)* | Your Discord application ID |
| `tmdb_api_key` | empty | TMDb API key. Leave empty to disable TMDb lookups |
| `tmdb_language` | `en-US` | TMDb language used for searches and metadata |
| `tmdb_episode_lookup` | `yes` | Look up exact TMDb TV episodes when season/episode information is parsed |
| `key_toggle` | `D` | Key binding used to enable/disable Rich Presence |
| `large_image` | `mpv` | Fallback Discord large-image asset key |
| `large_text` | `mpv` | Hover text for the fallback large image |
| `small_image_playing` | `play` | Small-image asset while playing |
| `small_image_paused` | `pause` | Small-image asset while paused |
| `small_image_idle` | `mpv` | Small-image asset while idle |
| `poster_fit` | `contain` | `contain` letterboxes TMDb artwork to a square through wsrv.nl; `raw` sends the original TMDb image URL directly |
| `enabled` | `yes` | Start with Rich Presence enabled |

Example:

```ini
client_id=123456789012345678
tmdb_api_key=your_tmdb_key_here
tmdb_language=en-US
tmdb_episode_lookup=yes

key_toggle=D
large_image=mpv
large_text=mpv
small_image_playing=play
small_image_paused=pause
small_image_idle=mpv

poster_fit=contain
enabled=yes
```


## Rich Presence behavior

### Title and state

The Discord title is chosen in this order:

```text
TMDb official title
    ↓
file metadata/title
    ↓
cleaned filename
    ↓
mpv media-title
```

The state line uses:

```text
TMDb episode name
    ↓
meaningful chapter title
    ↓
Playing / Paused / Idle
```

Generic chapter labels and timestamp-only chapter names are filtered out.

### Progress bar

While playing, the script sends Discord `start` and `end` timestamps calculated from mpv's current position and duration. Discord animates the progress bar locally after that.

There is **no periodic elapsed/remaining-time text update**.

When paused, timestamps are removed so the progress bar does not continue advancing. On resume or seek, the timestamps are recalculated once and sent again.

### Event-driven updates

Presence is refreshed only when something meaningful changes, including:

- file loaded
- TMDb/poster/episode result arrived
- pause or resume
- seek / playback restart
- chapter change when no TMDb episode title is active
- idle state change
- Discord reconnect
- manual enable/disable

Seek/restart events are debounced to avoid unnecessary Discord IPC updates while scrubbing.

## Filename parsing

The parser recognizes several common TV/anime patterns, including forms such as:

```text
Show.Name.S02E05.mkv
Show Name S02 E05.mkv
Show Name S2 - 03.mkv
Show.Name.2x05.mkv
Show Name Season 2 Episode 5.mkv
Show Name Season 2 Ep 5.mkv
Show Name - 05 - Episode Title.mkv
Show Name - 05 (1080p).mkv
Show Name - 05v2.mkv
```

Movie filenames can use common year forms such as:

```text
Movie Name (2026).mkv
Movie.Name.2026.1080p.BluRay.mkv
```

Release-group brackets, dots/underscores, year markers, episode markers, and other common filename noise are cleaned before matching.

When useful, the script can also inherit title/year context from a parent directory containing a year, for example:

```text
Show Name (2026)/
└── Show Name - S01E02.mkv
```

## TMDb matching

TMDb matching is designed to avoid unnecessary requests while still handling localized, romanized, rebooted, and alternate-title releases.

### TV shows

TV resolution is staged:

1. Search `/search/tv` using the filename-derived title and known year when available.
2. If needed, broaden the TV search without the year filter.
3. If directory title context differs from the filename title, search that too.
4. Use `/search/multi` as an additional candidate source when the earlier stages remain weak/ambiguous.
5. Only difficult matches fan out into alternate-title requests.
6. Alternate-title checks are tiered:
   - exact-year candidates first
   - strongest broader candidates next
   - full deduplicated candidate pool only as a final fallback

Candidates are scored using title similarity, original/official titles, alternate titles when needed, media type, year, and poster availability.

This allows a release name to match a TMDb series even when TMDb's primary English title is different.

### Movies

Movies use TMDb multi-search and the same confidence-based title/year/media-type scoring.

### TV episodes

If a filename resolves to a TV show and contains a season/episode, the script requests exactly:

```text
/tv/<show-id>/season/<season>/episode/<episode>
```

The returned `season_number` and `episode_number` must match the requested values.

If TMDb does not currently have that exact season/episode, the script stops there. It does **not** guess, shift, or map the episode to another season.

Set:

```ini
tmdb_episode_lookup=no
```

to disable episode lookup entirely.

## Posters and `poster_fit`

### `poster_fit=contain`

Discord displays large artwork in a square area, which can crop portrait posters. With `poster_fit=contain`, the script sends the TMDb artwork through wsrv.nl to create a 512×512 contained image with letterboxing.

The script probes wsrv availability with a lightweight GET whose image body is discarded:

- success is remembered for 24 hours
- failure is remembered for 10 minutes
- recent global wsrv health is persisted across mpv sessions
- if wsrv is unavailable, the raw TMDb image URL is used instead

### `poster_fit=raw`

The raw TMDb image URL is sent directly to Discord. wsrv.nl is not used.

> **Privacy/network note:** `poster_fit=contain` sends the TMDb image URL to wsrv.nl so it can proxy/resize the image. Use `poster_fit=raw` if you do not want to use that third-party image proxy.

## Cache

The persistent cache is stored next to `main.lua` as:

```text
discord-mpv-rpc-posters.json
```

| Mode | Cache path |
|---|---|
| Standard Windows | `%APPDATA%\mpv\scripts\discord-mpv-rpc\discord-mpv-rpc-posters.json` |
| Standard Linux/macOS | `~/.config/mpv/scripts/discord-mpv-rpc/discord-mpv-rpc-posters.json` |
| Portable | `<mpv_dir>\portable_config\scripts\discord-mpv-rpc\discord-mpv-rpc-posters.json` |

### Persistent entries

Show cache keys distinguish media type:

```text
show:tv|<normalized title>|<year>|<language>
show:movie|<normalized title>|<year>|<language>
```

Episode entries use the resolved TMDb show ID:

```text
episode:<tmdb show id>:SxxExx:<language>
```

The persistent cache stores compact data used by Discord, such as:

- TMDb ID/media type
- official title
- poster/still URL
- TMDb page URL
- episode name when available

Other behavior:

- show misses expire after 7 days
- exact episode 404s expire after 24 hours
- expired entries are pruned on cache load/save
- cache size is bounded to 1000 entries
- writes are deferred briefly to reduce disk churn
- cache replacement uses a temporary file before replacing the main JSON file
- transient network failures are not persisted as permanent misses

Delete `discord-mpv-rpc-posters.json` to force a completely fresh persistent lookup.

### In-memory caches

discord-mpv-rpc also keeps bounded process-local caches for reusable data:

- TMDb search responses: up to 512 entries, 24-hour TTL
- TMDb alternate titles: up to 256 entries, 30-day TTL
- parsed filenames: up to 256 entries
- wsrv per-URL status: up to 256 entries

Episode responses and alternate-title raw JSON are not unnecessarily duplicated in the generic TMDb response cache.

## Network/request behavior

TMDb requests are designed to stay conservative during normal playback:

- new TMDb HTTP requests are paced at least 250 ms apart
- identical simultaneous TMDb requests are coalesced
- reusable search responses are cached in memory
- persistent show results prevent rediscovering the same show for every episode
- switching files invalidates stale lookup work
- active stale TMDb `curl` subprocesses are aborted when possible
- HTTP 429 triggers exponential backoff from 30 seconds up to 5 minutes
- request failures are not stored as normal "no result" matches

A cached show followed by another uncached episode of the same series will normally need only the exact episode request.

Discord Rich Presence traffic uses local IPC and is separate from TMDb/wsrv HTTP traffic.

## Discord IPC and reconnects

The script communicates directly with the Discord desktop client's IPC socket/named pipe.

It includes:

- IPC frame length/opcode validation
- partial send/receive handling
- UTF-8 → UTF-16 handling on Windows
- reconnect backoff from 1 to 30 seconds
- a reconnect-only watchdog while Discord is unavailable
- automatic republishing of the current activity after Discord reconnects

The normal presence engine does not use a periodic update timer.

## Usage

1. Start Discord.
2. Start mpv and play a file.
3. Rich Presence should appear after connection/metadata resolution.
4. Press `D` (or your configured `key_toggle`) to turn Rich Presence on/off.

Useful log messages include:

```text
discord-mpv-rpc: connected to Discord
discord-mpv-rpc: cleaned title="..." year=... tv=... S...E...
discord-mpv-rpc: TMDb selected id=... type=tv title="..." year=... score=...
discord-mpv-rpc: poster -> https://image.tmdb.org/...
discord-mpv-rpc: episode -> ...
discord-mpv-rpc: poster cache hit -> ...
```

Run mpv from a terminal or enable verbose logging when troubleshooting title matching.

## Troubleshooting

| Problem | What to check |
|---|---|
| No Discord status | Discord desktop is running; `client_id` is correct; Activity Privacy is enabled |
| `handshake not READY` | Verify the Discord Application ID; restart Discord if necessary |
| Discord was started/restarted after mpv | discord-mpv-rpc should reconnect automatically using the reconnect watchdog/backoff |
| No TMDb artwork | `tmdb_api_key` is set; `curl` is available on `PATH`; inspect the cleaned-title/TMDb log lines |
| Wrong movie/show | Inspect `cleaned title=...` and `TMDb selected id=...`; remove the persistent cache when deliberately retesting from a clean state |
| Correct show but no episode title/still | TMDb may not contain that exact season/episode yet. discord-mpv-rpc intentionally does not remap it to a different season |
| Do not want episode lookups | Set `tmdb_episode_lookup=no` |
| Poster is cropped | Use `poster_fit=contain` |
| Do not want wsrv.nl | Use `poster_fit=raw` |
| wsrv is unavailable | The script automatically falls back to the raw TMDb image and retries after the cached failure expires |
| TMDb returns 429 | The script automatically backs off; avoid repeatedly deleting the cache during normal use |
| Old cached result during testing | Delete `discord-mpv-rpc-posters.json` to force a clean persistent lookup |

### Test TMDb manually

Example TV search:

```bash
curl -s "https://api.themoviedb.org/3/search/tv?api_key=YOUR_KEY&query=Dragon%20Ball%20DAIMA"
```

If that fails outside mpv, check your TMDb key, network access, and `curl` installation.

## Notes

- TMDb episode lookup is intentionally conservative. Missing TMDb data is left missing rather than guessed.
- Title matching is cached, so later episodes of the same show normally avoid repeating the full search process.
- The Discord progress bar is driven by timestamps; the script does not display elapsed/remaining time text.

## License

[MIT](https://opensource.org/licenses/MIT)
