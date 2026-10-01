#!/usr/bin/env bash
# Install the built .deb in a *clean* Debian 12 container and run it.
#
#     packaging/verify-deb.sh [path/to/tidal-wave_*.deb]
#
# Defaults to the newest .deb in dist/. Deliberately not the build image: that
# one has every -dev package and the whole Qt toolchain, so a missing runtime
# dependency would go unnoticed there. A bare debian:bookworm has nothing, so
# apt has to resolve the generated Depends list for real.
#
# What it checks, in order:
#   1. `apt-get install ./pkg.deb` resolves and configures with no -f fixup.
#   2. The installed binary reaches its event loop with a root object. The app
#      returns -1 immediately when the QML engine produces none, so surviving
#      until the timeout kills it (exit 124) is the window check, and an
#      immediate exit is the failure.
#   3. stderr carries no "is not a type" and no ReferenceError.
# It never logs in: the app stops at the login page on its own with no token.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"

if [ $# -ge 1 ]; then
    DEB="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
    DEB="$(ls -t "$REPO"/dist/*.deb 2>/dev/null | head -1 || true)"
fi
[ -n "${DEB:-}" ] && [ -f "$DEB" ] || { echo "no .deb found - run packaging/build-deb.sh first" >&2; exit 2; }
echo "==> verifying $(basename "$DEB")"

read -r -d '' INNER <<'INNER_EOF' || true
set -eu
export DEBIAN_FRONTEND=noninteractive
DEB=/pkg/$(ls /pkg)

echo "=== 1. apt-get install ==="
apt-get update -qq
# No -f, no --fix-broken, no dpkg -i fallback: if the generated floors are wrong
# for this release apt refuses here, and that refusal is the finding.
apt-get install -y "$DEB"
echo "--- install status"
dpkg-query -W -f='${Package} ${Version} ${Status}\n' tidal-wave
echo "--- anything left unconfigured or half-installed?"
if dpkg --audit | grep -q .; then dpkg --audit; echo "DPKG AUDIT NOT CLEAN"; else echo "dpkg --audit: clean"; fi
echo "--- would apt-get -f install change anything?"
apt-get -f install --dry-run 2>&1 | tail -5

echo
echo "=== 2+3. launch the installed binary, headless ==="
command -v tidal-wave
export QT_QPA_PLATFORM=offscreen
export HOME=/tmp/run; mkdir -p "$HOME"
export XDG_RUNTIME_DIR=/tmp/run
set +e
timeout -s TERM 25 tidal-wave >/tmp/out.log 2>&1
RC=$?
set -e
echo "exit code: $RC  (124 = still running when the timer fired = reached the event loop)"
echo "--- stderr/stdout, in full ---"
cat /tmp/out.log
echo "--- scan ---"
if grep -q "is not a type" /tmp/out.log; then echo 'FAIL: "is not a type" present'; else echo 'ok: no "is not a type"'; fi
if grep -q "ReferenceError" /tmp/out.log; then
    echo 'ReferenceError present:'; grep -c "ReferenceError" /tmp/out.log
    grep -o "ReferenceError: [A-Za-z]* is not defined" /tmp/out.log | sort | uniq -c
else
    echo "ok: no ReferenceError"
fi
if [ "$RC" -eq 124 ] || [ "$RC" -eq 143 ]; then echo "ok: reached a window"; else echo "FAIL: exited early with $RC"; fi
INNER_EOF

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DEB" "$STAGE/"

docker run --rm -v "$STAGE:/pkg:ro" debian:bookworm bash -c "$INNER"
