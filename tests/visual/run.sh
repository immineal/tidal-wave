#!/usr/bin/env bash
#
# Screenshot harness: what 0.4.0 actually looks like.
#
# Three parts, because no single one of them can reach everything:
#
#   login   The real build-t/tidal-wave binary, launched the way a brand new
#           install sees it - empty HOME, no saved Tidal session - on a private
#           Xvfb sized 960x1200, once per theme. An unauthenticated launch shows
#           the login page and nothing else, so that is what this half captures,
#           and it is the only half where the picture comes out of the shipping
#           executable.
#
#   shots   Everything behind the login wall: the sidebar, the player bar, the
#           Settings panel, a track row, the album page and Now Playing. There
#           is no Tidal session on a developer box, so these are instantiated
#           against tests/TestStubs.h by the tst_shots runner built out of
#           tests/visual/CMakeLists.txt, and grabbed with QQuickItem::grabToImage
#           (via QtQuickTest's grabImage).
#
#   store   The five store screenshots: Main.qml whole, 1280x800, on the
#           invented library in tests/visual/store/. Same runner as shots.
#
# Usage
#   tests/visual/run.sh                  all of them
#   tests/visual/run.sh login            only the real-binary login shots
#   tests/visual/run.sh shots            only the component shots
#   tests/visual/run.sh store            only the five store screenshots
#   tests/visual/run.sh --clean          also throw the harness build away first
#   tests/visual/run.sh --keep           leave the sandbox behind for poking at
#   DWELL=12 tests/visual/run.sh         seconds to let each app launch live
#   TIDALWAVE_BIN=/path/to/tidal-wave tests/visual/run.sh
#
# PNGs land in tests/visual/out/, which carries a .gitignore so they are never
# committed. Exit status is 0 only if every half that ran succeeded; a half that
# cannot run on this box says why and does not fail the run.
#
# Safety, because a real instance of this app is usually running on the dev box.
# The rules and most of the machinery are lifted from tests/firstrun/run.sh:
#
#   * Nothing here ever pkills, killalls or pattern-matches a process name. The
#     only processes killed are helpers this script started, by recorded pid.
#   * Every launch gets its own HOME, TMPDIR, XDG_RUNTIME_DIR and XDG_*_HOME
#     under a private scratch directory, and goes through `env -i` so no
#     variable from the caller's session leaks in.
#   * The single-instance lock is a QLocalServer bound to an absolute path,
#     $XDG_RUNTIME_DIR/TidalWave-<uid>, falling back to $TMPDIR and then to
#     /tmp. XDG_RUNTIME_DIR is therefore what isolates a launch, with TMPDIR
#     behind it, and the sandbox sets both. tests/lib/socket-name.sh works the
#     address out the same way Application::singleInstanceSocketName() does,
#     rather than this script guessing a name again - the guess it used to make
#     stopped matching anything the day the uid went into the name, and a lock
#     path nobody can match is a probe that always says "all clear". Without
#     the isolation a second launch connects to the developer's own instance,
#     tells it to show itself and exits 0 - which proves nothing and pops their
#     window.
#   * A unix socket path caps at 107 bytes, so the scratch root has to be short
#     or listen() fails and the lock silently never exists. Checked up front,
#     because a disabled lock is a false pass.
#   * The developer's real ~/.config/TidalWave is fingerprinted before the run
#     and re-checked after each launch. Any change aborts.
#   * No synthetic input reaches the X server. Nothing is clicked or typed:
#     state is seeded into the settings file before launch. The component half
#     does post Qt mouse-move events, but in its own process, to its own
#     window; nothing goes near the developer's session or this terminal.
#   * Every launch runs under `timeout`, so nothing started here outlives the
#     run.
#
set -u

# ── locations ───────────────────────────────────────────────────────────────

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
APP=${TIDALWAVE_BIN:-$REPO_ROOT/build-t/tidal-wave}
# TW_SOCKET_LEAF and tw_socket_path/tw_socket_live: the one place that knows
# where the single-instance lock lives, kept in step with src/ui/Application.cpp.
. "$REPO_ROOT/tests/lib/socket-name.sh"
OUT=$SELF_DIR/out
# Short on purpose, and outside the repo: see the sun_path note above. Kept
# between runs so a re-run is an incremental build rather than a four minute
# one; --clean throws it away.
HARNESS_BUILD=${TW_VISUAL_BUILD:-/tmp/tw-vis-build}

DWELL=${DWELL:-10}
KEEP=0
CLEAN=0
WANTED=()

# The six palette names in src/ui/ThemePalette.cpp, in the order Settings lists
# them: three dark, then the three light ones this run exists to look at.
THEMES=(sea pine rust clay sky sand)

# Half the user's 1920x1200 monitor, and the width the layout was designed
# against (SPEC L1, tests/qml/tst_layout_player.qml).
SHOT_W=960
SHOT_H=1200

for arg in "$@"; do
    case $arg in
        --keep)  KEEP=1 ;;
        --clean) CLEAN=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)  WANTED+=("$arg") ;;
    esac
done

wanted() {
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local w
    for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

# ── reporting ───────────────────────────────────────────────────────────────

C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_OFF=''
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
fi

PASSED=(); FAILED=(); SKIPPED=()

head2() { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass()  { PASSED+=("$1");  printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "${2:-$1}"; }
fail()  { FAILED+=("$1");  printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "${2:-$1}"; }
skip()  { SKIPPED+=("$1"); printf '  %sSKIP%s %s: %s\n' "$C_YEL" "$C_OFF" "$1" "$2"; }
info()  { printf '       %s\n' "$1"; }

die() { printf '%sabort:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 2; }

# ── scratch root and cleanup ────────────────────────────────────────────────

SCRATCH=$(mktemp -d /tmp/twvis.XXXXXX) || die "cannot create a scratch directory"

# The longest address a launch of ours can bind is $SCRATCH/<sandbox>/run/<leaf>
# - 24 bytes is ample for "/login-sea" and friends, 5 covers "/run/". The limit
# is kept short of sun_path's 107 rather than at it, because a lock that never
# binds does not fail the run, it silently stops isolating it.
probe_len=$(( ${#SCRATCH} + 24 + 5 + ${#TW_SOCKET_LEAF} ))
[ "$probe_len" -lt 100 ] || die "scratch path $SCRATCH is too long for a unix socket"

HELPER_PIDS=()
track() { HELPER_PIDS+=("$1"); }
reap_all() {
    local pid
    for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        # Only pids this script started, never a name match.
        kill -TERM "$pid" 2>/dev/null
    done
    for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -KILL "$pid" 2>/dev/null
    done
    HELPER_PIDS=()
}
cleanup() {
    reap_all
    if [ "$KEEP" -eq 1 ]; then
        printf '\nsandbox kept at %s\n' "$SCRATCH"
    else
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT INT TERM

# ── guard: the developer's own config must not move ─────────────────────────

REAL_CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/TidalWave
# The developer's own lock, worked out the way the app works it out. On a normal
# session that is $XDG_RUNTIME_DIR/TidalWave-<uid>, i.e. /run/user/<uid>/..., and
# not the temp dir this script used to fingerprint instead.
REAL_LOCK=$(tw_socket_path "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}")

# Passive liveness probe: a bound unix socket shows up in /proc/net/unix, so this
# never signals, connects to, or even names a process. A running instance
# rewrites its own settings whenever the volume or the last page changes, so
# contents drifting under us is expected and is not our doing.
#
# This used to grep for the old flat socket name, which nothing has bound since
# the uid went into it: it matched nothing, so the harness believed no instance
# was running even while the developer's window was open, and the tolerance
# below was never granted. Matching on the leaf also catches an instance that
# landed in $TMPDIR rather than $XDG_RUNTIME_DIR, and $SCRATCH is excluded so
# our own sandboxes can never be mistaken for it.
LIVE_INSTANCE=0
tw_socket_live "$SCRATCH" && LIVE_INSTANCE=1

guard_structure() {
    { [ -e "$REAL_LOCK" ] && stat -c 'lock %i %Y %a' "$REAL_LOCK"; } 2>/dev/null
    { [ -d "$REAL_CONF_DIR" ] && find "$REAL_CONF_DIR" -type f -printf 'file %p\n' | sort; } 2>/dev/null
    true
}
guard_contents() {
    { [ -d "$REAL_CONF_DIR" ] && find "$REAL_CONF_DIR" -type f -exec md5sum {} + | sort; } 2>/dev/null
    true
}
GUARD_STRUCT=$(guard_structure)
GUARD_BODY=$(guard_contents)

guard_check() {
    local now; now=$(guard_structure)
    if [ "$now" != "$GUARD_STRUCT" ]; then
        printf '%s\n' "--- before ---" "$GUARD_STRUCT" "--- after ---" "$now" >&2
        die "the real lock or settings directory changed while '$1' ran"
    fi
    local body; body=$(guard_contents)
    if [ "$body" != "$GUARD_BODY" ]; then
        if [ "$LIVE_INSTANCE" -eq 1 ]; then
            # Expected: the developer's own instance is saving its state. Our
            # launches die by SIGTERM, so QSettings never syncs and they write
            # no settings file at all, not even inside their sandbox.
            GUARD_BODY=$body
        else
            die "'$1' rewrote $REAL_CONF_DIR and no other instance is running"
        fi
    fi
}

# ── output directory ────────────────────────────────────────────────────────

mkdir -p "$OUT"
if [ ! -f "$OUT/.gitignore" ]; then
    cat > "$OUT/.gitignore" <<'IGN'
# Screenshots are build output: regenerate them with tests/visual/run.sh.
*
!.gitignore
IGN
fi

head2 "sandbox"
info "output:  $OUT"
info "scratch: $SCRATCH (short on purpose: a unix socket path caps at 107 bytes)"
if [ "$LIVE_INSTANCE" -eq 1 ]; then
    info "another instance is listening on $REAL_LOCK; it is left strictly alone."
else
    info "no other instance is listening; any write to the real settings is a hard failure."
fi

# ── a private X display ─────────────────────────────────────────────────────

pick_display() {
    local n
    for n in $(seq 90 99); do
        [ -e "/tmp/.X11-unix/X$n" ] || { echo ":$n"; return 0; }
    done
    return 1
}

# start_xvfb <w> <h> -> sets DISP, or returns 1
start_xvfb() {
    local w=$1 h=$2
    DISP=$(pick_display) || return 1
    Xvfb "$DISP" -screen 0 "${w}x${h}x24" -nolisten tcp \
        >"$SCRATCH/xvfb${DISP#:}.log" 2>&1 &
    XVFB_PID=$!
    track "$XVFB_PID"
    local _
    for _ in $(seq 1 60); do
        [ -e "/tmp/.X11-unix/X${DISP#:}" ] && return 0
        sleep 0.25
    done
    return 1
}

# ── sandbox construction ────────────────────────────────────────────────────

BOX=''
BOX_ENV=()

sandbox() {
    BOX=$SCRATCH/$1
    rm -rf "$BOX"
    mkdir -p "$BOX/home/.config/TidalWave" "$BOX/home/.cache" \
             "$BOX/home/.local/share" "$BOX/home/.local/state" \
             "$BOX/run" "$BOX/tmp" "$BOX/logs"
    # Qt complains and falls back if the runtime dir is group or world readable.
    chmod 700 "$BOX/run"
    BOX_ENV=(
        "PATH=/usr/local/bin:/usr/bin:/bin"
        "LANG=C.UTF-8"
        "LC_ALL=C.UTF-8"
        "HOME=$BOX/home"
        "TMPDIR=$BOX/tmp"
        "TMP=$BOX/tmp"
        "TEMP=$BOX/tmp"
        "XDG_RUNTIME_DIR=$BOX/run"
        "XDG_CONFIG_HOME=$BOX/home/.config"
        "XDG_CACHE_HOME=$BOX/home/.cache"
        "XDG_DATA_HOME=$BOX/home/.local/share"
        "XDG_STATE_HOME=$BOX/home/.local/state"
        "XDG_CONFIG_DIRS=/etc/xdg"
        "XDG_DATA_DIRS=/usr/local/share:/usr/share"
        # A dead address rather than an unset one: unset makes libdbus try to
        # autolaunch a daemon, and a live one would put this run's MPRIS name on
        # the developer's session bus.
        "DBUS_SESSION_BUS_ADDRESS=unix:path=$BOX/run/absent-session-bus"
        "QT_LOGGING_RULES="
    )
}

# The app's settings file. QSettings on Linux writes
# $XDG_CONFIG_HOME/<org>/<app>.conf, and Application::run() sets those to
# "TidalWave" and "Tidal Wave" - hence the space in the filename.
seed_theme() {
    printf '[ui]\ntheme=%s\n' "$1" > "$BOX/home/.config/TidalWave/Tidal Wave.conf"
}

# ── half one: the login page, from the real binary ──────────────────────────

if wanted login; then
    head2 "login page, real binary, ${SHOT_W}x${SHOT_H}"

    if [ ! -x "$APP" ]; then
        skip login "no binary at $APP (build with: cmake --build build-t --parallel 4)"
    elif ! command -v Xvfb >/dev/null 2>&1; then
        skip login "Xvfb is not installed, and using the real display would touch the developer's session"
    elif ! command -v import >/dev/null 2>&1; then
        skip login "ImageMagick's 'import' is not installed, so there is nothing to capture with"
    elif ! start_xvfb "$SHOT_W" "$SHOT_H"; then
        skip login "no free X display between :90 and :99, or Xvfb never came up"
    else
        info "private display $DISP (pid $XVFB_PID) at ${SHOT_W}x${SHOT_H}"
        login_ok=1
        for theme in "${THEMES[@]}"; do
            sandbox "login-$theme"
            seed_theme "$theme"

            # -qwindowgeometry is QGuiApplication's own option, applied to the
            # first top-level window. Without it the window comes up at the
            # 1280x800 Main.qml asks for and the 960-wide screen crops it; with
            # it the window is exactly the size under review and no window
            # manager has to be run to force it.
            ( env -i "${BOX_ENV[@]}" DISPLAY="$DISP" QT_QPA_PLATFORM=xcb \
                timeout -s TERM "$DWELL" "$APP" \
                -qwindowgeometry "${SHOT_W}x${SHOT_H}+0+0" \
                >"$BOX/logs/app.out" 2>"$BOX/logs/app.err" ) &
            app_job=$!
            # Long enough for the engine to load and the first frame to land.
            sleep $(( DWELL > 6 ? 5 : 3 ))

            geom=$(DISPLAY="$DISP" xwininfo -root -children 2>/dev/null \
                   | awk '/"Tidal Wave": \("tidal-wave"/ {
                              for (i = 1; i <= NF; i++)
                                  if ($i ~ /^[0-9]+x[0-9]+\+-?[0-9]+\+-?[0-9]+$/) { print $i; exit }
                          }')
            shot=$OUT/login_$theme.png
            import -display "$DISP" -window root "$shot" 2>/dev/null

            wait "$app_job"; status=$?

            if [ ! -s "$shot" ]; then
                fail "login-$theme" "nothing was captured"
                login_ok=0
            elif [ "$geom" != "${SHOT_W}x${SHOT_H}+0+0" ]; then
                fail "login-$theme" "window geometry was '$geom', wanted ${SHOT_W}x${SHOT_H}+0+0"
                login_ok=0
            elif [ "$status" -ne 124 ]; then
                # 124 is our own timeout, which is what "it stayed up" looks
                # like. A clean 0 means the sandbox leaked and it found the
                # developer's instance instead of starting its own.
                fail "login-$theme" "the app exited $status before the timeout"
                login_ok=0
            else
                ncol=$(convert "$shot" -format %k info: 2>/dev/null)
                pass "login-$theme" "login_$theme.png ($geom, $ncol distinct colours)"
            fi
            guard_check "login-$theme"
        done
        reap_all
        [ "$login_ok" -eq 1 ] || true
    fi
fi

# ── the shot runner, shared by the two sets below ───────────────────────────

RUNNER_BUILT=0

# build_runner <half> -> 0 with tst_shots built, 1 after saying why not
build_runner() {
    [ "$RUNNER_BUILT" -eq 1 ] && return 0

    if [ "$CLEAN" -eq 1 ]; then
        info "removing $HARNESS_BUILD"
        rm -rf "$HARNESS_BUILD"
        CLEAN=0
    fi

    if ! command -v cmake >/dev/null 2>&1; then
        skip "$1" "cmake is not installed"
        return 1
    elif ! command -v Xvfb >/dev/null 2>&1; then
        skip "$1" "Xvfb is not installed, and using the real display would touch the developer's session"
        return 1
    fi

    # Qt is not on the default search path on this box; take the prefix the
    # developer's own build was configured with rather than guessing.
    prefix=$(grep -m1 '^CMAKE_PREFIX_PATH:' "$REPO_ROOT/build-t/CMakeCache.txt" 2>/dev/null \
             | cut -d= -f2-)
    cfg_args=(-B "$HARNESS_BUILD" -S "$SELF_DIR" -DCMAKE_BUILD_TYPE=Debug)
    [ -n "$prefix" ] && cfg_args+=(-DCMAKE_PREFIX_PATH="$prefix")

    info "configuring and building the shot runner in $HARNESS_BUILD"
    if ! cmake "${cfg_args[@]}" >"$SCRATCH/cmake-configure.log" 2>&1; then
        fail "$1" "cmake configure failed; see $SCRATCH/cmake-configure.log"
        tail -20 "$SCRATCH/cmake-configure.log" | sed 's/^/         /'
        return 1
    elif ! cmake --build "$HARNESS_BUILD" --parallel 4 >"$SCRATCH/cmake-build.log" 2>&1; then
        fail "$1" "cmake build failed; see $SCRATCH/cmake-build.log"
        tail -20 "$SCRATCH/cmake-build.log" | sed 's/^/         /'
        return 1
    fi
    RUNNER_BUILT=1
}

# ── half two: the components, against the test stubs ────────────────────────

if wanted shots; then
    head2 "components, against tests/TestStubs.h"

    if build_runner shots; then
        if ! start_xvfb 1700 1400; then
            skip shots "no free X display between :90 and :99, or Xvfb never came up"
        else
            # Bigger than any scene, because grabToImage renders the item's own
            # subtree and the window only has to be somewhere to render it in.
            info "private display $DISP (pid $XVFB_PID) at 1700x1400"
            sandbox shots
            log=$BOX/logs/shots.log
            env -i "${BOX_ENV[@]}" DISPLAY="$DISP" TW_SHOT_OUT="$OUT" \
                timeout -s TERM 900 "$HARNESS_BUILD/tst_shots" \
                -input "$SELF_DIR/qml" >"$log" 2>&1
            status=$?
            written=$(grep -c '^PASS' "$log" 2>/dev/null)
            if [ "$status" -eq 0 ]; then
                pass shots "$(grep -m1 '^Totals:' "$log")"
            else
                fail shots "the shot runner exited $status"
                grep -aE '^(FAIL|QFATAL|QWARN)' "$log" | head -20 | sed 's/^/         /'
            fi
            grep -a 'title x,' "$log" | sed 's/^.*qml: /       /'
            reap_all
            guard_check shots
        fi
    fi
fi

# ── the store screenshots: the whole window, on invented data ───────────────

STORE_SHOTS=(home collection album nowplaying search)

if wanted store; then
    head2 "store screenshots, Main.qml on the invented library"

    if build_runner store; then
        # The 1280x800 window is drawn at 2x in the top half. The bottom half
        # is where a new X server parks its pointer, clear of anything hoverable.
        if ! start_xvfb 2600 3300; then
            skip store "no free X display between :90 and :99, or Xvfb never came up"
        else
            info "private display $DISP (pid $XVFB_PID) at 2600x3300"
            sandbox store
            log=$BOX/logs/store.log
            # Gone first, so a picture left by an earlier run cannot stand in
            # for one this run failed to write.
            for shot in "${STORE_SHOTS[@]}"; do rm -f "$OUT/store_$shot.png"; done
            # Twice the pixels, averaged back down when each shot is saved: at
            # 1x the app's hairline icon strokes come out broken.
            scale=2
            # Qt packs its glyph atlas in QSet order, which is random per
            # process unless the seed is pinned, and the text pixels follow it.
            seed=0
            env -i "${BOX_ENV[@]}" DISPLAY="$DISP" TW_SHOT_OUT="$OUT" \
                QT_SCALE_FACTOR=$scale QT_HASH_SEED=$seed \
                timeout -s TERM 300 "$HARNESS_BUILD/tst_shots" \
                -input "$SELF_DIR/store" >"$log" 2>&1
            status=$?
            missing=()
            for shot in "${STORE_SHOTS[@]}"; do
                [ -s "$OUT/store_$shot.png" ] || missing+=("store_$shot.png")
            done
            if [ "$status" -ne 0 ]; then
                fail store "the shot runner exited $status"
                grep -aE '^(FAIL|QFATAL|QWARN)' "$log" | head -20 | sed 's/^/         /'
            elif [ ${#missing[@]} -gt 0 ]; then
                fail store "not written: ${missing[*]}"
            else
                pass store "$(grep -m1 '^Totals:' "$log")"
            fi
            reap_all
            guard_check store
        fi
    fi
fi

# ── summary ─────────────────────────────────────────────────────────────────

head2 "summary"
printf '  %d passed, %d failed, %d skipped\n' \
       "${#PASSED[@]}" "${#FAILED[@]}" "${#SKIPPED[@]}"
shots_made=$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l)
printf '  %d PNGs in %s\n' "$shots_made" "$OUT"
[ ${#FAILED[@]} -eq 0 ] || exit 1
exit 0
