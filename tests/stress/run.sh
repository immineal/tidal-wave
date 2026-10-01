#!/usr/bin/env bash
#
# Stress and environment harness (HANDOFF section I, SPEC X4 / X5 / X6).
#
# Runs the QtQuickTest stress suite in tests/stress/qml once per graphics
# environment this box can offer, samples resident set size while it runs, and
# finishes with a pass/fail summary.
#
# Usage
#   tests/stress/run.sh                  every scenario this box can run
#   tests/stress/run.sh --list           list scenario ids and exit
#   tests/stress/run.sh offscreen xcb    run only the named scenarios
#   tests/stress/run.sh --no-build       use the stress binary already built
#   tests/stress/run.sh --keep           leave the sandbox behind
#   STRESS_SCALE=0.25 tests/stress/run.sh   quarter length, for a quick check
#   STRESS_SCALE=4 tests/stress/run.sh      four times as long, to reproduce
#   STRESS_BUILD=/path tests/stress/run.sh  where to build the runner
#   TIDALWAVE_BIN=/path/to/tidal-wave    the app binary, for the idle scenario
#
# Exit status is 0 only if every scenario that ran passed. A scenario that was
# skipped says why and does not fail the run.
#
# Safety, because a real instance of this app is usually running on the dev box.
# Same rules as tests/firstrun/run.sh, for the same reasons:
#
#   * Nothing here pkills, killalls or matches a process name. The only
#     processes signalled are ones this script started, by recorded pid.
#   * Every run gets its own HOME, TMPDIR, XDG_RUNTIME_DIR and XDG_*_HOME under
#     a private scratch directory, through `env -i`, so nothing from the
#     caller's session leaks in.
#   * The single-instance lock is a QLocalServer at an absolute path the app
#     builds itself: $XDG_RUNTIME_DIR, else $TMPDIR, else /tmp, plus
#     TidalWave-<uid>. XDG_RUNTIME_DIR is therefore what isolates a run, with
#     TMPDIR behind it, and the sandbox sets both. tests/lib/socket-name.sh
#     derives the address the way Application.cpp does rather than guessing at
#     it. A unix socket path caps a couple of bytes under sun_path, so the
#     scratch root is deliberately short and the script refuses to run if it is
#     not: a path too long makes listen() fail and the isolation would be a
#     false pass.
#   * The developer's real ~/.config/TidalWave is fingerprinted up front and
#     re-checked after every scenario.
#   * No synthetic input. Nothing drives the app from outside: the stress cases
#     are a QtQuickTest driver inside the process, which is also the only way
#     to resize and navigate deterministically.
#   * Every launch runs under `timeout`, so nothing started here outlives it.
#
set -u

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
# TW_SOCKET_LEAF and tw_socket_path/tw_socket_live: the one place that knows
# where the single-instance lock lives, kept in step with src/ui/Application.cpp.
. "$REPO_ROOT/tests/lib/socket-name.sh"

APP=${TIDALWAVE_BIN:-$REPO_ROOT/build-t/tidal-wave}
BUILD_DIR=${STRESS_BUILD:-/tmp/tw-stress-build}
SCALE=${STRESS_SCALE:-1}
# Per-scenario wall clock ceiling. The suite is long by design; this only has
# to be larger than it, and it scales with STRESS_SCALE.
RUN_TIMEOUT=${STRESS_TIMEOUT:-$(awk -v s="$SCALE" 'BEGIN{t=600*s; if(t<300)t=300; printf "%d", t}')}
IDLE_SECONDS=${STRESS_IDLE_SECONDS:-25}

DO_BUILD=1
KEEP=0
WANTED=()

for arg in "$@"; do
    case $arg in
        --keep)     KEEP=1 ;;
        --no-build) DO_BUILD=0 ;;
        --list)     printf '%s\n' offscreen software xcb wayland idle-rss; exit 0 ;;
        -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
        -*)         echo "unknown option: $arg" >&2; exit 2 ;;
        *)          WANTED+=("$arg") ;;
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

head2() { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass()  { PASSED+=("$1");  printf '  %spass%s %s\n' "$C_GRN" "$C_OFF" "${2:-$1}"; }
fail()  { FAILED+=("$1");  printf '  %sfail%s %s\n' "$C_RED" "$C_OFF" "${2:-$1}"; }
skip()  { SKIPPED+=("$1"); printf '  %sskip%s %s: %s\n' "$C_YEL" "$C_OFF" "$1" "$2"; }
note()  { NOTES+=("$1");   printf '  %snote%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
info()  { printf '       %s\n' "$1"; }

die() { printf '%sabort:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 2; }

# ── scratch root, kept short on purpose ─────────────────────────────────────

SCRATCH=$(mktemp -d /tmp/twst.XXXXXX) || die "cannot create a scratch directory"

# The longest address a run of ours can bind is $SCRATCH/<scenario>/run/<leaf>;
# 24 bytes is ample for the scenario directory and 5 covers "/run/". A lock that
# cannot bind does not fail the run, it silently stops isolating it, so this is
# checked up front rather than discovered later.
probe_len=$(( ${#SCRATCH} + 24 + 5 + ${#TW_SOCKET_LEAF} ))
[ "$probe_len" -le "$TW_SOCKET_PATH_MAX" ] \
    || die "scratch path $SCRATCH is too long for a unix socket"

HELPER_PIDS=()
track() { HELPER_PIDS+=("$1"); }
reap_all() {
    local pid
    for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null       # only pids this script started
    done
    for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        for _ in $(seq 1 20); do
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

# ── guard: the developer's own settings must not move ───────────────────────

REAL_CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/TidalWave
REAL_CREDS=$HOME/.config/tidal-wave
# The developer's own lock, worked out the way the app works it out. On a normal
# session that is $XDG_RUNTIME_DIR/TidalWave-<uid>, i.e. /run/user/<uid>/..., and
# not the temp dir this script used to fingerprint instead.
REAL_LOCK=$(tw_socket_path "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}")

# Passive liveness probe. This grepped for "TidalWaveSingleInstanceSocket", a
# name nothing has bound since the uid went into the leaf, so it never once
# matched: the harness believed nothing was running while the developer's window
# was open, and the tolerance below was never granted. Anything under $SCRATCH is
# excluded so a run never mistakes its own sandbox for the real instance.
LIVE_INSTANCE=0
tw_socket_live "$SCRATCH" && LIVE_INSTANCE=1

guard_structure() {
    { [ -e "$REAL_LOCK" ] && stat -c 'lock %i %Y %a' "$REAL_LOCK"; } 2>/dev/null
    { [ -d "$REAL_CONF_DIR" ] && find "$REAL_CONF_DIR" -type f -printf 'file %p\n' | sort; } 2>/dev/null
    { [ -d "$REAL_CREDS" ] && find "$REAL_CREDS" -type f -printf 'cred %p\n' | sort; } 2>/dev/null
    true
}
GUARD_STRUCT=$(guard_structure)

guard_check() {
    local now; now=$(guard_structure)
    if [ "$now" != "$GUARD_STRUCT" ]; then
        printf '%s\n' "--- before ---" "$GUARD_STRUCT" "--- after ---" "$now" >&2
        printf 'The real lock or settings directory changed while %s ran.\n' "$1" >&2
        printf 'Restarting the app by hand mid-run does this too and is harmless.\n' >&2
        printf 'Anything else means a sandbox leaked, so the run stops here either way.\n' >&2
        die "guard tripped during '$1'"
    fi
}

# ── the sandbox ─────────────────────────────────────────────────────────────

BOX=''
BOX_ENV=()

sandbox() {
    BOX=$SCRATCH/$1
    rm -rf "$BOX"
    mkdir -p "$BOX/home/.config" "$BOX/home/.cache" "$BOX/home/.local/share" \
             "$BOX/home/.local/state" "$BOX/run" "$BOX/tmp" "$BOX/logs"
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
        # autolaunch a daemon, and a live one would put this run's MPRIS name
        # on the developer's session bus.
        "DBUS_SESSION_BUS_ADDRESS=unix:path=$BOX/run/absent-session-bus"
        "QT_LOGGING_RULES="
        "STRESS_SCALE=$SCALE"
        # The QML cases read /proc/self/status for VmRSS and /proc/self/environ
        # for STRESS_SCALE. QML blocks file:// reads from XMLHttpRequest unless
        # this is set, and without it every memory number comes back as -1.
        "QML_XHR_ALLOW_FILE_READ=1"
    )
}

# Sample VmRSS of one pid every 250 ms into a log. Pure procfs reads: it never
# signals the process and never touches anything outside the sandbox.
sample_rss() {
    local pid=$1 out=$2
    (
        while [ -r "/proc/$pid/status" ]; do
            awk '/^VmRSS:/ {print systime(), $2}' "/proc/$pid/status" >> "$out" 2>/dev/null
            sleep 0.25
        done
    ) &
    track $!
    echo $!
}

rss_summary() {
    local log=$1
    [ -s "$log" ] || { echo "no samples"; return; }
    awk '{ if (NR==1) {first=$2; min=$2; max=$2}
           if ($2<min) min=$2; if ($2>max) max=$2; last=$2; n++ }
         END { printf "%d samples, start %.1f MiB, peak %.1f MiB, end %.1f MiB, growth %+.1f MiB",
                      n, first/1024, max/1024, last/1024, (last-first)/1024 }' "$log"
}

# ── build the stress runner ─────────────────────────────────────────────────

STRESS_BIN=$BUILD_DIR/tst_stress
FALLBACK_BIN=$REPO_ROOT/build-t/tests/tst_qml
USING_FALLBACK=0

head2 "stress runner"
# The box may have a system Qt6 that is missing QuickTest. Reuse whatever
# prefix the app's own build dir was configured with rather than guessing.
CMAKE_EXTRA=()
QT_PREFIX=${STRESS_QT_PREFIX:-$(sed -n 's/^CMAKE_PREFIX_PATH:[^=]*=//p' \
                                   "$REPO_ROOT/build-t/CMakeCache.txt" 2>/dev/null | head -1)}
if [ -n "$QT_PREFIX" ]; then
    CMAKE_EXTRA+=("-DCMAKE_PREFIX_PATH=$QT_PREFIX")
    info "Qt prefix: $QT_PREFIX (from build-t/CMakeCache.txt)"
fi

if [ "$DO_BUILD" -eq 1 ]; then
    info "configuring and building $BUILD_DIR (this also builds the app library)"
    if cmake -B "$BUILD_DIR" -S "$SELF_DIR" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
            > "$SCRATCH/cmake-configure.log" 2>&1 \
       && cmake --build "$BUILD_DIR" --parallel 4 --target tst_stress \
            > "$SCRATCH/cmake-build.log" 2>&1; then
        info "built $STRESS_BIN"
    else
        note "the stress runner did not build; see $SCRATCH/cmake-*.log"
        tail -25 "$SCRATCH/cmake-build.log" 2>/dev/null | sed 's/^/         /'
        tail -15 "$SCRATCH/cmake-configure.log" 2>/dev/null | sed 's/^/         /'
        KEEP=1
    fi
fi

if [ -x "$STRESS_BIN" ]; then
    info "runner:  $STRESS_BIN"
elif [ -x "$FALLBACK_BIN" ]; then
    USING_FALLBACK=1
    STRESS_BIN=$FALLBACK_BIN
    note "falling back to the prebuilt $FALLBACK_BIN; it installs no prefs/i18n context property, so the theme and language cases will skip"
    info "runner:  $STRESS_BIN (fallback)"
else
    die "no stress runner and no prebuilt tests/tst_qml to fall back to"
fi

info "input:   $SELF_DIR/qml"
info "scale:   STRESS_SCALE=$SCALE, per-scenario timeout ${RUN_TIMEOUT}s"
info "scratch: $SCRATCH (short on purpose: a unix socket path caps at 107 bytes)"
if [ "$LIVE_INSTANCE" -eq 1 ]; then
    info "another instance is listening on $REAL_LOCK; it is left strictly alone"
fi

# ── patterns that mean the app is broken, not that the box is odd ───────────

FATAL='TypeError|ReferenceError|is not a function|Binding loop|Cannot assign|Unable to assign|Cannot read propert|QQmlApplicationEngine failed|is not installed|is not a type|ASSERT|Segmentation fault|SIGSEGV|QQmlComponent: Component is not ready'
BENIGN='pipewire|PulseAudio|pa_context|ALSA|snd_pcm|snd_lib|[Ff]ontconfig|libEGL|libGL|MESA|swrast|DRI[0-9]|session bus|D-Bus|dbus|XDG_RUNTIME_DIR|Icon theme|QStandardPaths|xkbcommon|Wayland does not support|Could not connect to any X display|QSocketNotifier|Populating font family aliases'

# ── one stress scenario ─────────────────────────────────────────────────────

# run_suite <id> <label> [VAR=VAL ...]
run_suite() {
    local id=$1 label=$2; shift 2
    sandbox "$id"
    local out=$BOX/logs/$id.out
    local err=$BOX/logs/$id.err
    local rss=$BOX/logs/$id.rss

    env -i "${BOX_ENV[@]}" "$@" \
        timeout -s TERM "$RUN_TIMEOUT" "$STRESS_BIN" \
            -input "$SELF_DIR/qml" -maxwarnings 0 \
        >"$out" 2>"$err" &
    local job=$!

    # The pid of `timeout` is not the pid of the test binary, so find the child
    # it started. Both are ours; nothing is matched by name.
    local child=''
    for _ in $(seq 1 40); do
        child=$(cat "/proc/$job/task/$job/children" 2>/dev/null | awk '{print $1}')
        [ -n "$child" ] && break
        sleep 0.25
    done
    [ -n "$child" ] && sample_rss "$child" "$rss" >/dev/null

    wait "$job"; local status=$?
    reap_all

    local totals
    totals=$(grep -aE '^Totals:' "$out" | tail -1)
    local ok=1

    case $status in
        0)   : ;;
        124) fail "$id" "$label: hit the ${RUN_TIMEOUT}s timeout before finishing"; ok=0 ;;
        139) fail "$id" "$label: segfault (exit 139)"; ok=0 ;;
        *)   fail "$id" "$label: exited $status"; ok=0 ;;
    esac

    # Everything QTest reported, not just the tail.
    local failures
    failures=$(grep -aE '^(FAIL!|XPASS|QFATAL)' "$out")
    if [ -n "$failures" ]; then
        [ "$ok" -eq 1 ] && { fail "$id" "$label: QTest reported failures"; ok=0; }
        printf '%s\n' "$failures" | head -40 | sed 's/^/         /'
    fi

    local bad
    bad=$(grep -aEn "$FATAL" "$out" "$err" 2>/dev/null | head -25)
    if [ -n "$bad" ]; then
        [ "$ok" -eq 1 ] && { fail "$id" "$label: QML errors in the log"; ok=0; }
        printf '%s\n' "$bad" | sed 's/^/         /'
    fi

    [ "$ok" -eq 1 ] && pass "$id" "$label: ${totals:-no totals line}"
    [ -n "$totals" ] && [ "$ok" -eq 0 ] && info "$totals"

    # The measurements are the point of the exercise, pass or fail.
    grep -a '\[stress\]' "$out" "$err" 2>/dev/null \
        | sed 's/.*\[stress\]/       [stress]/' | head -60

    local skips
    skips=$(grep -acE '^SKIP' "$out" 2>/dev/null)
    [ "${skips:-0}" -gt 0 ] && info "$skips QTest case(s) skipped inside the suite"

    [ -s "$rss" ] && info "process rss: $(rss_summary "$rss")"

    guard_check "$id"
}

# ── scenario: offscreen, the CI shape and the baseline ──────────────────────

if wanted offscreen; then
    head2 "offscreen (CI baseline)"
    run_suite offscreen "offscreen" QT_QPA_PLATFORM=offscreen
fi

# ── scenario: software scene graph ──────────────────────────────────────────

if wanted software; then
    head2 "software scene graph (no GPU)"
    run_suite software "QT_QUICK_BACKEND=software" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
fi

# ── scenario: X11 on a private Xvfb ─────────────────────────────────────────

pick_display() {
    local n
    for n in $(seq 80 89); do
        [ -e "/tmp/.X11-unix/X$n" ] || { echo ":$n"; return 0; }
    done
    return 1
}

if wanted xcb; then
    head2 "X11 / xcb"
    if ! command -v Xvfb >/dev/null 2>&1; then
        skip xcb "Xvfb is not installed, and the real display belongs to the developer"
    elif ! DISP=$(pick_display); then
        skip xcb "no free X display between :80 and :89"
    else
        mkdir -p "$SCRATCH/xvfb"
        Xvfb "$DISP" -screen 0 1600x1000x24 -nolisten tcp \
            >"$SCRATCH/xvfb/xvfb.log" 2>&1 &
        XVFB_PID=$!; track "$XVFB_PID"
        ready=0
        for _ in $(seq 1 40); do
            [ -e "/tmp/.X11-unix/X${DISP#:}" ] && { ready=1; break; }
            sleep 0.25
        done
        if [ "$ready" -eq 0 ]; then
            skip xcb "Xvfb never came up on $DISP"
            reap_all
        else
            info "private display $DISP (pid $XVFB_PID); nothing on the real session is touched"
            run_suite xcb "xcb on $DISP" DISPLAY="$DISP" QT_QPA_PLATFORM=xcb
            # reap_all inside run_suite already took Xvfb down with it.
            HELPER_PIDS=()
        fi
    fi
fi

# ── scenario: Wayland, nested in a headless compositor ──────────────────────

if wanted wayland; then
    head2 "Wayland"
    if ! command -v kwin_wayland >/dev/null 2>&1 && ! command -v weston >/dev/null 2>&1; then
        skip wayland "no nested compositor (kwin_wayland or weston), and the real session must not be used"
    elif ! command -v dbus-daemon >/dev/null 2>&1; then
        skip wayland "a nested compositor needs a session bus and dbus-daemon is not installed"
    else
        sandbox wayland-host
        PRIVATE_BUS=''
        if ! dbus-daemon --session --fork --print-address=3 --print-pid=4 \
                3>"$BOX/run/bus-address" 4>"$BOX/run/bus-pid" 2>/dev/null; then
            skip wayland "could not start a private session bus"
        else
            BUSPID=$(cat "$BOX/run/bus-pid" 2>/dev/null)
            [ -n "$BUSPID" ] && track "$BUSPID"
            PRIVATE_BUS=$(cat "$BOX/run/bus-address" 2>/dev/null)
            WD=wayland-twst
            HOSTRUN=$BOX/run

            if command -v kwin_wayland >/dev/null 2>&1; then
                info "nested kwin_wayland on a virtual framebuffer, socket $WD"
                env -i "${BOX_ENV[@]}" DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" \
                    QT_QPA_PLATFORM=offscreen \
                    kwin_wayland --virtual --width 1600 --height 1000 \
                                 --no-lockscreen --no-global-shortcuts --socket "$WD" \
                    >"$BOX/logs/compositor.log" 2>&1 &
            else
                info "nested weston on a headless backend, socket $WD"
                env -i "${BOX_ENV[@]}" DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" \
                    weston --backend=headless-backend.so --width=1600 --height=1000 \
                           --socket="$WD" \
                    >"$BOX/logs/compositor.log" 2>&1 &
            fi
            COMP_PID=$!; track "$COMP_PID"

            ready=0
            for _ in $(seq 1 80); do
                [ -S "$HOSTRUN/$WD" ] && { ready=1; break; }
                kill -0 "$COMP_PID" 2>/dev/null || break
                sleep 0.25
            done
            if [ "$ready" -eq 0 ]; then
                skip wayland "the compositor never created $WD (see $BOX/logs/compositor.log)"
                info "$(tail -3 "$BOX/logs/compositor.log" 2>/dev/null)"
                reap_all
            else
                # The suite runs in its own sandbox, so point it at the
                # compositor's runtime dir rather than its own.
                COMP_PIDS=("${HELPER_PIDS[@]}")
                run_suite wayland "wayland (nested compositor)" \
                    XDG_RUNTIME_DIR="$HOSTRUN" WAYLAND_DISPLAY="$WD" \
                    QT_QPA_PLATFORM=wayland \
                    DBUS_SESSION_BUS_ADDRESS="$PRIVATE_BUS" \
                    XDG_CURRENT_DESKTOP=KDE
                HELPER_PIDS=("${COMP_PIDS[@]}")
                reap_all
            fi
        fi
    fi
fi

# ── scenario: the real binary, idle, watched ────────────────────────────────
#
# The stress suite is the QML tree without the app around it. This is the app
# itself, in every theme, doing nothing. It catches the opposite problem: a
# timer, an animation or a poll that burns memory or CPU while the window just
# sits there. Observation only, no input, no network expected to answer.

if wanted idle-rss; then
    head2 "the real binary, idle"
    if [ ! -x "$APP" ]; then
        skip idle-rss "no binary at $APP"
    else
        for theme in sea sky; do
            sandbox "idle-$theme"
            mkdir -p "$BOX/home/.config/TidalWave"
            cat > "$BOX/home/.config/TidalWave/Tidal Wave.conf" <<CONF
[ui]
theme=$theme
language=de
sidebarWidth=240

[update]
enabled=false
CONF
            out=$BOX/logs/idle.out; err=$BOX/logs/idle.err; rss=$BOX/logs/idle.rss
            env -i "${BOX_ENV[@]}" QT_QPA_PLATFORM=offscreen \
                timeout -s TERM "$IDLE_SECONDS" "$APP" >"$out" 2>"$err" &
            job=$!
            child=''
            for _ in $(seq 1 40); do
                child=$(cat "/proc/$job/task/$job/children" 2>/dev/null | awk '{print $1}')
                [ -n "$child" ] && break
                sleep 0.25
            done
            if [ -n "$child" ]; then
                sample_rss "$child" "$rss" >/dev/null
                cpu0=$(awk '{print $14+$15}' "/proc/$child/stat" 2>/dev/null)
            fi
            sleep 1
            cpu1=''
            [ -n "$child" ] && cpu1=$(awk '{print $14+$15}' "/proc/$child/stat" 2>/dev/null)
            wait "$job"; status=$?
            reap_all

            if [ "$status" != 124 ] && [ "$status" != 0 ]; then
                fail "idle-$theme" "the app exited $status while sitting idle"
            elif [ "$status" = 0 ]; then
                fail "idle-$theme" "exited 0 straight away: the sandbox leaked and it found another instance"
            else
                bad=$(grep -aEn "$FATAL" "$out" "$err" 2>/dev/null | head -10)
                if [ -n "$bad" ]; then
                    fail "idle-$theme" "stayed up but logged QML errors with theme=$theme"
                    printf '%s\n' "$bad" | sed 's/^/         /'
                else
                    pass "idle-$theme" "stayed up ${IDLE_SECONDS}s on theme=$theme, language=de, no QML errors"
                fi
            fi
            [ -s "$rss" ] && info "idle rss: $(rss_summary "$rss")"
            noise=$(grep -avE "$BENIGN" "$err" 2>/dev/null | grep -av '^[[:space:]]*$' | head -10)
            [ -n "$noise" ] && { info "unclassified stderr:"; printf '%s\n' "$noise" | sed 's/^/         /'; }
            guard_check "idle-$theme"
        done
    fi
fi

# ── summary ─────────────────────────────────────────────────────────────────

printf '\n%s== summary ==%s\n' "$C_DIM" "$C_OFF"
printf '  scale:   STRESS_SCALE=%s\n' "$SCALE"
[ "$USING_FALLBACK" -eq 1 ] && printf '  runner:  prebuilt tests/tst_qml (theme and language cases skipped)\n'
printf '  passed:  %d  %s\n' "${#PASSED[@]}"  "${PASSED[*]:-}"
printf '  failed:  %d  %s\n' "${#FAILED[@]}"  "${FAILED[*]:-}"
printf '  skipped: %d  %s\n' "${#SKIPPED[@]}" "${SKIPPED[*]:-}"
if [ "${#NOTES[@]}" -gt 0 ]; then
    printf '  notes:\n'
    printf '    - %s\n' "${NOTES[@]}"
fi
printf '\n'
[ "${#FAILED[@]}" -eq 0 ]
