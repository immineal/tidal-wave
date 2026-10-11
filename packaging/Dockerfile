# Build toolchain for the release .deb. CMakeLists.txt derives the package's
# dependency floors from the toolchain that configured the build, so the
# release is built on the oldest one supported: bookworm, Qt 6.4.2, GCC 12.2.
# Qt comes from apt, which lets dpkg-shlibdeps resolve it. Build deps only:
# packaging/build-deb.sh bind-mounts the source tree at build time.
FROM debian:bookworm

# Keep apt from asking anything and from keeping its lists in the layer.
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        file \
        dpkg-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# One package per component find_package(Qt6 ...) asks for. qt6-tools-dev is
# LinguistTools: without it the build ships no German catalogue.
# libavahi-client-dev is for Chromecast discovery.
RUN apt-get update && apt-get install -y --no-install-recommends \
        qt6-base-dev \
        qt6-declarative-dev \
        qt6-multimedia-dev \
        qt6-svg-dev \
        qt6-tools-dev \
        qt6-tools-dev-tools \
        libavahi-client-dev \
    && rm -rf /var/lib/apt/lists/*

# Runtime QML modules: the app's own QML is embedded, the modules it imports
# are not, so tests fail at import without them. The same qml6-module-*
# packages as the generated Depends list.
RUN apt-get update && apt-get install -y --no-install-recommends \
        qml6-module-qtquick \
        qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts \
        qml6-module-qtquick-shapes \
        qml6-module-qtquick-templates \
        qml6-module-qtquick-window \
        qml6-module-qtqml-workerscript \
        libasound2 \
        pulseaudio \
        dbus-daemon \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# The last three are what the tests need at run time. Qt 6.4's FFmpeg backend
# crashes without an audio device, so tests/with-null-sink.sh gives it a silent
# one. dbus-daemon serves the session bus test, ffmpeg the cast preparation.

# Every Qt GUI binary in here runs headless - no X, no Wayland. Setting it in
# the image means a forgotten environment variable cannot open a window.
ENV QT_QPA_PLATFORM=offscreen

# build-deb.sh runs the container as the invoking user, so the artifacts it
# writes to the mounted dist/ are not root-owned on the host. That uid exists
# nowhere in here, so the build tree has to be writable by anyone.
RUN mkdir -p /build && chmod 0777 /build
WORKDIR /build
