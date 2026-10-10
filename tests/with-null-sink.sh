#!/bin/sh
# Runs a command with a private PulseAudio server that has one null sink, so
# tests that open an audio device find one and nothing reaches a speaker.
# For containers and CI, where no sound server runs.
#   tests/with-null-sink.sh ctest --test-dir build
set -eu
XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
trap 'pulseaudio --kill 2>/dev/null || true; rm -rf "$XDG_RUNTIME_DIR"' EXIT
pulseaudio -n --daemonize=yes --exit-idle-time=-1 \
    --load=module-native-protocol-unix \
    --load="module-null-sink sink_name=tests_null" \
    --load=module-always-sink
"$@"
