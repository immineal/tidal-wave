#!/usr/bin/env bash
# Build the release .deb in a Debian 12 (bookworm) container.
#
# Run it from anywhere; it locates the repo from its own path:
#
#     packaging/build-deb.sh              # build, package, print Depends
#     packaging/build-deb.sh --tests       # also run ctest inside the container
#     packaging/build-deb.sh --rebuild-image
#
# The .deb lands in dist/ at the repo root, owned by the invoking user.
#
# Why not just build on the host: the depends floors in CMakeLists.txt come from
# the configuring toolchain, so a host build (Qt 6.12, GCC 16) demands
# libqt6core6 (>= 6.12) and libstdc++6 (>= 16) and installs nowhere. See
# packaging/Dockerfile for the long version.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
IMAGE="tidal-wave-build:bookworm"

RUN_TESTS=0
REBUILD_IMAGE=0
for arg in "$@"; do
    case "$arg" in
        --tests)         RUN_TESTS=1 ;;
        --rebuild-image) REBUILD_IMAGE=1 ;;
        -h|--help)       sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ── The build itself, as run inside the container ────────────────────────────
# Kept as a here-doc rather than a second file so there is one thing to read.
# /src is the bind-mounted source tree (read-only), /out is dist/ on the host,
# and the build tree is a fresh container-local directory every run - never the
# host's build dir, whose cache points at the host Qt.
read -r -d '' INNER <<'INNER_EOF' || true
set -euo pipefail

echo "=== toolchain ==="
cmake --version | head -1
c++ --version | head -1
dpkg-query -W 'qt6-base-dev' | head -1

BUILD=/build/pkg
rm -rf "$BUILD"

# No CMAKE_PREFIX_PATH: Qt comes from apt and is on the default search path.
# Pinning one here is exactly the dev-machine leak this container exists to
# avoid. Tests are on so the same configure can run them.
cmake -S /src -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DTIDALWAVE_BUILD_TESTS="${TW_TESTS:-ON}"

cmake --build "$BUILD" --parallel "$(nproc)"

if [ "${TW_RUN_TESTS:-0}" = "1" ]; then
    echo "=== ctest ==="
    # Debian's real ctest, by absolute path. The one on a dev box's PATH can be
    # a shim that exits 0 without running anything, so the count is printed and
    # a zero-test run is a failure here.
    CTEST=/usr/bin/ctest
    "$CTEST" --version | head -1
    n=$("$CTEST" --test-dir "$BUILD" -N 2>/dev/null | sed -n 's/^Total Tests: //p')
    echo "ctest sees ${n:-0} tests"
    if [ "${n:-0}" -lt 1 ]; then
        echo "ERROR: ctest reports no tests - refusing to call that a pass" >&2
        exit 1
    fi
    "$CTEST" --test-dir "$BUILD" --output-on-failure || TEST_RC=$?
    echo "ctest exit: ${TEST_RC:-0}"
fi

echo "=== cpack ==="
# Likewise absolute, and from the same cmake that configured the build.
/usr/bin/cpack --version | head -1
( cd "$BUILD" && /usr/bin/cpack -G DEB )

mkdir -p /out
find "$BUILD" -maxdepth 1 -name '*.deb' -exec cp -v {} /out/ \;

echo "=== generated control fields ==="
for deb in /out/*.deb; do
    echo "--- $deb"
    dpkg-deb -f "$deb" Package Version Architecture Installed-Size
    echo "Depends:"; dpkg-deb -f "$deb" Depends | tr ',' '\n' | sed 's/^ */  /'
    echo "Recommends:"; dpkg-deb -f "$deb" Recommends
done
INNER_EOF

if [ "$REBUILD_IMAGE" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> building $IMAGE"
    docker build -t "$IMAGE" -f "$SELF/Dockerfile" "$SELF"
fi

mkdir -p "$REPO/dist"

echo "==> building the package in $IMAGE"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e XDG_RUNTIME_DIR=/tmp \
    -e QT_QPA_PLATFORM=offscreen \
    -e TW_RUN_TESTS="$RUN_TESTS" \
    -v "$REPO:/src:ro" \
    -v "$REPO/dist:/out" \
    "$IMAGE" bash -c "$INNER"

echo
echo "==> artifacts in $REPO/dist"
ls -l "$REPO/dist"
