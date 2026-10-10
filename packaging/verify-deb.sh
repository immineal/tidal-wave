#!/usr/bin/env bash
# Install the built .deb in a clean container and start the app headless.
#
#     packaging/verify-deb.sh [package.deb] [image]
#
# Defaults: the newest .deb in dist/, and debian:bookworm. The image is a bare
# distribution, never the build image, so apt has to resolve the generated
# Depends for real. Pass means apt installs the package with nothing left to
# fix, the app is still running after 25 seconds, and its log carries no QML
# or plugin load error. Any failure exits non-zero.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"

IMAGE="debian:bookworm"
DEB=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *.deb)     DEB="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")" ;;
        *)         IMAGE="$arg" ;;
    esac
done
if [ -z "$DEB" ]; then
    DEB="$(ls -t "$REPO"/dist/*.deb 2>/dev/null | head -1 || true)"
fi
[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "no .deb found - run packaging/build-deb.sh first" >&2; exit 2; }
echo "==> verifying $(basename "$DEB") on $IMAGE"

read -r -d '' INNER <<'INNER_EOF' || true
set -eu
export DEBIAN_FRONTEND=noninteractive
DEB=/pkg/$(ls /pkg)
FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

echo "=== 1. apt-get install ==="
apt-get update -qq
# No -f and no dpkg -i fallback: a refusal from apt is the finding.
apt-get install -y "$DEB"
dpkg-query -W -f='${Package} ${Version} ${Status}\n' tidal-wave
if dpkg --audit | grep -q .; then
    dpkg --audit
    fail "dpkg --audit is not clean"
else
    echo "ok: dpkg --audit is clean"
fi
# Simulated. An Inst, Remv or Conf line is work apt still wants to do.
if apt-get -f install --dry-run 2>&1 | grep -E '^(Inst|Remv|Conf) '; then
    fail "apt-get -f install would still change something"
else
    echo "ok: apt-get -f install has nothing to do"
fi

echo
echo "=== 2. launch the installed binary, headless ==="
command -v tidal-wave
export QT_QPA_PLATFORM=offscreen
export HOME=/tmp/run XDG_RUNTIME_DIR=/tmp/run
mkdir -m 700 "$HOME"
RC=0
timeout -s TERM 25 tidal-wave >/tmp/out.log 2>&1 || RC=$?
echo "--- log, in full ---"
cat /tmp/out.log
echo "--- end of log ---"
# The app exits at once when the QML engine yields no root object, so 124
# (timeout had to stop it) means it reached its event loop with a window.
if [ "$RC" -eq 124 ]; then
    echo "ok: still running after 25 s"
else
    fail "exited early with status $RC"
fi

echo
echo "=== 3. scan the log ==="
for pattern in \
    'is not a type' \
    'ReferenceError' \
    'module "[^"]*" is not installed' \
    'Could not (find|load) the Qt platform plugin' \
    'No QtMultimedia backends found' \
    'TLS initialization failed'
do
    if grep -qE "$pattern" /tmp/out.log; then
        fail "the log matches: $pattern"
        grep -E "$pattern" /tmp/out.log | sort | uniq -c | head -5
    else
        echo "ok: no match for: $pattern"
    fi
done

echo
if [ "$FAILED" -ne 0 ]; then echo "RESULT: FAILED"; else echo "RESULT: passed"; fi
exit "$FAILED"
INNER_EOF

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DEB" "$STAGE/"

docker run --rm -v "$STAGE:/pkg:ro" "$IMAGE" bash -c "$INNER"
