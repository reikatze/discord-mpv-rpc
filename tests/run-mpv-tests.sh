#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

mpv_bin=${MPV_BIN:-}
media_file=${MPV_TEST_MEDIA:-}
library_dir=${MPV_LIBRARY_PATH:-}
database_dir=${MPV_TEST_DATABASE:-}
ffmpeg_bin=${FFMPEG_BIN:-}

usage() {
    cat <<'EOF'
Usage: tests/run-mpv-tests.sh [options]

Runs the unit and integration suites inside a real mpv LuaJIT runtime.

Options:
  --mpv PATH      mpv executable (or set MPV_BIN)
  --media PATH    local video used for playback tests (or set MPV_TEST_MEDIA)
  --lib-dir PATH  directory containing private shared libraries
                  (or set MPV_LIBRARY_PATH)
  --database PATH TMDb index directory containing current.json
                  (or set MPV_TEST_DATABASE)
  --ffmpeg PATH   ffmpeg executable for the live-stream test
                  (or set FFMPEG_BIN)
EOF
}

while (($#)); do
    case $1 in
        --mpv)
            mpv_bin=${2:?missing value for --mpv}
            shift 2
            ;;
        --media)
            media_file=${2:?missing value for --media}
            shift 2
            ;;
        --lib-dir)
            library_dir=${2:?missing value for --lib-dir}
            shift 2
            ;;
        --database)
            database_dir=${2:?missing value for --database}
            shift 2
            ;;
        --ffmpeg)
            ffmpeg_bin=${2:?missing value for --ffmpeg}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z $mpv_bin ]]; then
    for candidate in \
        "$root_dir/../runtime/mpv" \
        "$root_dir/../mpv"; do
        if [[ -x $candidate ]]; then
            mpv_bin=$candidate
            break
        fi
    done
fi
if [[ -z $mpv_bin ]]; then
    mpv_bin=$(command -v mpv || true)
fi
if [[ -z $mpv_bin || ! -x $mpv_bin ]]; then
    printf 'mpv was not found; pass --mpv PATH or set MPV_BIN.\n' >&2
    exit 2
fi

if [[ -z $media_file ]]; then
    for candidate in \
        "$root_dir/../runtime/big buck bunny.mp4" \
        "$root_dir/../big buck bunny.mp4"; do
        if [[ -f $candidate ]]; then
            media_file=$candidate
            break
        fi
    done
fi
if [[ -z $media_file || ! -f $media_file ]]; then
    printf 'Test media was not found; pass --media PATH or set MPV_TEST_MEDIA.\n' >&2
    exit 2
fi

if [[ -z $library_dir ]]; then
    mpv_dir=$(CDPATH= cd -- "$(dirname -- "$mpv_bin")" && pwd)
    if compgen -G "$mpv_dir/lib*.so*" >/dev/null; then
        library_dir=$mpv_dir
    fi
fi
if [[ -n $library_dir ]]; then
    export LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

if [[ -z $database_dir ]]; then
    for candidate in \
        "$root_dir/db/tmdb" \
        "$root_dir/../../Discord MPV Tracker Database/tmdb"; do
        if [[ -f $candidate/current.json ]]; then
            database_dir=$candidate
            break
        fi
    done
fi
if [[ -n $database_dir && ! -f $database_dir/current.json ]]; then
    printf 'TMDb test database does not contain current.json: %s\n' "$database_dir" >&2
    exit 2
fi

if [[ -z $ffmpeg_bin ]]; then
    ffmpeg_bin=$(command -v ffmpeg || true)
fi
if [[ -n $ffmpeg_bin && ! -x $ffmpeg_bin ]]; then
    printf 'ffmpeg is not executable: %s\n' "$ffmpeg_bin" >&2
    exit 2
fi

test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/discord-mpv-rpc-tests.XXXXXX")
trap 'rm -rf -- "$test_tmp"' EXIT

scene_media="$test_tmp/[Judas] Dragon Ball Daima - S01E04v2.mkv"
movie_media="$test_tmp/Birdman (or the Unexpected Virtue of Ignorance) (2014) 1080p BluRay.mkv"
ln -s -- "$media_file" "$scene_media"
ln -s -- "$media_file" "$movie_media"
ln -s -- "$script_dir/mpv/fake-curl.sh" "$test_tmp/curl"

common=(
    --no-config
    --load-scripts=no
    --vo=null
    --ao=null
    --terminal=yes
    --msg-color=no
)
main_options=(
    --script="$root_dir/main.lua"
    --script-opts=discord-mpv-rpc-enabled=no,discord-mpv-rpc-tmdb_local_index=no
)

passed=0
skipped=0
run_case() {
    local name=$1
    local marker=$2
    shift 2
    local log="$test_tmp/$name.log"

    printf 'test: %-28s ' "$name"
    if ! "$mpv_bin" "${common[@]}" "$@" >"$log" 2>&1; then
        printf 'FAIL\n' >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    fi
    if grep -Eq 'MPV_TEST_FAILURE|Lua error|stack traceback|cannot load .+\.lua' "$log"; then
        printf 'FAIL\n' >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    fi
    if ! grep -Fq "$marker" "$log"; then
        printf 'FAIL (missing marker)\n' >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    fi
    printf 'ok\n'
    passed=$((passed + 1))
}

run_case unit-suite MPV_TEST_UNIT_OK \
    --idle=yes \
    --script="$script_dir/mpv/unit_runner.lua"

run_case main-idle MPV_TEST_IDLE_OK \
    --idle=yes \
    "${main_options[@]}" \
    --script="$script_dir/mpv/probe.lua" \
    --script-opts-append=mpv-rpc-test-mode=idle

run_case playback-lifecycle MPV_TEST_PLAYBACK_OK \
    --frames=3 \
    "${main_options[@]}" \
    --script="$script_dir/mpv/probe.lua" \
    --script-opts-append=mpv-rpc-test-mode=playback \
    "$media_file"

run_case scene-filename MPV_TEST_FILENAME_OK \
    --frames=3 \
    "${main_options[@]}" \
    --script="$script_dir/mpv/probe.lua" \
    --script-opts-append=mpv-rpc-test-mode=filename \
    --script-opts-append='mpv-rpc-test-expected_title=Dragon Ball Daima' \
    --script-opts-append=mpv-rpc-test-expected_tv=yes \
    --script-opts-append=mpv-rpc-test-expected_season=1 \
    --script-opts-append=mpv-rpc-test-expected_episode=4 \
    "$scene_media"

run_case movie-filename MPV_TEST_FILENAME_OK \
    --frames=3 \
    "${main_options[@]}" \
    --script="$script_dir/mpv/probe.lua" \
    --script-opts-append=mpv-rpc-test-mode=filename \
    --script-opts-append='mpv-rpc-test-expected_title=Birdman (or the Unexpected Virtue of Ignorance)' \
    --script-opts-append=mpv-rpc-test-expected_year=2014 \
    "$movie_media"

run_case presence-toggle MPV_TEST_TOGGLE_OK \
    --idle=yes \
    "${main_options[@]}" \
    --script="$script_dir/mpv/probe.lua" \
    --script-opts-append=mpv-rpc-test-mode=toggle

if [[ -n $ffmpeg_bin ]]; then
    stream_port=${MPV_TEST_STREAM_PORT:-$((38000 + $$ % 1000))}
    stream_log="$test_tmp/stream.log"
    stream_server_log="$test_tmp/stream-server.log"
    stream_curl_log="$test_tmp/stream-curl.log"
    printf 'test: %-28s ' live-network-stream
    "$ffmpeg_bin" -hide_banner -loglevel error -re -stream_loop -1 \
        -i "$media_file" -map 0:v:0 -c:v copy -an -f mpegts -listen 1 \
        "http://127.0.0.1:$stream_port" >"$stream_server_log" 2>&1 &
    stream_server_pid=$!
    sleep 0.5
    if ! PATH="$test_tmp:$PATH" MPV_TEST_CURL_LOG="$stream_curl_log" \
        "$mpv_bin" "${common[@]}" \
        --length=2 \
        --script="$root_dir/main.lua" \
        --script="$script_dir/mpv/probe.lua" \
        --script-opts=discord-mpv-rpc-enabled=yes,discord-mpv-rpc-tmdb_local_index=no,discord-mpv-rpc-tmdb_api_key=stream-test-key \
        --script-opts-append=mpv-rpc-test-mode=stream \
        "http://127.0.0.1:$stream_port/live.ts" >"$stream_log" 2>&1; then
        kill "$stream_server_pid" 2>/dev/null || true
        wait "$stream_server_pid" 2>/dev/null || true
        printf 'FAIL\n' >&2
        sed -n '1,240p' "$stream_log" >&2
        sed -n '1,120p' "$stream_server_log" >&2
        exit 1
    fi
    kill "$stream_server_pid" 2>/dev/null || true
    wait "$stream_server_pid" 2>/dev/null || true
    if grep -Eq 'MPV_TEST_FAILURE|Lua error|stack traceback|cannot load .+\.lua|Discord unavailable|connected to Discord' "$stream_log" \
        || ! grep -Fq MPV_TEST_STREAM_OK "$stream_log" \
        || [[ -s $stream_curl_log ]]; then
        printf 'FAIL\n' >&2
        sed -n '1,240p' "$stream_log" >&2
        sed -n '1,120p' "$stream_server_log" >&2
        exit 1
    fi
    printf 'ok\n'
    passed=$((passed + 1))
else
    printf 'test: %-28s skip (ffmpeg not found)\n' live-network-stream
    skipped=$((skipped + 1))
fi

if [[ -n $database_dir ]]; then
    run_case local-database MPV_TEST_DATABASE_OK \
        --idle=yes \
        --script="$script_dir/mpv/database_probe.lua" \
        --script-opts="mpv-rpc-db-test-database=$database_dir"
else
    printf 'test: %-28s skip (set --database)\n' local-database
    skipped=$((skipped + 1))
fi

printf 'ok - %d mpv test cases' "$passed"
if ((skipped > 0)); then printf ' (%d skipped)' "$skipped"; fi
printf '\n'
