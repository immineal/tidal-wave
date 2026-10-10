#!/usr/bin/env bash
# Run the built AppImage headless in a clean container.
#
#     packaging/verify-appimage.sh [file.AppImage] [image]
#
# Defaults: the newest AppImage in dist/, and debian:bookworm. The container
# gets only the packages listed below. They are what the AppImage needs from
# the host, and the README names the same ones. Pass means the app is still
# running after 25 seconds and its log carries no QML or plugin load error.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"

IMAGE="debian:bookworm"
APPIMAGE=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)  sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *.AppImage) APPIMAGE="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")" ;;
        *)          IMAGE="$arg" ;;
    esac
done
if [ -z "$APPIMAGE" ]; then
    APPIMAGE="$(ls -t "$REPO"/dist/*.AppImage 2>/dev/null | head -1 || true)"
fi
[ -n "$APPIMAGE" ] && [ -f "$APPIMAGE" ] || { echo "no AppImage found - run packaging/build-appimage.sh first" >&2; exit 2; }
echo "==> verifying $(basename "$APPIMAGE") on $IMAGE"

read -r -d '' INNER <<'INNER_EOF' || true
set -eu
FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

echo "=== 1. host requirements ==="
# OpenGL, EGL, fontconfig, OpenSSL 3 with the CA certificates (ca-certificates
# pulls both in), and two base libraries a bare image can lack. Add a package
# here and it goes into the README too.
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates libegl1 libfontconfig1 libgl1 libcom-err2 libgpg-error0
elif command -v dnf >/dev/null; then
    dnf install -y -q \
        ca-certificates openssl-libs libglvnd-egl libglvnd-glx fontconfig \
        libcom_err libgpg-error
else
    echo "ERROR: this image has neither apt-get nor dnf" >&2
    exit 2
fi

echo
echo "=== 2. launch the AppImage, headless ==="
# Copied, because the mount it arrives on may not allow execution.
cp /pkg/*.AppImage /tmp/tidal-wave.AppImage
chmod +x /tmp/tidal-wave.AppImage
export QT_QPA_PLATFORM=offscreen
export HOME=/tmp/home XDG_RUNTIME_DIR=/tmp/home
mkdir -m 700 "$HOME"
# There is no FUSE in a container, so the AppImage unpacks itself to run.
RC=0
timeout -s TERM 25 /tmp/tidal-wave.AppImage --appimage-extract-and-run >/tmp/out.log 2>&1 || RC=$?
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
cp "$APPIMAGE" "$STAGE/"

docker run --rm -v "$STAGE:/pkg:ro" "$IMAGE" bash -c "$INNER"
