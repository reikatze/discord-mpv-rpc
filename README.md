# discord-mpv-rpc

<p align="center">
  <a href="https://discord.com/"><img src="assets/discord-logo.svg" alt="Discord" height="40"></a>&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://www.themoviedb.org/"><img src="assets/tmdb-logo.svg" alt="TMDb" height="40"></a>
</p>

A small [mpv](https://mpv.io/) script that shows what you are watching as Discord Rich Presence.

It works on its own with filenames and mpv metadata. Add a free [TMDb](https://www.themoviedb.org/) API key if you also want official titles, posters, episode names, episode stills, and links back to TMDb.

<p align="center">
  <img src="assets/preview-1.png" alt="Discord Rich Presence showing Dragon Ball DAIMA" width="48%" height="160">
  <img src="assets/preview-2.png" alt="Discord Rich Presence showing The Boy And The Heron" width="48%" height="160">
</p>

## What it does

- Shows **Watching `<title>`** in Discord
- Displays playing, paused, buffering, and idle states
- Keeps Discord's progress bar in sync with playback speed
- Understands common movie, TV, scene, and anime filenames
- Removes common release tags before looking up a title
- Can show episode details such as `04 of 20: Chatty`
- Uses TMDb posters, show art, and episode stills when available
- Reconnects automatically if Discord restarts
- Caches metadata between mpv sessions
- Can use a local TMDb title index to reduce online searches
- Updates only when something changes instead of constantly polling

You do not need a Discord bot, OAuth setup, or installation link.

## Before you start

You will need:

- [mpv](https://mpv.io/)
- The Discord desktop app
- **Display current activity as a status message** enabled under Discord's **Settings > Activity Privacy**
- [`curl`](https://curl.se/) on your `PATH` if you want TMDb metadata and artwork
- A free [TMDb API key](https://www.themoviedb.org/settings/api) for TMDb features

Basic Rich Presence works without a TMDb key.

## Install

Copy the project into mpv's configuration directory so it looks like this:

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

Use `discord-mpv-rpc.conf.example` as the starting point for `script-opts/discord-mpv-rpc.conf`.

| OS | mpv configuration directory |
|---|---|
| Windows | `%APPDATA%\mpv` |
| Linux / macOS | `~/.config/mpv` |
| Portable Windows | `<mpv_dir>\portable_config` |

Keep the complete `modules/`, `db/`, and `tools/` directories beside `main.lua`.

## Get it working

For the full experience, open `script-opts/discord-mpv-rpc.conf` and add your TMDb key:

```ini
tmdb_api_key=your_tmdb_key_here
```

Then:

1. Start Discord.
2. Open a video in mpv.
3. Check your Discord profile for the activity.

Press `D` at any time to turn Rich Presence off or back on for the current mpv session.

The script includes a Discord Application ID, so you can leave `client_id` empty. If you prefer to use your own application, create one in the [Discord Developer Portal](https://discord.com/developers/applications) and set:

```ini
client_id=your_application_id
```

For a custom application, you can upload square Rich Presence assets named `mpv`, `play`, and `pause`, or change the matching asset names in the configuration.

## Configuration

The defaults should be fine for most people. Restart mpv after changing the configuration file.

| Option | Default | What it controls |
|---|---|---|
| `client_id` | built in | Discord Application ID; leave empty to use the included one |
| `tmdb_api_key` | empty | Enables TMDb titles, episode data, links, and artwork |
| `tmdb_language` | `en-US` | Language used for TMDb searches and metadata |
| `tmdb_episode_lookup` | `yes` | Looks up the exact parsed season and episode |
| `tmdb_local_index` | `yes` | Enables local title-index lookup and automatic maintenance |
| `tmdb_index_mpv_path` | empty | Optional path to a LuaJIT-enabled mpv for the index worker |
| `tmdb_positive_cache_days` | `60` | Days before successful TMDb metadata is refreshed |
| `cache_path` | empty | Metadata-cache path; empty stores it beside `main.lua` |
| `key_toggle` | `D` | Turns Rich Presence on or off for the current session |
| `key_toggle_db` | `Ctrl+d` | Turns local-index lookup on or off for the current session |
| `large_image` | `mpv` | Fallback large-image asset key |
| `large_text` | `mpv` | Fallback image hover text |
| `small_image_playing` | `play` | Playing badge asset key; leave empty to hide it |
| `small_image_paused` | `pause` | Paused and buffering badge asset key; leave empty to hide it |
| `small_image_idle` | `mpv` | Idle badge asset key; leave empty to hide it |
| `poster_fit` | `contain` | `contain` fits artwork through wsrv.nl; `raw` uses the TMDb image directly |
| `enabled` | `yes` | Enables Rich Presence when mpv starts |
| `ignored_paths` | `[]` | JSON array of files or directories that the script should ignore |

## Keep private media private

If there are files or directories you never want shown in Discord, add them to `ignored_paths` as a JSON array:

```ini
ignored_paths=["~~/watch-later/private","/mnt/media/home-videos","/mnt/media/test.mkv"]
```

A file entry matches only that file. A directory entry includes everything below it.

Absolute paths and mpv path prefixes such as `~~/` are supported. Relative paths are resolved from mpv's working directory. On Windows, forward slashes are easiest because they avoid JSON backslash escaping:

```ini
ignored_paths=["C:/Media/Private"]
```

If the JSON is invalid, the option is ignored and mpv writes a warning to its log. When ignored media is opened, the script clears any previous Discord activity and skips metadata parsing, TMDb requests, presence updates, and reconnection attempts.

Network streams are also ignored.

## What appears in Discord

The script chooses a title in this order:

1. Official TMDb title
2. The file's `metadata/title`
3. A cleaned version of the filename
4. mpv's `media-title`

For a TV episode, the second line can include the episode number, season total, and title:

```text
Dragon Ball DAIMA
04 of 20: Chatty
```

If the season total is unavailable, this becomes `04: Chatty`. If TMDb has no title for that exact episode, the script uses a meaningful chapter title or the current playback state instead. It never guesses a missing episode or silently remaps it to another season.

While a video is playing, Discord receives timestamps based on the current position, duration, and playback speed. The timestamps disappear while playback is paused or buffering and are recalculated after a seek or resume.

## How filename matching works

You do not need to rename a typical media library. These formats are recognized automatically:

```text
Movie.Name.2026.1080p.BluRay.mkv
Show.Name.S02E05.mkv
Show.Name.2x05.mkv
Show Name Season 2 Episode 5.mkv
[Judas] Dragon Ball Daima - S01E04v2.mkv
[SubsPlease] Show - 04 [1080p].mkv
```

The parser removes common source, resolution, codec, audio, bit-depth, and release-group tags. It can also use a parent directory such as `Show Name (2026)` for extra title and year context.

Filename parsing is still heuristic. If a title is matched incorrectly, check the `cleaned title` entry in mpv's log. Simplifying an unusual filename or parent-directory name will often fix it.

## Optional local TMDb index

The local index helps the script find exact movie and TV titles before falling back to a regular online TMDb search. It is built from [TMDb's daily ID exports](https://developer.themoviedb.org/docs/daily-id-exports).

This feature is optional. A TMDb API key is still needed to retrieve metadata and artwork, and automatic index maintenance will not start without one.

With `tmdb_local_index=yes`, a separate mpv worker checks the index at startup and once an hour. Full checksum checks happen no more than once a day unless corruption is detected. The worker downloads and rebuilds the index only when it is:

- Missing
- Corrupted
- At least seven days old

An older but valid index remains available while a replacement is built. Playback, cached metadata, and normal online TMDb searches continue during maintenance. When the new index is ready, the script picks it up automatically and removes downloaded exports and inactive generations.

The updater is written in pure Lua and uses mpv, LuaJIT, and the existing `curl` executable. It does not need Python, a database engine, or an unzip program.

Index builds can use several hundred MB of memory, and the script directory must be writable. A failed build leaves the active index untouched and will not be retried more than once an hour.

To disable both local lookups and automatic maintenance, set:

```ini
tmdb_local_index=no
```

`Ctrl+D` temporarily toggles the local index for the current session. It does not rewrite the configuration or stop a worker that is already running.

To run the same validation and update manually from the installed script directory:

```sh
mpv --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tools/update_tmdb_index.lua
```

Generated index files are stored in `db/tmdb/`.

## Cache, requests, and artwork

By default, metadata is cached in `discord-mpv-rpc-posters.json` beside `main.lua`. Set `cache_path` if you would rather store it somewhere else; mpv path prefixes such as `~~/` are supported.

Successful TMDb results are refreshed according to `tmdb_positive_cache_days`. Missing results use shorter retry periods. If you deliberately want to test matching from scratch, close mpv and delete the cache file first.

TMDb requests are paced, combined when possible, cached, and cancelled when they belong to a file that is no longer active. The script also backs off automatically after an HTTP 429 response. Local-index lookups read small, bounded sections from disk instead of loading the whole database into memory.

With `poster_fit=contain`, the TMDb image URL is sent to [wsrv.nl](https://wsrv.nl/) so portrait artwork fits Discord's square image area. Set `poster_fit=raw` if you do not want to use that third-party image service; Discord may crop the original image.

## Troubleshooting

| Problem | Things to check |
|---|---|
| Nothing appears in Discord | Start the Discord desktop app and enable its activity-privacy setting |
| A custom Discord application does not work | Double-check its `client_id` |
| No TMDb titles or artwork | Add `tmdb_api_key`, make sure `curl` is on `PATH`, and inspect mpv's log |
| The wrong movie or show is selected | Check the `cleaned title` and `TMDb selected` log entries; clear the cache before retesting |
| No episode title | TMDb may not have that exact season and episode, or `tmdb_episode_lookup` may be disabled |
| No `of <total>` text | The season total is unavailable or smaller than the current episode number |
| A poster is cropped | Set `poster_fit=contain` |
| You do not want to use wsrv.nl | Set `poster_fit=raw` |
| Discord was restarted after mpv | Reconnection is automatic; background detection on Windows requires LuaJIT |
| The local index does not build | Use a LuaJIT-enabled mpv, verify `curl`, and make sure the script directory is writable |

Running mpv from a terminal—or turning on verbose logging—usually provides the most useful details.

## Credits

Movie and TV metadata and artwork are provided by TMDb. The pure-Lua index updater includes [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) under its original zlib license.

Discord is a trademark of Discord Inc. This project is not affiliated with or endorsed by Discord or TMDb.

## License

[MIT](https://opensource.org/licenses/MIT)
