# Build toolchain for the release .deb.
#
# Why a container at all: the depends list in CMakeLists.txt derives its floors
# from the toolchain that configured the build - the Qt's own version for every
# libqt6*/qml6-module-* entry, and the compiler's major for libstdc++6. Built on
# a rolling dev box (Qt 6.12, GCC 16) that is honest and useless: the package
# correctly refuses to install on anything older, which is nearly everything.
# Built here it asks for Qt 6.4 and libstdc++ 12, which is the oldest toolchain
# we mean to support and the floor almost every live Debian/Ubuntu clears.
#
# bookworm pins the whole story: Qt 6.4.2 and GCC 12.2. Nothing below is pinned
# to a dev machine and no Qt is downloaded - apt owns it, which also makes
# dpkg-shlibdeps able to resolve the Qt libraries for the first time (on the dev
# box they live in ~/Qt and no package owns them, so it contributes nothing).
#
# This image carries build deps only. The source tree is bind-mounted at build
# time by packaging/build-deb.sh, so changing a source file does not rebuild it.
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

# Qt 6.4.2 development packages, one per component the top-level
# find_package(Qt6 ...) asks for:
#   qt6-base-dev        Core Gui Widgets Network DBus Concurrent  (+ Test)
#   qt6-declarative-dev Quick Qml QmlModels                       (+ QuickTest)
#   qt6-multimedia-dev  Multimedia
#   qt6-svg-dev         Svg
#   qt6-tools-dev{,-tools}  LinguistTools - optional in CMakeLists, but without
#                       it the build warns and ships no German catalogue, which
#                       is not what a release should do.
# libavahi-client-dev is the Chromecast mDNS discovery dependency (Linux only).
RUN apt-get update && apt-get install -y --no-install-recommends \
        qt6-base-dev \
        qt6-declarative-dev \
        qt6-multimedia-dev \
        qt6-svg-dev \
        qt6-tools-dev \
        qt6-tools-dev-tools \
        libavahi-client-dev \
    && rm -rf /var/lib/apt/lists/*

# Runtime QML modules. The app's own QML is embedded in its resources, but the
# modules it imports are not, so without these the test suite's QML half and any
# in-container launch fail at import rather than at link. These are the same
# qml6-module-* packages the generated Depends list names.
RUN apt-get update && apt-get install -y --no-install-recommends \
        qml6-module-qtquick \
        qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts \
        qml6-module-qtquick-shapes \
        qml6-module-qtquick-templates \
        qml6-module-qtquick-window \
        qml6-module-qtqml-workerscript \
        libasound2 \
        gstreamer1.0-plugins-good \
    && rm -rf /var/lib/apt/lists/*

# gstreamer1.0-plugins-good above is not a build dependency and not optional
# either. Qt 6.4 still defaults to the GStreamer media backend (6.5 switched the
# default to FFmpeg, which is why this never shows up on a newer Qt), and with
# only plugins-base installed the pipeline Qt builds gets a null element:
#     GStreamer-CRITICAL: gst_element_link_many: assertion 'GST_IS_ELEMENT
#     (element_2)' failed
# followed by a segfault the moment anything touches QMediaPlayer. That takes
# out four of the test binaries here, and it will take out the installed app on
# any minimal bookworm, because nothing in the generated Depends list pulls it
# in - see the note in the report accompanying this change.

# Every Qt GUI binary in here runs headless - no X, no Wayland. Setting it in
# the image means a forgotten environment variable cannot open a window.
ENV QT_QPA_PLATFORM=offscreen

# build-deb.sh runs the container as the invoking user, so the artifacts it
# writes to the mounted dist/ are not root-owned on the host. That uid exists
# nowhere in here, so the build tree has to be writable by anyone.
RUN mkdir -p /build && chmod 0777 /build
WORKDIR /build
