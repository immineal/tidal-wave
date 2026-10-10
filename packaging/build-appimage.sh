#!/usr/bin/env bash
# Build the AppImage in an Ubuntu 22.04 container, with Qt 6.12.0 bundled.
#
#     packaging/build-appimage.sh
#     packaging/build-appimage.sh --rebuild-image
#
# The result is dist/tidal-wave-<version>-x86_64.AppImage. The container sets
# the glibc floor; see packaging/Dockerfile.appimage. Qt, its plugins and FFmpeg
# are bundled, while OpenSSL 3, OpenGL, fontconfig and X11 come from the host.
# Any failure exits non-zero and leaves dist/ untouched.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
IMAGE="tidal-wave-appimage:jammy"

REBUILD_IMAGE=0
for arg in "$@"; do
    case "$arg" in
        --rebuild-image) REBUILD_IMAGE=1 ;;
        -h|--help)       sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# The one declaration of the version, as the CI workflow reads it.
VERSION="$(sed -n 's/^project(tidal-wave VERSION \([0-9.]*\).*/\1/p' "$REPO/CMakeLists.txt")"
[ -n "$VERSION" ] || { echo "no version found in CMakeLists.txt" >&2; exit 1; }

# ── The build itself, as run inside the container ────────────────────────────
# /src is the source tree (read-only), /out is dist/ on the host, and
# QT_PREFIX is set by the image.
read -r -d '' INNER <<'INNER_EOF' || true
set -euo pipefail

QT="${QT_PREFIX:?the image sets QT_PREFIX}"
BUILD=/build/appimage
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"
OUT="tidal-wave-${TW_VERSION:?}-x86_64.AppImage"
rm -rf "$BUILD"
mkdir -p "$TOOLS"

echo "=== toolchain ==="
cmake --version | head -1
c++ --version | head -1
echo "Qt $("$QT/bin/qmake" -query QT_VERSION)"
ldd --version | sed -n 1p

echo "=== packaging tools ==="
# Each tool is pinned to a release and checked against the hash recorded here.
fetch() {
    local url="$1" sum="$2" file="$TOOLS/${1##*/}"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sum  $file" | sha256sum -c -
    chmod +x "$file"
}
fetch https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage \
    c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
fetch https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage \
    15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
    ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
# The runtime is passed to appimagetool, which would otherwise download the
# newest one at build time.
fetch https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
    2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

# There is no FUSE in a container, so the tools unpack themselves to run.
export APPIMAGE_EXTRACT_AND_RUN=1
export PATH="$TOOLS:$PATH"

echo "=== build ==="
cmake -S /src -B "$BUILD/cmake" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DTIDALWAVE_REQUIRE_TRANSLATIONS=ON
cmake --build "$BUILD/cmake" --parallel "$(nproc)"

echo "=== install into the AppDir ==="
# The install rules place the binary, the desktop entry, both icons and the
# metainfo file. Nothing of that is copied by hand here.
DESTDIR="$APPDIR" cmake --install "$BUILD/cmake"
for installed in \
    bin/tidal-wave \
    share/applications/io.github.immineal.TidalWave.desktop \
    share/icons/hicolor/128x128/apps/tidal-wave.png \
    share/icons/hicolor/scalable/apps/tidal-wave.svg \
    share/metainfo/io.github.immineal.TidalWave.metainfo.xml
do
    [ -f "$APPDIR/usr/$installed" ] || { echo "ERROR: cmake --install did not place usr/$installed" >&2; exit 1; }
done

echo "=== deploy Qt ==="
# LD_LIBRARY_PATH because the installed binary has no RUNPATH yet, so nothing
# else tells linuxdeploy where the Qt libraries are. Its "Missing qml module:
# TidalWave" is expected: that module is compiled into the binary.
export QMAKE="$QT/bin/qmake"
export QML_SOURCES_PATHS=/src/qml
export EXTRA_PLATFORM_PLUGINS="libqwayland.so;libqoffscreen.so"
export LD_LIBRARY_PATH="$QT/lib"
linuxdeploy-x86_64.AppImage --appdir "$APPDIR" --plugin qt

echo "=== what the deployment has to contain ==="
# The import scanner and the plugin deployer see only what is linked or
# imported by name. Each path is asserted, and copied from Qt when missing.
checked=0
copied_elf=()
need() {
    local rel="$1"
    checked=$((checked + 1))
    [ -e "$APPDIR/usr/$rel" ] && return 0
    [ -e "$QT/$rel" ] || { echo "ERROR: $rel is missing from the AppDir and from $QT" >&2; exit 1; }
    mkdir -p "$(dirname "$APPDIR/usr/$rel")"
    cp -L "$QT/$rel" "$APPDIR/usr/$rel"
    echo "copied: $rel"
    case "$rel" in *.so|*.so.*) copied_elf+=("$APPDIR/usr/$rel") ;; esac
}
need_dir() {
    local rel="$1" file
    [ -d "$QT/$rel" ] || { echo "ERROR: $QT/$rel does not exist" >&2; exit 1; }
    while IFS= read -r file; do
        need "${file#"$QT"/}"
    done < <(find "$QT/$rel" -type f ! -name '*.debug' | sort)
}

# Controls styles are chosen at run time: Fusion in src/ui/Application.cpp,
# with Basic as its fallback.
need_dir qml/QtQuick/Controls/Fusion
need_dir qml/QtQuick/Controls/Basic
need_dir qml/QtQuick/Controls/impl
need     qml/QtQuick/Controls/qmldir
# Platform plugins are chosen by the session. Wayland loads its shell, EGL and
# decoration plugins from three further directories. Offscreen is what
# packaging/verify-appimage.sh runs on.
need     plugins/platforms/libqxcb.so
need_dir plugins/xcbglintegrations
need     plugins/platforms/libqwayland.so
need_dir plugins/wayland-shell-integration
need_dir plugins/wayland-graphics-integration-client
need_dir plugins/wayland-decoration-client
need     plugins/platforms/libqoffscreen.so
# Playback, with the FFmpeg libraries from Qt's lib directory. Then cover art,
# icons and HTTPS.
need     plugins/multimedia/libffmpegmediaplugin.so
for lib in $(objdump -p "$QT/plugins/multimedia/libffmpegmediaplugin.so" \
        | awk '$1 == "NEEDED" && $2 ~ /^lib(av|sw)/ { print $2 }'); do
    need "lib/$lib"
done
need     plugins/imageformats/libqjpeg.so
need     plugins/imageformats/libqsvg.so
need     plugins/iconengines/libqsvgicon.so
need     plugins/tls/libqopensslbackend.so
echo "$checked files checked, ${#copied_elf[@]} libraries copied"

if [ "${#copied_elf[@]}" -gt 0 ]; then
    echo "=== dependencies of what was copied ==="
    linuxdeploy-x86_64.AppImage --appdir "$APPDIR" "${copied_elf[@]/#/--deploy-deps-only=}"
fi
unset LD_LIBRARY_PATH

echo "=== entry point ==="
# linuxdeploy wraps AppRun in a script that sources a plugin hook naming a
# Qt 5 platform theme. The AppRun written here replaces both.
rm -rf "$APPDIR/AppRun" "$APPDIR/AppRun.wrapped" "$APPDIR/apprun-hooks"
cat > "$APPDIR/AppRun" <<'APPRUN_EOF'
#!/bin/sh
# The binary is started by its real path because argv[0] names the X11
# WM_CLASS that StartupWMClass has to match. XDG_DATA_DIRS is left alone: the
# tray is drawn by the desktop, which has to find the icon by name itself.
here="$(dirname "$(readlink -f "$0")")"
exec "$here/usr/bin/tidal-wave" "$@"
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

echo "=== what the bundle asks of the host ==="
# Every library a bundled file links must be reachable through that file's
# RUNPATH, or be on this list. ldd cannot tell: this container has them all.
# OpenSSL 3 is not listed because Qt loads it at run time.
HOST_LIBS=" ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0 \
libresolv.so.2 libgcc_s.so.1 libstdc++.so.6 libEGL.so.1 libGL.so.1 \
libfontconfig.so.1 libfreetype.so.6 libX11.so.6 libX11-xcb.so.1 libxcb.so.1 \
libwayland-client.so.0 libdrm.so.2 libz.so.1 libcom_err.so.2 libgpg-error.so.0 "
asked=""
stray=0
while IFS= read -r elf; do
    dynamic="$(objdump -p "$elf" 2>/dev/null || true)"
    runpath="$(awk '$1 == "RUNPATH" || $1 == "RPATH" { print $2 }' <<<"$dynamic")"
    runpath="${runpath//\$\{ORIGIN\}/$(dirname "$elf")}"
    runpath="${runpath//\$ORIGIN/$(dirname "$elf")}"
    for lib in $(awk '$1 == "NEEDED" { print $2 }' <<<"$dynamic"); do
        found=0
        for dir in ${runpath//:/ }; do
            [ -e "$dir/$lib" ] && found=1
        done
        [ "$found" = 1 ] && continue
        case "$HOST_LIBS" in
            *" $lib "*) asked="$asked $lib" ;;
            *) echo "${elf#"$APPDIR"/} links $lib: not bundled, not expected of the host"; stray=1 ;;
        esac
    done
done < <(find "$APPDIR/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/usr/bin/*' \) | sort)
echo "from the host: $(printf '%s\n' $asked | sort -u | tr '\n' ' ')"
[ "$stray" = 0 ] || { echo "ERROR: the bundle is incomplete" >&2; exit 1; }

echo "=== symbol version floors ==="
# The newest glibc and libstdc++ symbol versions any bundled file asks for.
floor() {
    { find "$APPDIR" -type f -exec objdump -T {} + 2>/dev/null || true; } \
        | grep -o "$1_[0-9][0-9.]*" | sort -uV | tail -n 1
}
echo "glibc:     $(floor GLIBC)"
echo "libstdc++: $(floor GLIBCXX)"

echo "=== AppImage ==="
ARCH=x86_64 appimagetool-x86_64.AppImage --runtime-file "$TOOLS/runtime-x86_64" "$APPDIR" "$BUILD/$OUT"

mkdir -p /out
cp -v "$BUILD/$OUT" /out/
INNER_EOF

if [ "$REBUILD_IMAGE" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> building $IMAGE"
    docker build -t "$IMAGE" -f "$SELF/Dockerfile.appimage" "$SELF"
fi

mkdir -p "$REPO/dist"

# As the invoking user, so the AppImage in dist/ is not owned by root.
echo "==> building the AppImage in $IMAGE"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e XDG_RUNTIME_DIR=/tmp \
    -e TW_VERSION="$VERSION" \
    -v "$REPO:/src:ro" \
    -v "$REPO/dist:/out" \
    "$IMAGE" bash -c "$INNER"

echo
echo "==> artifacts in $REPO/dist"
ls -l "$REPO/dist"
