#!/usr/bin/env bash
# Validate the desktop entry and the AppStream metainfo that Linux stores read,
# and check they still agree with the project.
#
#     packaging/validate-store-metadata.sh [--no-net] [--tag vX.Y.Z]
#
# Without --no-net, appstreamcli fetches every <url> and screenshot and fails
# on a missing one. The screenshots point at the release tag, so before the
# tag exists only --no-net can pass. --tag also checks that every screenshot
# names that tag. Needs appstreamcli and desktop-file-validate.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF/.."

NET=1
TAG=
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        --no-net) NET=0 ;;
        --tag) TAG="${2:?--tag needs a tag name}"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

id=io.github.immineal.TidalWave
# Named after the app id: Flatpak exports only <app-id>.desktop.
desktop="packaging/$id.desktop"
template="packaging/$id.metainfo.xml.in"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
metainfo="$out/$id.metainfo.xml"

# --warn-kde: Plasma is where this app's tray lives.
desktop-file-validate --warn-kde "$desktop"
echo "desktop-file-validate: clean"

# The file in the tree is a configure_file() template: substitute the
# version as CMakeLists.txt does and validate what is installed.
ver=$(sed -n 's/^project(tidal-wave VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt)
test -n "$ver" || { echo "no version found in CMakeLists.txt"; exit 1; }
echo "project() version: $ver"
sed "s/@PROJECT_VERSION@/$ver/g" "$template" > "$metainfo"
if grep -q '@[A-Z_]*@' "$metainfo"; then
    echo "a @PLACEHOLDER@ survived substitution:"
    grep -n '@[A-Z_]*@' "$metainfo"
    exit 1
fi

# --pedantic only adds hints to the log; appstreamcli exits non-zero on
# errors and warnings alone.
if [ "$NET" -eq 1 ]; then
    appstreamcli validate --explain --pedantic "$metainfo"
else
    echo "--no-net: the URLs and screenshots are not fetched"
    appstreamcli validate --explain --pedantic --no-net "$metainfo"
fi

# 1. AppStream pairs a metainfo file with its component by filename, so
#    <id> and the installed basename have to be the same string.
grep -q "<id>$id</id>" "$metainfo" \
    || { echo "<id> does not match the filename $id.metainfo.xml"; exit 1; }
# 2. <launchable> has to name the desktop entry as installed. If it
#    does not, the store lists an app with no way to start it.
want=$(sed -n 's@.*<launchable type="desktop-id">\(.*\)</launchable>.*@\1@p' "$metainfo")
test "$want" = "$(basename "$desktop")" \
    || { echo "<launchable> says '$want', we install '$(basename "$desktop")'"; exit 1; }
# 3. The version must not be a second copy of project()'s. The template
#    has to defer to CMake for it, and the PKGBUILD cannot (pkgver is
#    needed before any source is fetched), so it is checked instead.
grep -q 'version="@PROJECT_VERSION@"' "$template" \
    || { echo "$template hardcodes a version instead of taking @PROJECT_VERSION@"; exit 1; }
pkgver=$(sed -n 's/^pkgver=//p' packaging/PKGBUILD)
test "$pkgver" = "$ver" \
    || { echo "packaging/PKGBUILD says pkgver=$pkgver, project() says $ver"; exit 1; }

# 4. A store shows the screenshots of the tag they name, so a release whose
#    URLs still name an older tag would show an older app.
if [ -n "$TAG" ]; then
    stale=$(grep -o '<image>[^<]*</image>' "$metainfo" | grep -v "/$TAG/" || true)
    if [ -n "$stale" ]; then
        echo "screenshots that do not name $TAG:"
        echo "$stale"
        exit 1
    fi
    echo "every screenshot names $TAG"
fi

echo "id, launchable and version all agree"
