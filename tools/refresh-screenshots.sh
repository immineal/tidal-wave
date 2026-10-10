#!/usr/bin/env bash
# Draw the five store screenshots from the invented library and put them where
# the README and the AppStream metainfo read them.
#
# Usage:
#   tools/refresh-screenshots.sh              # draw, then copy into assets/
#   tools/refresh-screenshots.sh --dry-run    # draw, and print what it would copy
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ "${1:-}" = "-n" ] && DRY=1

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo/tests/visual/out"
assets="$repo/assets"
shots=(home collection album nowplaying search)

# A skipped run exits 0 and writes nothing, so pictures left by an earlier one
# must not be there to be mistaken for this one's.
for s in "${shots[@]}"; do rm -f "$out/store_$s.png"; done

if ! "$repo/tests/visual/run.sh" store; then
    echo "the store set did not run clean; assets/ is untouched" >&2
    exit 1
fi

for s in "${shots[@]}"; do
    if [ ! -s "$out/store_$s.png" ]; then
        echo "store_$s.png was not drawn; assets/ is untouched" >&2
        exit 1
    fi
done

echo
for s in "${shots[@]}"; do
    src="$out/store_$s.png"
    dst="$assets/screenshot_$s.png"
    if cmp -s "$src" "$dst"; then
        echo "unchanged: assets/screenshot_$s.png"
    elif [ "$DRY" = 1 ]; then
        echo "would write: assets/screenshot_$s.png"
    else
        cp -f "$src" "$dst"
        echo "wrote: assets/screenshot_$s.png"
    fi
done
