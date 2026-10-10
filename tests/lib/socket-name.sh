# Where Tidal Wave's single-instance rendezvous socket lives. Sourced, never
# run: `. "$REPO_ROOT/tests/lib/socket-name.sh"`. Safe under `set -u`.
# Mirrors Application::singleInstanceSocketName() in src/ui/Application.cpp and
# has to change whenever that does. The address is <dir>/TidalWave-<uid>, where
# <dir> is the first of $XDG_RUNTIME_DIR, $TMPDIR (else /tmp) and /tmp that
# exists and keeps the path inside sun_path.

# kUnixSocketPathMax in Application.cpp: sizeof(sun_path) - 2, with 108 on
# Linux. QLocalServer::listen() takes one byte less than a raw bind().
TW_SOCKET_PATH_MAX=106

TW_SOCKET_LEAF="TidalWave-$(id -u)"

# tw_socket_dir <xdg_runtime_dir> <tmpdir>
# The directory the app will choose for those two environment values, in the
# C++'s order of preference. Either may be empty. Falls back to /tmp.
tw_socket_dir() {
    local xdg=${1:-} tmp=${2:-} dir bytes
    # QDir::tempPath() is $TMPDIR with any trailing slash cleaned off, or /tmp.
    tmp=${tmp%/}
    [ -n "$tmp" ] || tmp=/tmp
    for dir in "$xdg" "$tmp" /tmp; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || continue
        # Counted in bytes, as sun_path and the C++'s QFile::encodeName() count.
        bytes=$(( $(printf '%s/%s' "$dir" "$TW_SOCKET_LEAF" | wc -c) ))
        [ "$bytes" -le "$TW_SOCKET_PATH_MAX" ] || continue
        printf '%s\n' "$dir"
        return 0
    done
    printf '%s\n' /tmp
}

# tw_socket_path <xdg_runtime_dir> <tmpdir>
# The absolute address the app will bind for that pair of values, for example
# tw_socket_path "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}" for the current session.
tw_socket_path() {
    printf '%s/%s\n' "$(tw_socket_dir "${1:-}" "${2:-}")" "$TW_SOCKET_LEAF"
}

# tw_socket_live_addresses [exclude_prefix]
# Every bound unix socket whose leaf is ours, one address per line, skipping
# anything under <exclude_prefix>. Reads /proc/net/unix, a passive probe.
tw_socket_live_addresses() {
    local exclude=${1:-}
    # The address is whatever follows the seven fixed columns, so a directory
    # with a space in it comes out whole. Abstract names begin with '@' and are
    # never ours. Any state counts.
    awk -v leaf="/$TW_SOCKET_LEAF" -v ex="$exclude" '
        { path = $0; sub(/^([^ \t]+[ \t]+){7}/, "", path) }
        path !~ /^\// { next }
        substr(path, length(path) - length(leaf) + 1) != leaf { next }
        ex != "" && substr(path, 1, length(ex)) == ex { next }
        { print path }
    ' /proc/net/unix 2>/dev/null
}

# tw_socket_live [exclude_prefix]: true when such a socket is bound.
tw_socket_live() {
    [ -n "$(tw_socket_live_addresses "${1:-}")" ]
}
