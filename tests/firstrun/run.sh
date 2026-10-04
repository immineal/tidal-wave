#!/usr/bin/env bash
#
# First-run simulation harness (HANDOFF section M).
#
# Starts the built binary the way a brand new install would see it - empty HOME,
# no settings file, no saved Tidal session, no cache, no window geometry - once
# per environment the app claims to support, and reports what each one printed.
#
# Usage
#   tests/firstrun/run.sh                 run every scenario this box can run
#   tests/firstrun/run.sh --list          list scenario ids and exit
#   tests/firstrun/run.sh offscreen xcb   run only the named scenarios
#   tests/firstrun/run.sh --keep          leave the sandbox behind for poking at
#   DWELL=15 tests/firstrun/run.sh        seconds to let each run live (default 8)
#   TIDALWAVE_BIN=/path/to/tidal-wave tests/firstrun/run.sh
#
# Exit status is 0 only if every scenario that ran passed. Skipped scenarios say
# why they were skipped and do not fail the run.
#
# Safety, because a real instance of this app is usually running on the dev box:
#
#   * Nothing here ever pkills, killalls or pattern-matches a process name. The
#     only processes killed are helpers this script started, by recorded pid.
#   * Every run gets its own HOME, TMPDIR, XDG_RUNTIME_DIR and XDG_*_HOME under a
#     private scratch directory, and is launched through `env -i` so no variable
#     from the caller's session leaks in.
#   * The single-instance lock is a QLocalServer bound to an absolute path:
#     $XDG_RUNTIME_DIR/TidalWave-<uid>, falling back to $TMPDIR and then /tmp.
#     XDG_RUNTIME_DIR is what isolates a run, with TMPDIR behind it, and the
#     sandbox sets both. tests/lib/socket-name.sh derives the address the way
#     Application::singleInstanceSocketName() does instead of this script
#     naming it a second time: the name it used to hardcode stopped matching
#     anything when the uid went into it, and nothing failed, it just stopped
#     seeing locks. Without the isolation a second launch connects to the
#     developer's own instance, tells it to show itself and exits 0, which
#     proves nothing and pops their window.
#   * A unix socket path is capped at 107 bytes, so the scratch root has to be
#     short or listen() fails and the lock silently never exists. The script
#     checks this and refuses to run rather than report a false pass.
#   * The developer's real ~/.config/TidalWave and their real lock are
#     fingerprinted up front and re-checked after every scenario. Any change
#     aborts the whole run.
#   * No synthetic input. Observation only: exit codes, stdout, stderr, window
#     properties and screenshots.
#   * Every launch runs under `timeout`, so nothing started here outlives the run.
#
set -u

# ── locations ───────────────────────────────────────────────────────────────

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
APP=${TIDALWAVE_BIN:-$REPO_ROOT/build-t/tidal-wave}
# The desktop entry, named once. Its basename is the app id rather than the
# binary name, because Flatpak exports only <app-id>.desktop; the binary and the
# icon are still tidal-wave. Every check below derives what it needs from this
# single path, so the next rename is one line here and not six.
DESKTOP_FILE=$REPO_ROOT/packaging/io.github.immineal.TidalWave.desktop
# TW_SOCKET_LEAF and tw_socket_path/tw_socket_live: the one place that knows
# where the single-instance lock lives, kept in step with src/ui/Application.cpp.
. "$REPO_ROOT/tests/lib/socket-name.sh"
DWELL=${DWELL:-8}
KEEP=0
WANTED=()

for arg in "$@"; do
    case $arg in
        --keep) KEEP=1 ;;
        --list)
            printf '%s\n' offscreen software xcb wayland offline no-tray \
                          bad-settings missing-qml single-instance \
                          desktop-file deps
            exit 0 ;;
        -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
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

PASSED=(); FAILED=(); SKIPPED=(); NOTES=()

head2()  { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass()   { PASSED+=("$1");  printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "${2:-$1}"; }
fail()   { FAILED+=("$1");  printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "${2:-$1}"; }
skip()   { SKIPPED+=("$1"); printf '  %sSKIP%s %s: %s\n' "$C_YEL" "$C_OFF" "$1" "$2"; }
note()   { NOTES+=("$1");   printf '  %snote%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
info()   { printf '       %s\n' "$1"; }

die() { printf '%sabort:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 2; }

# ── scratch root and cleanup ────────────────────────────────────────────────

[ -x "$APP" ] || die "no binary at $APP (build with: cmake --build build-t --parallel 8)"

# Deliberately short: see the sun_path note at the top.
SCRATCH=$(mktemp -d /tmp/twfr.XXXXXX) || die "cannot create a scratch directory"

# The longest address a run of ours can bind is $SCRATCH/<scenario>/run/<leaf>.
# 24 bytes is ample for the longest scenario name ("single-instance"), 5 covers
# "/run/". The limit stays short of sun_path's 107 rather than sitting on it,
# because a lock that never binds does not fail a run, it silently stops
# isolating it.
probe_len=${#SCRATCH}
probe_len=$(( probe_len + 24 + 5 + ${#TW_SOCKET_LEAF} ))
[ "$probe_len" -lt 100 ] || die "scratch path $SCRATCH is too long for a unix socket"

HELPER_PIDS=()
track()   { HELPER_PIDS+=("$1"); }
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

# ── guard: the developer's own config and lock must not move ────────────────

REAL_CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/TidalWave
# The developer's own lock, worked out the way the app works it out. On a normal
# session that is $XDG_RUNTIME_DIR/TidalWave-<uid>, i.e. /run/user/<uid>/..., and
# not the temp dir this script used to fingerprint instead.
REAL_LOCK=$(tw_socket_path "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}")

# Passive liveness probe. A bound unix socket shows up in /proc/net/unix, so this
# never signals, connects to, or even names a process. A developer's own running
# instance rewrites its settings file whenever the volume or the last page
# changes, so its contents drifting is expected and is not our doing.
#
# This used to grep for the old flat socket name, which nothing has bound since
# the uid went into it: it matched nothing, so the run believed no instance was
# live even with the developer's window open, and the tolerance below was never
# granted. Matching on the leaf also catches an instance that landed in $TMPDIR
# rather than $XDG_RUNTIME_DIR, and $SCRATCH is excluded so our own sandboxes
# can never be mistaken for it.
LIVE_INSTANCE=0
if tw_socket_live "$SCRATCH"; then
    LIVE_INSTANCE=1
fi

# Structure, not contents: the lock's identity, and the set of files that exist.
# A leak out of the sandbox would either replace the lock or create a file.
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
        printf 'The real lock or settings directory changed while %s ran.\n' "$1" >&2
        printf 'Restarting the app by hand mid-run does this too, and is harmless.\n' >&2
        printf 'Anything else means a sandbox leaked, so the run stops here either way.\n' >&2
        die "guard tripped during '$1'"
    fi
    local body; body=$(guard_contents)
    if [ "$body" != "$GUARD_BODY" ]; then
        if [ "$LIVE_INSTANCE" -eq 1 ]; then
            # Expected: the developer's own instance is running and saving state.
            # Our runs are killed by SIGTERM, so QSettings never syncs and they
            # write no settings file at all, not even inside their sandbox.
            GUARD_BODY=$body
        else
            die "scenario '$1' rewrote $REAL_CONF_DIR and no other instance is running"
        fi
    fi
}

head2 "sandbox"
info "binary:  $APP"
# A binary older than the sources makes every dynamic check below measure the
# previous build while saying nothing about this one. Not hypothetical: the
# Wayland app-id check was first run against a binary from before the entry was
# renamed, and it faithfully reported the old id.
STALE_SRC=$(find "$REPO_ROOT/src" "$REPO_ROOT/qml" -type f -newer "$APP" -print -quit 2>/dev/null)
if [ -n "$STALE_SRC" ]; then
    note "the binary predates ${STALE_SRC#"$REPO_ROOT/"}; rebuild, or every dynamic check measures the previous build"
fi
info "scratch: $SCRATCH (short on purpose: a unix socket path caps at 107 bytes)"
if [ "$LIVE_INSTANCE" -eq 1 ]; then
    info "another instance is already listening on $REAL_LOCK; it is left strictly alone."
    info "its settings file may change under us, which the guard tolerates but never causes."
else
    info "no other instance is listening; any write to the real settings would be a hard failure."
fi

# ── sandbox construction ────────────────────────────────────────────────────

BOX=''        # current sandbox dir
BOX_ENV=()    # current `env -i` argument list

sandbox() {
    BOX=$SCRATCH/$1
    rm -rf "$BOX"
    mkdir -p "$BOX/home/.config" "$BOX/home/.cache" "$BOX/home/.local/share" \
             "$BOX/home/.local/state" "$BOX/run" "$BOX/tmp" "$BOX/logs"
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

# Start a private session bus inside the sandbox. Needed by kwin_wayland; not
# used by the plain app scenarios, which are meant to survive without one.
private_bus() {
    local addr_file=$BOX/run/bus-address
    dbus-daemon --session --fork --print-address=3 --print-pid=4 \
        3>"$addr_file" 4>"$BOX/run/bus-pid" 2>/dev/null || return 1
    local pid; pid=$(cat "$BOX/run/bus-pid" 2>/dev/null)
    [ -n "$pid" ] || return 1
    track "$pid"
    PRIVATE_BUS=$(cat "$addr_file")
    return 0
}

# ── running the app ─────────────────────────────────────────────────────────

RUN_STATUS=0; RUN_OUT=''; RUN_ERR=''

# run_app <log-name> [extra VAR=VAL ...]
# Honours RUN_WRAPPER, an array prefixed to the command line (unshare, kwin, ...).
run_app() {
    local name=$1; shift
    RUN_OUT=$BOX/logs/$name.out
    RUN_ERR=$BOX/logs/$name.err
    env -i "${BOX_ENV[@]}" "$@" \
        ${RUN_WRAPPER[@]+"${RUN_WRAPPER[@]}"} \
        timeout -s TERM "$DWELL" "$APP" >"$RUN_OUT" 2>"$RUN_ERR"
    RUN_STATUS=$?
    return 0
}

# Noise that says something about the box, not about the app, and that a real
# first-run user on a normal desktop would not see. Reported, never failed on.
BENIGN='pipewire|PulseAudioService|pa_context|ALSA|snd_pcm|snd_lib|Detected locale|[Ff]ontconfig|libEGL|libGL|MESA|swrast|DRI[0-9]|Could not connect to any X display|session bus|D-Bus|dbus|Failed to create wl_display|XDG_RUNTIME_DIR|Icon theme|QStandardPaths|xkbcommon|Wayland does not support'

# Anything here means the app is broken for a first-run user.
FATAL='QQmlApplicationEngine failed to load component|is not installed|is not a type|Invalid image provider|ReferenceError|TypeError|Cannot assign|Unable to assign|Cannot read propert|ASSERT|Segmentation fault|SIGSEGV|failed to start because|Could not (load|find) the Qt platform plugin|QQmlComponent: Component is not ready|Binding loop'

qml_errors() { grep -aEn "$FATAL" "$RUN_ERR" "$RUN_OUT" 2>/dev/null; }
other_noise() { grep -avE "$BENIGN" "$RUN_ERR" 2>/dev/null | grep -av '^[[:space:]]*$'; }

# Shared verdict for "the app has to come up and stay up".
# verdict <id> <human label>
verdict() {
    local id=$1 label=$2 bad ok=1

    case $RUN_STATUS in
        124) : ;;  # killed by our own timeout, which is what staying up looks like
        0)   fail "$id" "$label: exited 0 straight away - the sandbox leaked and it found another instance"
             ok=0 ;;
        139) fail "$id" "$label: segfault (exit 139)"; ok=0 ;;
        255) fail "$id" "$label: engine refused to load a root object (exit 255 / -1)"; ok=0 ;;
        *)   fail "$id" "$label: exited $RUN_STATUS before the timeout"; ok=0 ;;
    esac

    bad=$(qml_errors)
    if [ -n "$bad" ]; then
        [ "$ok" -eq 1 ] && { fail "$id" "$label: stayed up but logged QML or plugin errors"; ok=0; }
        printf '%s\n' "$bad" | sed 's/^/         /'
    fi

    if [ "$ok" -eq 1 ]; then
        pass "$id" "$label: stayed up ${DWELL}s, no QML or plugin errors"
    fi

    local noise; noise=$(other_noise)
    [ -n "$noise" ] && { info "unclassified stderr:"; printf '%s\n' "$noise" | sed 's/^/         /'; }

    # Every first run writes the hicolor icon export; if it did not, the tray and
    # the taskbar have nothing to resolve "tidal-wave" against.
    if [ -f "$BOX/home/.local/share/icons/hicolor/128x128/apps/tidal-wave.png" ]; then
        info "icon export: ok (\$XDG_DATA_HOME/icons/hicolor/*/apps/tidal-wave.png)"
    else
        note "$id: no icon written to \$XDG_DATA_HOME/icons/hicolor - the named icon will not resolve"
    fi

    guard_check "$id"
}

# ── the .deb depends list, read once ────────────────────────────────────────
#
# Read the assembled list, not the code that assembles it.
#
# The deps scenario used to grep CMakeLists.txt for
# `set(CPACK_DEBIAN_PACKAGE_DEPENDS`, a string CMakeLists.txt does not contain
# and never did: the list is built up a package at a time into TW_DEB_DEPENDS,
# with a version floor appended to each, and only then
#     list(JOIN TW_DEB_DEPENDS ", " CPACK_DEBIAN_PACKAGE_DEPENDS)
# So the pattern could not match, the list was always empty, and that scenario
# took its skip branch on every run it has ever had - green by vacuity for its
# whole life, while reporting itself as merely unavailable.
#
# The generated CPackConfig.cmake beside the binary is the assembled value: it is
# what CPack writes into the control file, version constraints and all. Reading
# it keeps the package list in one place instead of making this file a second
# copy that drifts.
CPACK_CFG=$(dirname "$APP")/CPackConfig.cmake
cpack_var() {
    sed -n "s/^set(${1} \"\(.*\)\")[[:space:]]*\$/\1/p" "$CPACK_CFG" | head -1
}
DEB_DEPENDS=''; DEB_RECOMMENDS=''
if [ -f "$CPACK_CFG" ]; then
    DEB_DEPENDS=$(cpack_var CPACK_DEBIAN_PACKAGE_DEPENDS)
    DEB_RECOMMENDS=$(cpack_var CPACK_DEBIAN_PACKAGE_RECOMMENDS)
fi
# Package names only, with the "(>= 6.12)" stripped off: comparing whole entries
# would miss every versioned one, and substring matching would let
# "qml6-module-qtquick" pretend to satisfy "qml6-module-qtquick-shapes".
dep_names() {
    printf '%s' "$1" | tr ',' '\n' | sed 's/(.*//' \
        | tr -d '[:blank:]' | grep -v '^$'
}
listed()      { dep_names "$DEB_DEPENDS"    | grep -qxF -- "$1"; }
recommended() { dep_names "$DEB_RECOMMENDS" | grep -qxF -- "$1"; }

# ── scenario 1: offscreen, the CI shape and the baseline ────────────────────

if wanted offscreen; then
    head2 "offscreen (CI baseline)"
    sandbox offscreen
    RUN_WRAPPER=()
    run_app offscreen QT_QPA_PLATFORM=offscreen
    verdict offscreen "offscreen"
fi

# ── scenario 2: software scene graph, the no-GPU path ───────────────────────

if wanted software; then
    head2 "software scene graph (no GPU)"
    sandbox software
    RUN_WRAPPER=()
    run_app software QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
    verdict software "QT_QUICK_BACKEND=software"
fi

# ── scenario 3: X11 on a private Xvfb, so no window of the developer's moves ─

pick_display() {
    local n
    for n in $(seq 90 99); do
        [ -e "/tmp/.X11-unix/X$n" ] || { echo ":$n"; return 0; }
    done
    return 1
}

if wanted xcb; then
    head2 "X11 / xcb"
    if ! command -v Xvfb >/dev/null 2>&1; then
        skip xcb "Xvfb is not installed, and running on the real display would touch the developer's session"
    elif ! DISP=$(pick_display); then
        skip xcb "no free X display between :90 and :99"
    else
        sandbox xcb
        Xvfb "$DISP" -screen 0 1280x800x24 -nolisten tcp >"$BOX/logs/xvfb.log" 2>&1 &
        XVFB_PID=$!; track "$XVFB_PID"
        ready=0
        for _ in $(seq 1 40); do
            [ -e "/tmp/.X11-unix/X${DISP#:}" ] && { ready=1; break; }
            sleep 0.25
        done
        if [ "$ready" -eq 0 ]; then
            skip xcb "Xvfb never came up on $DISP"
        else
            info "private display $DISP (pid $XVFB_PID), nothing on the real session is touched"
            RUN_WRAPPER=()
            # Backgrounded so the window can be inspected while it is mapped.
            ( env -i "${BOX_ENV[@]}" DISPLAY="$DISP" QT_QPA_PLATFORM=xcb \
                timeout -s TERM "$DWELL" "$APP" \
                >"$BOX/logs/xcb.out" 2>"$BOX/logs/xcb.err" ) &
            APP_JOB=$!
            sleep $(( DWELL > 5 ? 4 : 2 ))

            # Qt also maps a 1x1 helper and a 3x3 selection-owner window, so
            # take the child with the largest area rather than the first listed.
            WIN=$(DISPLAY="$DISP" xwininfo -root -children 2>/dev/null \
                  | awk '/^ *0x[0-9a-f]+ / {
                             geo = ""
                             for (i = 1; i <= NF; i++)
                                 if ($i ~ /^[0-9]+x[0-9]+\+-?[0-9]+\+-?[0-9]+$/) { geo = $i; break }
                             if (geo == "") next
                             split(geo, g, /[x+]/)
                             print g[1] * g[2], $0
                         }' \
                  | sort -rn | head -1 | cut -d" " -f2-)
            if [ -n "$WIN" ]; then
                info "mapped window: $(echo "$WIN" | sed 's/^ *//')"
                WID=$(echo "$WIN" | awk '{print $1}')
                CLASS=$(DISPLAY="$DISP" xprop -id "$WID" WM_CLASS 2>/dev/null)
                NAME=$(DISPLAY="$DISP" xprop -id "$WID" _NET_WM_NAME 2>/dev/null)
                ICON=$(DISPLAY="$DISP" xprop -id "$WID" _NET_WM_ICON 2>/dev/null | head -c 80)
                info "$CLASS"
                info "$NAME"
                if echo "$ICON" | grep -q 'CARDINAL'; then
                    info "_NET_WM_ICON: present (the taskbar icon resolves on X11)"
                else
                    note "xcb: no _NET_WM_ICON on the window"
                fi
                # The two X11 ways a window is tied back to its launcher entry,
                # which use two different names and are both easy to get wrong.
                #
                # 1. StartupWMClass has to appear in WM_CLASS. WM_CLASS here is
                #    "tidal-wave", "Tidal Wave": Qt's xcb plugin builds the
                #    instance half from the argv[0] basename (or $RESOURCE_NAME)
                #    and the class half from applicationName(). It never reads
                #    desktopFileName() for this, so StartupWMClass tracks the
                #    *binary* name and must not be moved to the app id.
                DESK_WMCLASS=$(grep -m1 '^StartupWMClass=' \
                               "$DESKTOP_FILE" 2>/dev/null | cut -d= -f2-)
                if [ -z "$DESK_WMCLASS" ]; then
                    note "xcb: the entry has no StartupWMClass line"
                elif echo "$CLASS" | grep -qi "\"$DESK_WMCLASS\""; then
                    info "StartupWMClass=$DESK_WMCLASS appears in $(echo "$CLASS" | sed 's/^WM_CLASS[^=]*= //')"
                else
                    note "xcb: StartupWMClass=$DESK_WMCLASS does not appear in $CLASS"
                fi
                # 2. _KDE_NET_WM_DESKTOP_FILE is where desktopFileName() lands on
                #    X11, and it is how Plasma matches a window to its entry
                #    without going through WM_CLASS at all. This one *does* carry
                #    the app id, so it is the property the rename moved and the
                #    one that catches setDesktopFileName() drifting from the
                #    entry's basename on X11 the way the wayland-appid check does
                #    on Wayland.
                DESK_BASE=$(basename "$DESKTOP_FILE" .desktop)
                KDEPROP=$(DISPLAY="$DISP" xprop -id "$WID" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)
                if echo "$KDEPROP" | grep -q "\"$DESK_BASE\""; then
                    info "_KDE_NET_WM_DESKTOP_FILE is $DESK_BASE, so Plasma resolves the entry on X11 too"
                else
                    note "xcb: _KDE_NET_WM_DESKTOP_FILE is not \"$DESK_BASE\" ($KDEPROP)"
                fi
                if command -v import >/dev/null 2>&1; then
                    SHOT=$BOX/logs/xcb.png
                    import -display "$DISP" -window root "$SHOT" 2>/dev/null
                    if [ -s "$SHOT" ] && command -v convert >/dev/null 2>&1; then
                        TOP=$(convert "$SHOT" -format %c -depth 8 histogram:info:- 2>/dev/null \
                              | sort -rn | head -1)
                        info "screenshot at $SHOT"
                        info "dominant colour: $(echo "$TOP" | sed 's/^ *//')"
                        # The default theme is "sea": #0A0A0A page background.
                        if echo "$TOP" | grep -qi '#0A0A0A'; then
                            info "default theme: sea background painted (#0A0A0A)"
                        else
                            note "xcb: the dominant colour is not the sea background #0A0A0A"
                        fi
                        NCOL=$(convert "$SHOT" -format %k info: 2>/dev/null)
                        if [ -n "$NCOL" ] && [ "$NCOL" -lt 8 ] 2>/dev/null; then
                            note "xcb: only $NCOL distinct colours on screen - the window may be blank"
                        else
                            info "distinct colours: $NCOL (content was actually drawn)"
                        fi
                    fi
                fi
            else
                note "xcb: no client window was mapped on $DISP"
            fi

            wait "$APP_JOB"; RUN_STATUS=$?
            RUN_OUT=$BOX/logs/xcb.out; RUN_ERR=$BOX/logs/xcb.err
            verdict xcb "xcb on $DISP"
        fi
        reap_all
    fi
fi

# ── scenario 4: Wayland, nested in a headless compositor ────────────────────
#
# Why both of these used to fail, because the cause is nowhere near the symptom
# and it leaves no log line to find.
#
#   kwin_wayland is installed with the file capability cap_sys_nice=ep, and
#   KWin::gainRealTime() moves its main thread onto SCHED_RR the moment it has
#   it. A real-time thread is then subject to RLIMIT_RTTIME, and the kernel's
#   remedy for exceeding that is SIGXCPU at the soft limit and SIGKILL at the
#   hard one. Software-rendering the virtual backend's first frames spends a
#   200ms budget in one uninterrupted go, so the compositor was SIGKILLed about
#   a second after binding its socket, having written nothing at all - SIGKILL
#   leaves no opportunity to write. The app then connected to a socket with
#   nobody behind it, found no xdg-shell global and aborted with 134. That was
#   the pair of FAILs, and neither of them was about the app.
#
#   Whose limit it is matters, because it decides who sees the failure. Plasma
#   starts its own compositor with RLIMIT_RTTIME=infinity and so does a plain
#   terminal, so running this by hand on the developer's box never hit it. A
#   harness that lowers RLIMIT_RTTIME for itself hands the lowered value to
#   every child, and this script was failing under exactly that: measured at
#   200000us inherited, with the terminal above it still at infinity. A
#   container or service manager with a finite DefaultLimitRTTIME does the same.
#   The run prints the value it inherited so the next reader does not have to
#   work it out again.
#
#   setpriv --no-new-privs is the whole fix. PR_SET_NO_NEW_PRIVS makes the exec
#   refuse to pick the capability up, so sched_setscheduler() is denied by
#   RLIMIT_RTPRIO, KWin stays on SCHED_OTHER, and RLIMIT_RTTIME never applies to
#   it at all - no matter what was inherited. What that gives up is real-time
#   scheduling for the compositor, which a test reading protocol traffic rather
#   than frame timing does not need. It is otherwise the KWin the owner runs:
#   same xdg-shell implementation, same app-id matching, so this is not a
#   weaker stand-in for the real compositor.
#
#   The readiness check used to wait for the socket file and nothing else. The
#   socket is bound about a second before any global is advertised, and it stays
#   on disk after the compositor is killed, so that check could be satisfied
#   with nothing on the other end - which is how a dead compositor came out as a
#   broken app. It now waits until xdg_wm_base is really advertised, and the
#   compositor's life is re-checked at every verdict.
#
# Nothing here goes near the developer's session: the compositor renders to an
# offscreen framebuffer, binds its own socket inside the sandbox's own
# XDG_RUNTIME_DIR, and talks to the sandbox's own session bus. That is also why
# the old "this box is not running a Wayland session" precondition is gone:
# --virtual needs no parent display of any kind, so requiring one only made the
# scenario skip on the X11 and headless boxes where it would have run fine.

if wanted wayland; then
    head2 "Wayland"
    sandbox wayland
    WANT=$(basename "$DESKTOP_FILE" .desktop)

    # Report the compositor-dependent checks as skipped by name rather than
    # letting them disappear from the tally, which is how a check stops being
    # noticed at all.
    wl_skip_dynamic() {
        skip wayland "$1"; skip wayland-surface "$1"; skip wayland-appid "$1"
    }

    # ── wayland-entry: the id on the wire has to name the entry that is really
    # installed, so run the install rules into a throwaway DESTDIR and resolve
    # the id against that tree the way a compositor resolves it - not against
    # packaging/, which is not what reaches a user's disk. Static, so it runs
    # even where there is no compositor to nest.
    BUILD_DIR=$(dirname "$APP")
    STAGE=$BOX/stage
    if ! command -v cmake >/dev/null 2>&1; then
        skip wayland-entry "cmake is not installed, so the install rules cannot be run"
    elif [ ! -f "$BUILD_DIR/cmake_install.cmake" ]; then
        skip wayland-entry "$BUILD_DIR is not a configured CMake build directory"
    elif ! DESTDIR=$STAGE cmake --install "$BUILD_DIR" --prefix /usr \
              >"$BOX/logs/stage-install.log" 2>&1; then
        # Worth failing rather than skipping: a build directory whose install
        # rules predate a rename still names the file that used to exist, and
        # `cpack` out of that directory would package the old layout or nothing.
        # Re-configuring it is the fix.
        fail wayland-entry "cmake --install into a staging tree failed; ${BUILD_DIR#"$REPO_ROOT/"}'s install rules may predate the sources, so re-configure it"
        tail -6 "$BOX/logs/stage-install.log" 2>/dev/null | sed 's/^/         /'
    else
        ok=1
        APPDIR=$(find "$STAGE" -type d -name applications -print -quit 2>/dev/null)
        ENTRY=$APPDIR/$WANT.desktop
        if [ -z "$APPDIR" ]; then
            fail wayland-entry "the install rules create no applications directory, so the app id resolves to nothing"
            ok=0
        elif [ ! -f "$ENTRY" ]; then
            fail wayland-entry "nothing installs $WANT.desktop, so an app id of $WANT resolves to nothing"
            info "installed instead: $(ls "$APPDIR" 2>/dev/null | tr '\n' ' ')"
            ok=0
        else
            info "app id $WANT resolves to ${ENTRY#"$STAGE"}"
            # One entry only. Two would put the app in the launcher twice and
            # leave which one the compositor matches to chance; the legacy sweep
            # in CMakeLists.txt exists for exactly that.
            NENTRY=$(find "$APPDIR" -maxdepth 1 -name '*.desktop' | wc -l)
            if [ "$NENTRY" -ne 1 ]; then
                fail wayland-entry "$NENTRY desktop entries are installed; the app id may resolve to either"
                info "$(find "$APPDIR" -maxdepth 1 -name '*.desktop' -printf '%f ' 2>/dev/null)"
                ok=0
            fi
            # The file that is checked statically elsewhere in this script has to
            # be the file that is installed, or those checks measure nothing.
            if ! cmp -s "$ENTRY" "$DESKTOP_FILE"; then
                fail wayland-entry "the installed entry differs from ${DESKTOP_FILE#"$REPO_ROOT/"}, which is what the other checks read"
                ok=0
            fi
            # Last link of the icon chain: KWin takes Icon= out of the entry it
            # matched and looks that up as a theme icon name.
            EICON=$(grep -m1 '^Icon=' "$ENTRY" | cut -d= -f2-)
            if [ -z "$EICON" ]; then
                fail wayland-entry "the installed entry has no Icon= line, so the matched window has no icon to show"
                ok=0
            else
                FOUND=$(find "$STAGE" -path '*/icons/hicolor/*/apps/*' \
                        \( -name "$EICON.png" -o -name "$EICON.svg" \) -print 2>/dev/null)
                if [ -z "$FOUND" ]; then
                    fail wayland-entry "Icon=$EICON names no installed hicolor icon, so KWin matches the entry and still shows nothing"
                    ok=0
                else
                    info "Icon=$EICON resolves to $(printf '%s\n' "$FOUND" | grep -c .) installed hicolor file(s)"
                fi
            fi
            # AppStream is the third speller of the app id, and the one a store
            # listing hangs off.
            MINFO=$(find "$STAGE" -path '*/metainfo/*.xml' -print -quit 2>/dev/null)
            if [ -z "$MINFO" ]; then
                note "wayland-entry: no metainfo file is installed"
            else
                [ "$(basename "$MINFO")" = "$WANT.metainfo.xml" ] \
                    || { fail wayland-entry "the metainfo installs as $(basename "$MINFO"), not $WANT.metainfo.xml, so AppStream pairs it with no component"; ok=0; }
                LAUNCH=$(grep -o '<launchable[^>]*>[^<]*</launchable>' "$MINFO" \
                         | sed 's/.*>\(.*\)<.*/\1/' | head -1)
                if [ "$LAUNCH" = "$WANT.desktop" ]; then
                    info "metainfo <launchable> is $LAUNCH"
                else
                    fail wayland-entry "metainfo <launchable> is \"$LAUNCH\", not $WANT.desktop"
                    ok=0
                fi
            fi
        fi
        [ "$ok" -eq 1 ] && pass wayland-entry "the app id resolves to the installed entry, and its icon and metainfo resolve with it"
    fi

    # ── the nested compositor, and what the app does under it ───────────────
    if ! command -v kwin_wayland >/dev/null 2>&1; then
        wl_skip_dynamic "no nested compositor available (kwin_wayland), and the real session must not be used"
    elif ! command -v dbus-daemon >/dev/null 2>&1; then
        wl_skip_dynamic "kwin_wayland needs a session bus and dbus-daemon is not installed"
    else
        PRIVATE_BUS=''
        if ! private_bus; then
            wl_skip_dynamic "could not start a private session bus"
        else
            WD=wayland-twfr
            KWIN_WRAP=(); HOW='no capability guard'
            if command -v setpriv >/dev/null 2>&1; then
                KWIN_WRAP=(setpriv --no-new-privs); HOW='PR_SET_NO_NEW_PRIVS'
            else
                note "wayland: setpriv is missing, so the compositor may take SCHED_RR; a SIGKILL below is RLIMIT_RTTIME"
            fi
            RTTIME=$(awk '/realtime timeout/ {print $4}' /proc/self/limits 2>/dev/null)
            info "nested kwin_wayland on a virtual framebuffer, socket $WD, private bus"
            info "started with $HOW; inherited RLIMIT_RTTIME is ${RTTIME:-unknown}"
            # --virtual renders to an offscreen framebuffer, so nothing appears on
            # the developer's screen and no focus is taken.
            env -i "${BOX_ENV[@]}" DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" \
                QT_QPA_PLATFORM=offscreen \
                ${KWIN_WRAP[@]+"${KWIN_WRAP[@]}"} \
                kwin_wayland --virtual --width 1280 --height 800 \
                             --no-lockscreen --no-global-shortcuts --socket "$WD" \
                >"$BOX/logs/kwin.log" 2>&1 &
            KWIN_PID=$!; track "$KWIN_PID"

            # Readiness is "the shell global the app will ask for is advertised",
            # not "the socket file exists".
            HAVE_WL_INFO=0; READY_BY='the socket plus a settle, unverified'
            command -v wayland-info >/dev/null 2>&1 && \
                { HAVE_WL_INFO=1; READY_BY='xdg_wm_base, asked for with wayland-info'; }
            ready=0
            for _ in $(seq 1 120); do
                if [ -S "$BOX/run/$WD" ]; then
                    if [ "$HAVE_WL_INFO" -eq 1 ]; then
                        env -i "${BOX_ENV[@]}" WAYLAND_DISPLAY="$WD" wayland-info \
                            2>/dev/null | grep -q "'xdg_wm_base'" && { ready=1; break; }
                    else
                        # Nothing installed to ask the compositor with; give it
                        # time to finish binding globals instead.
                        sleep 2; ready=1; break
                    fi
                fi
                kill -0 "$KWIN_PID" 2>/dev/null || break
                sleep 0.25
            done
            kill -0 "$KWIN_PID" 2>/dev/null || ready=0

            if [ "$ready" -eq 0 ]; then
                if kill -0 "$KWIN_PID" 2>/dev/null; then
                    wl_skip_dynamic "kwin_wayland never advertised xdg_wm_base on $WD"
                else
                    wait "$KWIN_PID" 2>/dev/null; KST=$?
                    wl_skip_dynamic "the nested kwin_wayland died (status $KST) before it served xdg_wm_base"
                    [ "$KST" = 137 ] && info "137 is SIGKILL: RLIMIT_RTTIME=${RTTIME:-unknown} against KWin's SCHED_RR thread, see the note above this scenario"
                fi
                KLOG=$(tail -3 "$BOX/logs/kwin.log" 2>/dev/null)
                if [ -n "$KLOG" ]; then
                    printf '%s\n' "$KLOG" | sed 's/^/       /'
                else
                    info "kwin.log is empty: KWin logs to the journal, and a SIGKILLed process gets no chance to write either way"
                fi
            else
                info "compositor ready by: $READY_BY"
                RUN_WRAPPER=()
                run_app wayland WAYLAND_DISPLAY="$WD" QT_QPA_PLATFORM=wayland \
                        DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" \
                        XDG_CURRENT_DESKTOP=KDE
                if kill -0 "$KWIN_PID" 2>/dev/null; then
                    verdict wayland "wayland (nested kwin)"
                else
                    fail wayland "the nested compositor died mid-run, so nothing was measured about the app"
                fi

                # A second launch, this time with the protocol traffic printed,
                # so what the app told the compositor can be read instead of
                # assumed. WAYLAND_DEBUG goes to stderr and would drown the
                # verdict's own greps, hence the separate run.
                env -i "${BOX_ENV[@]}" WAYLAND_DISPLAY="$WD" QT_QPA_PLATFORM=wayland \
                    DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" XDG_CURRENT_DESKTOP=KDE \
                    WAYLAND_DEBUG=1 \
                    timeout -s TERM 6 "$APP" \
                    >"$BOX/logs/wl-debug.out" 2>"$BOX/logs/wl-debug.err"
                WLOG=$BOX/logs/wl-debug.err

                # Did a window actually reach the screen? Three things have to be
                # true, and only the middle one needs the compositor to answer:
                # the app asked for a toplevel, the compositor configured it with
                # a real size (an event, so it has no "->" prefix: proof there is
                # a compositor and not just a socket), and the app then attached
                # a buffer and committed it, which is a drawn frame.
                TOPLEVEL=$(grep -aoE 'xdg_surface#[0-9]+\.get_toplevel' "$WLOG" | head -1)
                CONFSZ=$(grep -a 'xdg_toplevel#' "$WLOG" | grep -av -- '->' \
                         | grep -aoE '\.configure\([1-9][0-9]*, [1-9][0-9]*,' | head -1)
                ATTACH=$(grep -aoE 'wl_surface#[0-9]+\.attach\(wl_buffer#[0-9]+' "$WLOG" | head -1)
                COMMIT=$(grep -aoE 'wl_surface#[0-9]+\.commit\(\)' "$WLOG" | head -1)
                ok=1
                if [ -z "$TOPLEVEL" ]; then
                    fail wayland-surface "no xdg_toplevel was ever created; no window reached the compositor"
                    ok=0
                elif [ -z "$CONFSZ" ]; then
                    fail wayland-surface "the compositor never configured the toplevel with a size; it was created but never mapped"
                    ok=0
                elif [ -z "$ATTACH" ] || [ -z "$COMMIT" ]; then
                    fail wayland-surface "no buffer was attached and committed; the surface exists but drew nothing"
                    ok=0
                fi
                if [ "$ok" -eq 1 ]; then
                    SZ=$(printf '%s' "$CONFSZ" | sed 's/\.configure(\([0-9]*\), \([0-9]*\),/\1x\2/')
                    pass wayland-surface "a toplevel was mapped at $SZ and a buffer was attached and committed"
                fi

                # On Wayland the taskbar entry and the icon come from the
                # .desktop file matched against xdg_toplevel.set_app_id, never
                # from setWindowIcon. This is the id on the wire; wayland-entry
                # above is the other end of the same chain.
                APPID=$(grep -aoE 'xdg_toplevel#[0-9]+\.set_app_id\("[^"]*"\)' \
                        "$WLOG" | head -1 | sed 's/.*("\(.*\)").*/\1/')
                if [ -z "$APPID" ]; then
                    fail wayland-appid "no app id was set on the toplevel, so KWin has no entry to match and the taskbar icon is generic"
                elif [ "$APPID" = "$WANT" ]; then
                    pass wayland-appid "set_app_id(\"$APPID\") is the installed entry's basename, so KWin resolves $WANT.desktop"
                    info "set_title: $(grep -aoE 'set_title\("[^"]*"\)' "$WLOG" | head -1)"
                else
                    fail wayland-appid "set_app_id(\"$APPID\") is not \"$WANT\"; KWin finds no $WANT.desktop and the taskbar shows a generic icon"
                fi
                guard_check wayland-appid
            fi
        fi
        reap_all
    fi
fi

# ── scenario 5: no network at all ───────────────────────────────────────────

if wanted offline; then
    head2 "no network"
    if unshare -rn true 2>/dev/null; then
        sandbox offline
        # A private network namespace with loopback down: DNS and every connect
        # fail immediately, exactly like a machine with the cable out. It needs
        # no root and touches no system configuration.
        RUN_WRAPPER=(unshare --user --map-root-user --net --)
        run_app offline QT_QPA_PLATFORM=offscreen
        verdict offline "offline (private netns)"
        if [ "$RUN_STATUS" = 124 ]; then
            info "did not hang on a dead network; it was still running when the timeout fired"
        fi
    else
        skip offline "unprivileged network namespaces are unavailable, and the app ignores http_proxy (it never calls QNetworkProxyFactory::setUseSystemConfiguration), so a proxy-based simulation would prove nothing"
    fi
fi

# ── scenario 6: no system tray ──────────────────────────────────────────────

if wanted no-tray; then
    head2 "no system tray"
    sandbox no-tray
    RUN_WRAPPER=()
    # No XDG_CURRENT_DESKTOP, no session bus, so there is no StatusNotifier host
    # and QSystemTrayIcon::isSystemTrayAvailable() is false.
    run_app no-tray QT_QPA_PLATFORM=offscreen
    verdict no-tray "no tray, no session bus"
    info "note: the window is 'visible: true' in Main.qml, so it still appears;"
    info "closing it calls root.hide() and only a relaunch brings it back."
fi

# ── scenario 7: a corrupt settings file from a future version ───────────────

if wanted bad-settings; then
    head2 "corrupt / future settings file"
    sandbox bad-settings
    CONF_DIR=$BOX/home/.config/TidalWave
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/Tidal Wave.conf" <<'CONF'
[ui]
theme=chartreuse-from-2027
language=klingon
sidebarWidth=999999
softwareRendering=maybe

[audio]
outputDevice=

[General]
this line has no equals sign at all
[unterminated section
binaryJunk=@ByteArray(\x00\x01\x02\xff)
CONF
    RUN_WRAPPER=()
    run_app bad-settings QT_QPA_PLATFORM=offscreen
    verdict bad-settings "corrupt settings"
    info "stored sidebarWidth=999999 must clamp to Prefs::maxSidebarWidth (420);"
    info "an unknown theme name must still resolve to a paintable palette."
fi

# ── scenario 8: a QML module the package forgot to depend on ────────────────

if wanted missing-qml; then
    head2 "missing QML module (QtQuick.Shapes)"
    # Located from the linked Qt, never by running the binary: an unsandboxed
    # launch would find the developer's instance through the lock in /tmp and
    # pop their window.
    QT_LIBDIR=$(dirname "$(ldd "$APP" | awk '/libQt6Quick\.so/ {print $3}')")
    SHAPES_DIR=$(cd "$QT_LIBDIR/../qml/QtQuick/Shapes" 2>/dev/null && pwd)
    if [ -z "$SHAPES_DIR" ]; then
        skip missing-qml "could not locate the QtQuick/Shapes module directory"
    elif ! unshare -rm true 2>/dev/null; then
        skip missing-qml "unprivileged mount namespaces are unavailable, so the module cannot be hidden"
    else
        sandbox missing-qml
        mkdir -p "$BOX/empty"
        info "hiding $SHAPES_DIR inside a private mount namespace"
        env -i "${BOX_ENV[@]}" QT_QPA_PLATFORM=offscreen \
            SHAPES_DIR="$SHAPES_DIR" EMPTY="$BOX/empty" APPBIN="$APP" DW="$DWELL" \
            unshare --user --map-root-user --mount --propagation private -- \
            sh -c 'mount --bind "$EMPTY" "$SHAPES_DIR" && exec timeout -s TERM "$DW" "$APPBIN"' \
            >"$BOX/logs/missing-qml.out" 2>"$BOX/logs/missing-qml.err"
        RUN_STATUS=$?
        RUN_OUT=$BOX/logs/missing-qml.out; RUN_ERR=$BOX/logs/missing-qml.err
        # This one is expected to break: the point is to show what a user who
        # installed the .deb without qml6-module-qtquick-shapes actually sees.
        if grep -aqE 'QtQuick.Shapes.*is not installed|failed to load component' "$RUN_ERR"; then
            pass missing-qml "reproduced the packaging failure a missing QtQuick.Shapes causes (exit $RUN_STATUS)"
            head -6 "$RUN_ERR" | sed 's/^/         /'
            # This note used to be an unconditional sentence claiming the
            # package was missing from the depends list. It was not missing, so
            # the claim was false on every run that ever printed it; the list is
            # right there to ask.
            if listed qml6-module-qtquick-shapes; then
                info "qml6-module-qtquick-shapes is in the depends list, so a .deb install does not land here"
            else
                note "qml6-module-qtquick-shapes is not in the depends list, so this is what a .deb user sees"
            fi
        elif [ "$RUN_STATUS" = 124 ]; then
            pass missing-qml "survived without QtQuick.Shapes (the module is optional after all)"
        else
            fail missing-qml "hiding QtQuick.Shapes gave exit $RUN_STATUS with no clear message"
            head -6 "$RUN_ERR" | sed 's/^/         /'
        fi
        guard_check missing-qml
    fi
fi

# ── scenario 9: the single-instance lock, inside the sandbox ────────────────

if wanted single-instance; then
    head2 "single-instance lock"
    sandbox single-instance
    # Where this launch will bind, given the sandbox's own environment. The
    # sandbox sets XDG_RUNTIME_DIR as well as TMPDIR, and XDG_RUNTIME_DIR is the
    # app's first choice, so the lock appears in $BOX/run. $BOX/tmp is where this
    # check used to look, which no build has used since the directory became
    # explicit, and a missing lock here reads as a hard failure.
    BOX_LOCK=$(tw_socket_path "$BOX/run" "$BOX/tmp")
    RUN_WRAPPER=()
    ( env -i "${BOX_ENV[@]}" QT_QPA_PLATFORM=offscreen \
        timeout -s TERM "$DWELL" "$APP" \
        >"$BOX/logs/first.out" 2>"$BOX/logs/first.err" ) &
    FIRST=$!
    sock_ok=0
    for _ in $(seq 1 40); do
        [ -S "$BOX_LOCK" ] && { sock_ok=1; break; }
        sleep 0.25
    done
    if [ "$sock_ok" -eq 1 ]; then
        info "lock created at \$XDG_RUNTIME_DIR/$TW_SOCKET_LEAF (inside the sandbox, not in the real /run/user)"
    else
        fail single-instance "the first instance never created $BOX_LOCK; listen() failed and the app said nothing"
    fi
    env -i "${BOX_ENV[@]}" QT_QPA_PLATFORM=offscreen \
        timeout -s TERM "$DWELL" "$APP" \
        >"$BOX/logs/second.out" 2>"$BOX/logs/second.err"
    SECOND=$?
    wait "$FIRST" >/dev/null 2>&1
    if [ "$sock_ok" -eq 1 ]; then
        if [ "$SECOND" = 0 ]; then
            pass single-instance "a second launch handed off to the first and exited 0"
        else
            fail single-instance "a second launch exited $SECOND instead of handing off"
        fi
    fi
    guard_check single-instance
fi

# ── static check: the desktop entry ─────────────────────────────────────────

if wanted desktop-file; then
    head2 "desktop entry and icon name"
    DESKTOP=$DESKTOP_FILE
    if [ ! -f "$DESKTOP" ]; then
        fail desktop-file "${DESKTOP#"$REPO_ROOT/"} is missing"
    else
        ok=1
        if command -v desktop-file-validate >/dev/null 2>&1; then
            OUT=$(desktop-file-validate "$DESKTOP" 2>&1)
            if [ -n "$OUT" ]; then
                fail desktop-file "desktop-file-validate complained"
                printf '%s\n' "$OUT" | sed 's/^/         /'
                ok=0
            else
                info "desktop-file-validate: clean"
            fi
        else
            info "desktop-file-validate not installed, skipping validation"
        fi
        # setDesktopFileName has to match the installed basename, or Wayland
        # cannot match the window to the launcher entry and the icon is generic.
        SET_NAME=$(grep -o 'setDesktopFileName("[^"]*")' "$REPO_ROOT/src/ui/Application.cpp" \
                   | head -1 | sed 's/.*("\(.*\)").*/\1/')
        BASE=$(basename "$DESKTOP" .desktop)
        if [ "$SET_NAME" = "$BASE" ]; then
            info "setDesktopFileName(\"$SET_NAME\") matches $BASE.desktop"
        else
            fail desktop-file "setDesktopFileName(\"$SET_NAME\") does not match $BASE.desktop"
            ok=0
        fi
        ICON=$(grep -m1 '^Icon=' "$DESKTOP" | cut -d= -f2-)
        if grep -q "QStringLiteral(\"$ICON\")" "$REPO_ROOT/src/ui/Application.cpp"; then
            info "Icon=$ICON matches the name loadAppIcon() exports and looks up"
        else
            note "desktop-file: Icon=$ICON is not the name loadAppIcon() uses"
        fi
        EXECNAME=$(grep -m1 '^Exec=' "$DESKTOP" | cut -d= -f2- | awk '{print $1}')
        [ "$EXECNAME" = "$(basename "$APP")" ] \
            && info "Exec=$EXECNAME matches the built binary name" \
            || note "desktop-file: Exec=$EXECNAME but the binary is $(basename "$APP")"
        [ "$ok" -eq 1 ] && pass desktop-file "desktop entry is consistent with the app"
    fi
fi

# ── static check: runtime dependencies against the .deb depends list ────────

if wanted deps; then
    head2 "runtime dependencies vs the .deb depends list"
    # The list itself is read once, near the top of this file; see the comment
    # there for why it is read out of CPackConfig.cmake and not CMakeLists.txt.
    if [ ! -f "$CPACK_CFG" ]; then
        skip deps "no CPackConfig.cmake beside the binary; configure $(dirname "$APP") to generate one"
    elif [ -z "$DEB_DEPENDS" ]; then
        # The file exists and carries no depends list, which is a defect and not
        # a reason to skip: the .deb would declare no dependencies at all.
        fail deps "$CPACK_CFG sets no CPACK_DEBIAN_PACKAGE_DEPENDS, so the package would declare no dependencies"
    else
        if [ "$REPO_ROOT/CMakeLists.txt" -nt "$CPACK_CFG" ]; then
            note "deps: CMakeLists.txt is newer than CPackConfig.cmake; re-configure that build directory or this reads the previous list"
        fi
        info "$(dep_names "$DEB_DEPENDS" | grep -c .) depends, $(dep_names "$DEB_RECOMMENDS" | grep -c .) recommends, read from ${CPACK_CFG#"$REPO_ROOT/"}"
        missing=0
        # Qt libraries the binary really needs, mapped to their Debian package.
        # dpkg-shlibdeps would catch these too, but only if it runs; the explicit
        # list is what a reader trusts.
        while read -r soname pkg; do
            [ -n "$soname" ] || continue
            ldd "$APP" 2>/dev/null | grep -q "$soname" || continue
            listed "$pkg" \
                || { note "deps: $soname is linked but $pkg is not in the depends list"; missing=1; }
        done <<'MAP'
libQt6Core.so.6 libqt6core6
libQt6Gui.so.6 libqt6gui6
libQt6Widgets.so.6 libqt6widgets6
libQt6Quick.so.6 libqt6quick6
libQt6Qml.so.6 libqt6qml6
libQt6Network.so.6 libqt6network6
libQt6DBus.so.6 libqt6dbus6
libQt6Multimedia.so.6 libqt6multimedia6
libQt6Sql.so.6 libqt6sql6
libQt6Svg.so.6 libqt6svg6
libQt6Concurrent.so.6 libqt6concurrent6
libQt6OpenGL.so.6 libqt6opengl6
libasound.so.2 libasound2
libavahi-client.so.3 libavahi-client3
MAP

        # QML modules are dlopened at runtime, so dpkg-shlibdeps cannot see them.
        # This is where a missing dependency turns into a blank window.
        for imp in $(grep -rh '^import Qt' "$REPO_ROOT/qml" | awk '{print $2}' | sort -u); do
            pkg="qml6-module-$(echo "$imp" | tr '[:upper:].' '[:lower:]-')"
            if listed "$pkg"; then
                info "$imp -> $pkg (listed)"
            else
                note "deps: qml/ imports $imp but $pkg is not in the depends list"
                missing=1
            fi
        done

        # The platform plugin is dlopened too, and on Debian the Wayland one is a
        # separate package from libqt6gui6.
        if listed qt6-wayland; then
            info "qt6-wayland is listed"
        elif recommended qt6-wayland; then
            # Deliberate: apt installs Recommends by default and an X11-only box
            # does not need it. Worth stating rather than passing silently,
            # because --no-install-recommends then leaves a Wayland-only desktop
            # with no wayland platform plugin at all.
            info "qt6-wayland is a Recommends, not a Depends; --no-install-recommends leaves a Wayland-only desktop without the platform plugin"
        else
            note "deps: qt6-wayland is in neither Depends nor Recommends; on a Wayland-only desktop the app falls back to XWayland or fails to start"
            missing=1
        fi

        # Every Qt entry has to carry a version floor. Without one the package
        # installs happily on a box whose Qt is older than the one it was built
        # against and then dies at load with "version Qt_6.12 not found", which
        # is the failure CMakeLists.txt records measuring on bookworm. An
        # install that succeeds and then crashes is the worst outcome of the
        # three, so the floors are the point of the list and not a detail of it.
        unversioned=$(printf '%s' "$DEB_DEPENDS" | tr ',' '\n' | sed 's/^[[:blank:]]*//' \
                      | grep -E '^(libqt6|qml6-module-)' | grep -v '(>=')
        if [ -n "$unversioned" ]; then
            note "deps: Qt entries with no version floor: $(printf '%s' "$unversioned" | tr '\n' ' ')"
            missing=1
        else
            info "every libqt6*/qml6-module-* entry carries a version floor"
        fi

        [ "$missing" -eq 0 ] && pass deps "every linked library and QML import is covered" \
                             || fail deps "the depends list has gaps (see the notes above)"
    fi
fi

# ── summary ─────────────────────────────────────────────────────────────────

printf '\n%s== summary ==%s\n' "$C_DIM" "$C_OFF"
printf '  passed:  %d  %s\n' "${#PASSED[@]}"  "${PASSED[*]:-}"
printf '  failed:  %d  %s\n' "${#FAILED[@]}"  "${FAILED[*]:-}"
printf '  skipped: %d  %s\n' "${#SKIPPED[@]}" "${SKIPPED[*]:-}"
if [ "${#NOTES[@]}" -gt 0 ]; then
    printf '  notes:\n'
    printf '    - %s\n' "${NOTES[@]}"
fi
printf '\n'
[ "${#FAILED[@]}" -eq 0 ]
