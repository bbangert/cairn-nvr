#!/bin/sh
# Stand-in for ffmpeg in FFmpegPort lifecycle tests.
# Usage: fake_ffmpeg.sh <fixture> [seconds_to_sleep_after_cat] [exit_status]
# Cats the fmp4 fixture to stdout, idles, then exits — exercising the
# demuxer path, the stall watchdog, and backoff respawn.
cat "$1"
sleep "${2:-0.2}"
exit "${3:-0}"
