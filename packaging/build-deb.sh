#!/usr/bin/env bash
# Build the release .deb in a Debian 12 (bookworm) container.
#
#     packaging/build-deb.sh                  # build, package, check the floors
#     packaging/build-deb.sh --tests          # also build and run the test suite
#     packaging/build-deb.sh --rebuild-image
#
# The .deb lands in dist/ at the repo root. The dependency floors come from the
# configuring toolchain, so a build on a newer host installs nowhere; see
# packaging/Dockerfile. Any failure exits non-zero and leaves dist/ untouched.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
IMAGE="tidal-wave-build:bookworm"

TW_TESTS=OFF
REBUILD_IMAGE=0
for arg in "$@"; do
    case "$arg" in
        --tests)         TW_TESTS=ON ;;
        --rebuild-image) REBUILD_IMAGE=1 ;;
        -h|--help)       sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ── The build itself, as run inside the container ────────────────────────────
# /src is the source tree (read-only), /out is dist/ on the host. The build
# tree is container-local, so no host CMake cache can leak in.
read -r -d '' INNER <<'INNER_EOF' || true
set -euo pipefail

echo "=== toolchain ==="
cmake --version | head -1
c++ --version | head -1
dpkg-query -W 'qt6-base-dev' | head -1

BUILD=/build/pkg
rm -rf "$BUILD"

# No CMAKE_PREFIX_PATH: Qt comes from apt. REQUIRE_TRANSLATIONS makes a missing
# lrelease a configure error, since the package would ship English only.
cmake -S /src -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DTIDALWAVE_REQUIRE_TRANSLATIONS=ON \
    -DTIDALWAVE_BUILD_TESTS="${TW_TESTS:-OFF}"

cmake --build "$BUILD" --parallel "$(nproc)"

if [ "${TW_TESTS:-OFF}" = "ON" ]; then
    echo "=== ctest ==="
    # By absolute path: a ctest shim on PATH can exit 0 without running
    # anything. A run that finds no tests is a failure for the same reason.
    CTEST=/usr/bin/ctest
    "$CTEST" --version | head -1
    n=$("$CTEST" --test-dir "$BUILD" -N 2>/dev/null | sed -n 's/^Total Tests: //p')
    echo "ctest sees ${n:-0} tests"
    if [ "${n:-0}" -lt 1 ]; then
        echo "ERROR: ctest reports no tests - refusing to call that a pass" >&2
        exit 1
    fi
    rc=0
    "$CTEST" --test-dir "$BUILD" --output-on-failure || rc=$?
    echo "ctest exit: $rc"
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: the test suite failed, so no package is built" >&2
        exit "$rc"
    fi
fi

echo "=== cpack ==="
/usr/bin/cpack --version | head -1
( cd "$BUILD" && /usr/bin/cpack -G DEB )

# Taken from the build tree: dist/ may still hold packages of other versions.
deb=$(find "$BUILD" -maxdepth 1 -name '*.deb')
if [ "$(printf '%s\n' "$deb" | grep -c .)" -ne 1 ]; then
    echo "ERROR: expected one .deb in $BUILD, found: ${deb:-none}" >&2
    exit 1
fi

echo "=== generated control fields ==="
dpkg-deb -f "$deb" Package Version Architecture Installed-Size
echo "Depends:"; dpkg-deb -f "$deb" Depends | tr ',' '\n' | sed 's/^ */  /'
echo "Recommends:"; dpkg-deb -f "$deb" Recommends

echo "=== dependency floors ==="
# Before the copy, so a package with the wrong floors never reaches dist/.
/src/packaging/assert-deb-floors.sh "$deb"

mkdir -p /out
cp -v "$deb" /out/
INNER_EOF

if [ "$REBUILD_IMAGE" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> building $IMAGE"
    docker build -t "$IMAGE" -f "$SELF/Dockerfile" "$SELF"
fi

mkdir -p "$REPO/dist"

# As the invoking user, so the package in dist/ is not owned by root.
echo "==> building the package in $IMAGE"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e XDG_RUNTIME_DIR=/tmp \
    -e QT_QPA_PLATFORM=offscreen \
    -e TW_TESTS="$TW_TESTS" \
    -v "$REPO:/src:ro" \
    -v "$REPO/dist:/out" \
    "$IMAGE" bash -c "$INNER"

echo
echo "==> artifacts in $REPO/dist"
ls -l "$REPO/dist"
