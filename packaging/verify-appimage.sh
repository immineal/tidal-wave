#!/usr/bin/env bash
# Run the built AppImage headless in a clean container.
#
#     packaging/verify-appimage.sh [file.AppImage] [image]
#
# Defaults: the newest AppImage in dist/, and debian:bookworm. The .zsync file
# is expected next to the AppImage, where the build leaves it. The container
# gets only the packages listed below. They are what the AppImage needs from
# the host, and the README names the same ones. Pass means the bundle carries
# what integration tools read, the app is still running after 25 seconds and
# its log carries no QML or plugin load error.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"

IMAGE="debian:bookworm"
APPIMAGE=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)  sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
echo "=== 2. what integration tools read ==="
# Copied, because the mount it arrives on may not allow execution.
NAME="$(basename /pkg/*.AppImage)"
cp "/pkg/$NAME" /tmp/tidal-wave.AppImage
chmod +x /tmp/tidal-wave.AppImage
(cd /tmp && ./tidal-wave.AppImage --appimage-extract >/dev/null)
ROOT=/tmp/squashfs-root
ID=io.github.immineal.TidalWave
key() { sed -n "s/^$1=//p" "$ROOT/$ID.desktop"; }
check() {
    local what="$1"
    shift
    if "$@" >/dev/null 2>&1; then echo "ok: $what"; else fail "$what"; fi
}

# The entry a tool copies into the menu, and the version it shows there.
check "the one entry at the top is $ID.desktop" \
    [ "$(cd "$ROOT" && echo *.desktop)" = "$ID.desktop" ]
check "Exec names the bundled binary" \
    [ "$(key Exec)" = tidal-wave -a -x "$ROOT/usr/bin/tidal-wave" ]
check "Icon is tidal-wave" [ "$(key Icon)" = tidal-wave ]
VERSION="$(key X-AppImage-Version)"
check "X-AppImage-Version is a version: $VERSION" expr "$VERSION" : '[0-9][0-9.]*$'
case "$NAME" in
    tidal-wave-[0-9]*) check "it is the version in the file name" \
        [ "$NAME" = "tidal-wave-$VERSION-x86_64.AppImage" ] ;;
esac

# The icon by every path a tool looks under. .DirIcon and the top-level file
# are links into the theme directory.
for icon in .DirIcon tidal-wave.svg \
    usr/share/icons/hicolor/scalable/apps/tidal-wave.svg \
    usr/share/icons/hicolor/128x128/apps/tidal-wave.png
do
    check "icon: $icon" [ -s "$ROOT/$icon" ]
done

# What Gear Lever and AppImageUpdate follow to the next release: the update
# information in the file, and a zsync file made from exactly this file.
ASSET=tidal-wave-x86_64.AppImage
check "the update information names the zsync file of the newest release" \
    [ "$(/tmp/tidal-wave.AppImage --appimage-updateinformation)" = "gh-releases-zsync|immineal|tidal-wave|latest|$ASSET.zsync" ]
zsync() { sed -n "s/^$1: //p;/^\$/q" "/pkg/$NAME.zsync" 2>/dev/null; }
check "the zsync file points at $ASSET" [ "$(zsync URL)" = "$ASSET" ]
check "the zsync file names the download $ASSET" [ "$(zsync Filename)" = "$ASSET" ]
check "the zsync file was made from this AppImage" \
    [ "$(zsync SHA-1)" = "$(sha1sum "/pkg/$NAME" | cut -d' ' -f1)" ]

META="$ROOT/usr/share/metainfo/$ID.metainfo.xml"
check "the metainfo file carries the id" grep -q "<id>$ID</id>" "$META"
check "the metainfo file launches the entry" \
    grep -q "<launchable type=\"desktop-id\">$ID.desktop</launchable>" "$META"

echo
echo "=== 3. launch the AppImage, headless ==="
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
echo "=== 4. scan the log ==="
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
[ ! -f "$APPIMAGE.zsync" ] || cp "$APPIMAGE.zsync" "$STAGE/"

docker run --rm -v "$STAGE:/pkg:ro" "$IMAGE" bash -c "$INNER"
