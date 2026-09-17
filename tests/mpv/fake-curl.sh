#!/usr/bin/env bash
set -eu

if [[ -n ${MPV_TEST_CURL_LOG:-} ]]; then
    printf 'called\n' >>"$MPV_TEST_CURL_LOG"
fi
printf '\n000'
exit 7
