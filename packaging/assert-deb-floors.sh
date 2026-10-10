#!/usr/bin/env bash
# Check that a built .deb asks for the Qt and the C++ runtime of Debian 12.
#
#     packaging/assert-deb-floors.sh <package.deb | control file>
#
# CMakeLists.txt derives both floors from the toolchain that configured the
# build. A package built on anything newer than bookworm asks for more than
# Debian 12 and Ubuntu 24.04 have, and apt refuses it there.
#
# Exit status: 0 as expected, 1 a floor is missing or wrong, 2 bad argument.
set -euo pipefail

# What a bookworm build produces. These move with packaging/Dockerfile.
QT_FLOOR=6.4
STDCXX_FLOOR=12

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 <package.deb | control file>" >&2
    exit 2
fi

case "$1" in
    *.deb)
        DEPENDS="$(dpkg-deb -f "$1" Depends)"
        ;;
    *)
        # A control field can be folded over several indented lines.
        DEPENDS="$(awk '
            /^Depends:/    { on = 1; sub(/^Depends:[ \t]*/, ""); print; next }
            on && /^[ \t]/ { print; next }
                           { on = 0 }' "$1")"
        ;;
esac
if [ -z "$DEPENDS" ]; then
    echo "ERROR: no Depends field in $1" >&2
    exit 2
fi

# Every floor of package $1, cut to as many components as $2 is written with,
# so 6.4.0 reads as 6.4. dpkg-shlibdeps adds entries beside the CMake ones.
floors_of() {
    local parts
    parts="$(printf '%s' "$2" | tr -cd '.' | wc -c)"
    printf '%s\n' "$DEPENDS" | tr ',|' '\n' \
        | sed -n "s/^[[:space:]]*$1[[:space:]]*([[:space:]]*>[>=][[:space:]]*\([^)[:space:]]*\)[[:space:]]*)[[:space:]]*\$/\1/p" \
        | cut -d. -f"1-$((parts + 1))"
}

FAILED=0
check() {
    local pkg="$1" want="$2" found highest
    found="$(floors_of "$pkg" "$want")"
    highest="$(printf '%s\n' "$found" | sort -V | tail -n 1)"
    if [ -z "$found" ]; then
        echo "FAIL: $pkg carries no version floor"
    elif [ "$highest" = "$want" ]; then
        echo "ok: $pkg (>= $want)"
        return
    elif [ "$(printf '%s\n%s\n' "$highest" "$want" | sort -V | tail -n 1)" = "$highest" ]; then
        echo "FAIL: $pkg (>= $highest) is above the (>= $want) of Debian 12"
    else
        echo "FAIL: $pkg (>= $highest) is below the expected (>= $want)"
    fi
    FAILED=1
}

check 'libqt6core6' "$QT_FLOOR"
check 'libstdc++6' "$STDCXX_FLOOR"

if [ "$FAILED" -ne 0 ]; then
    echo "ERROR: wrong dependency floors. Build with packaging/build-deb.sh," >&2
    echo "       or update the two numbers in $(basename "$0") with the build base." >&2
    exit 1
fi
