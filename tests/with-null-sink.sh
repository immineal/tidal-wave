#!/bin/sh
# Runs a command with a private PulseAudio server that has two null sinks, so
# tests that open or switch an audio device find them and nothing reaches a
# speaker.
# For containers and CI, where no sound server runs.
#   tests/with-null-sink.sh ctest --test-dir build
set -eu
XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR
# The exit status is the command's own. The daemon goes down after --kill has
# returned and still writes meanwhile, so it is waited for; what cannot be
# removed even then is named and left.
cleanup() {
    status=$?
    daemon=$(cat "$XDG_RUNTIME_DIR/pulse/pid" 2>/dev/null || true)
    HOME="$XDG_RUNTIME_DIR" pulseaudio --kill 2>/dev/null || true
    tries=0
    while [ -n "$daemon" ] && kill -0 "$daemon" 2>/dev/null && [ "$tries" -lt 100 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
    rm -rf "$XDG_RUNTIME_DIR" 2>/dev/null \
        || echo "with-null-sink.sh: left behind: $(find "$XDG_RUNTIME_DIR" | head -5 | tr '\n' ' ')" >&2
    exit "$status"
}
trap cleanup EXIT
# The daemon gets a home of its own: it refuses one that belongs to another
# user, which is what a CI container hands to root.
HOME="$XDG_RUNTIME_DIR" pulseaudio -n --daemonize=yes --exit-idle-time=-1 \
    --load="module-native-protocol-unix auth-anonymous=1" \
    --load="module-null-sink sink_name=tests_null" \
    --load="module-null-sink sink_name=tests_null_2" \
    --load=module-always-sink
"$@"
