# Where Tidal Wave's single-instance rendezvous socket lives.
#
# Sourced, never run: `. "$REPO_ROOT/tests/lib/socket-name.sh"`. Safe under
# `set -u`. Defines TW_SOCKET_LEAF and the tw_socket_* functions below.
#
# This mirrors Application::singleInstanceSocketName() in src/ui/Application.cpp
# and has to be changed whenever that is. It exists because the two harnesses
# each hardcoded the old flat name "TidalWaveSingleInstanceSocket", which no
# build has used since the uid went into the leaf and the directory became
# explicit. A wrong name fails silently in the worst possible direction: every
# probe for the developer's running instance came back "nothing is running", for
# as long as nobody looked. One copy here, two callers, one place to fix.
#
# The C++ builds the address as:
#
#   leaf = TidalWave-<getuid()>            the uid is in the name so that two
#                                          people on one machine cannot fight
#                                          over one file in a shared /tmp
#   dir  = the first of $XDG_RUNTIME_DIR,
#          QDir::cleanPath(QDir::tempPath()) (i.e. $TMPDIR, else /tmp),
#          and /tmp
#          that exists and leaves the finished path inside sun_path
#
# and hands QLocalServer that absolute path, so for a sandboxed launch it is
# XDG_RUNTIME_DIR that decides where the lock lands, with TMPDIR as the
# fallback. Both have to be inside the sandbox for the launch to be isolated.

# kUnixSocketPathMax in Application.cpp, which is sizeof(sun_path) - 2: 108 - 2
# on Linux, which is the only platform these harnesses run on. Two rather than
# one because the binder is QLocalServer, not bind() directly, and the two differ
# by a byte - measured on Qt 6.12, a raw bind() takes 107 bytes while
# QLocalServer::listen() refuses it with "Name error" and takes 106.
TW_SOCKET_PATH_MAX=106

TW_SOCKET_LEAF="TidalWave-$(id -u)"

# tw_socket_dir <xdg_runtime_dir> <tmpdir>
#
# The directory the app will choose given those two environment values, in the
# C++'s order of preference. Either argument may be empty, which is what an
# unset variable looks like from here. Always prints something, because /tmp is
# the floor the app itself falls back to.
tw_socket_dir() {
    local xdg=${1:-} tmp=${2:-} dir bytes
    # QDir::tempPath() is $TMPDIR with any trailing slash cleaned off, or /tmp.
    tmp=${tmp%/}
    [ -n "$tmp" ] || tmp=/tmp
    for dir in "$xdg" "$tmp" /tmp; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || continue
        # Bytes, not characters, because that is what sun_path and the C++'s
        # QFile::encodeName() count.
        bytes=$(( $(printf '%s/%s' "$dir" "$TW_SOCKET_LEAF" | wc -c) ))
        [ "$bytes" -le "$TW_SOCKET_PATH_MAX" ] || continue
        printf '%s\n' "$dir"
        return 0
    done
    printf '%s\n' /tmp
}

# tw_socket_path <xdg_runtime_dir> <tmpdir>
#
# The absolute address the app will bind for that pair of values. For the
# developer's own session: tw_socket_path "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}".
# For a harness sandbox: tw_socket_path "$BOX/run" "$BOX/tmp".
tw_socket_path() {
    printf '%s/%s\n' "$(tw_socket_dir "${1:-}" "${2:-}")" "$TW_SOCKET_LEAF"
}

# tw_socket_live_addresses [exclude_prefix]
#
# Every bound unix socket on this machine whose leaf is ours, one address per
# line, skipping anything under <exclude_prefix> so a harness never mistakes its
# own sandbox for the developer's instance. Matching on the leaf rather than on
# one expected directory also catches an instance that landed in $TMPDIR instead
# of $XDG_RUNTIME_DIR.
#
# Reading /proc/net/unix is a passive probe: it never signals, connects to, or
# even names a process, which is the one thing these harnesses must not do to
# the developer's running app.
tw_socket_live_addresses() {
    local exclude=${1:-}
    # The address is whatever follows the seven fixed columns, so a directory
    # with a space in it still comes out whole. Abstract names begin with '@'
    # and are never ours, hence the leading '/'. Any appearance counts, not only
    # state 01: erring towards "something is there" errs towards leaving it be.
    awk -v leaf="/$TW_SOCKET_LEAF" -v ex="$exclude" '
        { path = $0; sub(/^([^ \t]+[ \t]+){7}/, "", path) }
        path !~ /^\// { next }
        substr(path, length(path) - length(leaf) + 1) != leaf { next }
        ex != "" && substr(path, 1, length(ex)) == ex { next }
        { print path }
    ' /proc/net/unix 2>/dev/null
}

# tw_socket_live [exclude_prefix] - true when such a socket is bound.
tw_socket_live() {
    [ -n "$(tw_socket_live_addresses "${1:-}")" ]
}
