#!/bin/sh
# Runs a command with a private PulseAudio server that has one null sink, so
# tests that open an audio device find one and nothing reaches a speaker.
# For containers and CI, where no sound server runs.
#   tests/with-null-sink.sh ctest --test-dir build
set -eu
XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
trap 'HOME="$XDG_RUNTIME_DIR" pulseaudio --kill 2>/dev/null || true; rm -rf "$XDG_RUNTIME_DIR"' EXIT
# The daemon gets a home of its own: it refuses one that belongs to another
# user, which is what a CI container hands to root.
HOME="$XDG_RUNTIME_DIR" pulseaudio -n --daemonize=yes --exit-idle-time=-1 \
    --load="module-native-protocol-unix auth-anonymous=1" \
    --load="module-null-sink sink_name=tests_null" \
    --load=module-always-sink
"$@"
