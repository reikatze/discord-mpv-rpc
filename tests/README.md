# GitHub Actions tests

Install the updated workflow and all test files in the repository, preserving
`.github/workflows` and `tests/mpv`. The workflow runs on pushes, pull requests,
and manual **Actions → Tests → Run workflow** requests.

## Coverage

| Runner | Runtime | Tests |
| --- | --- | --- |
| Ubuntu 24.04 x64 | Lua 5.4 and LuaJIT | Shared unit and regression suite |
| Ubuntu 24.04 x64 | mpv built with LuaJIT | Unit suite, playback suite, native Unix IPC |
| Windows Server 2022 x64 | mpv built with LuaJIT using MSYS2 UCRT64 | Unit suite, playback suite, native Windows named pipes |
| macOS 15 ARM64 | Homebrew mpv with LuaJIT | Unit suite, playback suite, native Unix IPC |
| macOS 15 Intel | Homebrew mpv with LuaJIT | Unit suite, playback suite, native Unix IPC |

Every platform job runs the complete unit suite inside its actual mpv runtime.
The TV/movie Discord payload suite in `tests/presence_payload.lua` drives the
production filename, TMDb matching and episode lookup, artwork, metadata,
presence, and IPC modules with fixed local API responses. It checks:

- TV show name, episode label/count, episode still, and show-poster fallback.
- Movie name, year disambiguation, poster, and removal of stale TV metadata.
- Activity type, display mode, names, details, state, image tooltips, links,
  configured status icons, and omission of empty icons.
- Elapsed/remaining timestamps, pause/resume, seeking, playback speed,
  buffering, idle state, unknown duration, and position clamping.
- Raw and contained artwork, image-proxy failure fallback, missing metadata,
  Unicode/escaped text, duplicate suppression, ignored/disabled/network media,
  and clearing activity when playback ends.

Inside mpv, the suite uses mpv's real JSON codec and decodes the outgoing
`SET_ACTIVITY` frames to verify what the Discord peer would receive. Standalone
Lua checks activity fields and IPC framing with a small fixture serializer.
The fixture IDs and image paths are synthetic; these tests verify the payload
sent to Discord, not Discord's rendering or live TMDb/wsrv availability.

The portable playback runner checks idle startup, playback lifecycle, movie
and TV filename parsing, ignored paths, presence toggles, and a local HTTP
stream. It generates its own small video and writes an ignored-path
configuration using the platform's actual absolute path.

The native IPC runner starts a local fake Discord peer and launches the real
production IPC client in a separate mpv process. Six scenarios check:

1. Fragmented READY response, activity acknowledgement, and PING/PONG.
2. Activity rejection followed by a successful retry.
3. Disconnect detection and removal of pending commands and queued writes.
4. Reconnection after the backoff deadline and a second successful READY.
5. Handshake timeout when the peer never sends READY.
6. Write timeout when the peer stops consuming a large queued frame.

These scenarios use OS sockets or Windows named pipes. They are not replaced
by mocks in the GitHub Actions platform jobs. No Discord login or TMDb API
key is required. The IPC peer is intended for isolated CI runners, not a
computer with Discord already running.

## Boundaries

The workflow creates local media and synthetic unit-test index fixtures. It
never downloads, copies, or rebuilds the master TMDb database, and does not
perform live TMDb or wsrv service checks. It does not publish releases or
modify repository contents. Native 32-bit and Windows ARM runners are not
included in this matrix.

Linux and Windows build only a temporary mpv test runtime. macOS uses the
Homebrew package; the tests fail if that runtime is not LuaJIT-enabled.
The temporary builds explicitly disable OpenGL because the suites use null
video and audio outputs. The runners resolve script paths against mpv's
working directory, including the relative paths used by GitHub Actions.
Failed cases include the child mpv log in the Actions output, even when the
child times out. Individual logs are also written under `MPV_TEST_WORK`.
