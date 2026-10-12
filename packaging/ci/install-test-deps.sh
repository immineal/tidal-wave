#!/bin/sh
# Installs what a distribution needs to build the program and run its tests
# with its own Qt, as root in a fresh container. Beyond the build: the QML
# modules, PulseAudio, dbus-daemon, ffmpeg, and a font for the layout tests.
set -eu

# shellcheck source=/dev/null
. /etc/os-release

case " $ID ${ID_LIKE:-} " in
*" debian "*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # Where libasound2 is a virtual name with two providers, apt wants one named.
    alsa=libasound2
    if apt-cache show libasound2t64 > /dev/null 2>&1; then alsa=libasound2t64; fi
    apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build pkg-config git ca-certificates \
        qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-svg-dev \
        qt6-tools-dev qt6-tools-dev-tools \
        libavahi-client-dev \
        qml6-module-qtquick qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts qml6-module-qtquick-shapes \
        qml6-module-qtquick-templates qml6-module-qtquick-window \
        qml6-module-qtqml-workerscript \
        "$alsa" pulseaudio dbus-daemon ffmpeg fonts-dejavu-core
    ;;
*" fedora "*)
    dnf install -y --setopt=install_weak_deps=False \
        gcc-c++ cmake ninja-build pkgconf-pkg-config git-core \
        qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel \
        qt6-qtsvg-devel qt6-qttools-devel \
        avahi-devel alsa-lib \
        pulseaudio dbus-daemon ffmpeg-free default-fonts-core-sans
    ;;
*" arch "*)
    pacman -Syu --noconfirm --needed \
        base-devel cmake ninja git \
        qt6-base qt6-declarative qt6-multimedia qt6-multimedia-ffmpeg \
        qt6-svg qt6-tools \
        avahi alsa-lib \
        pulseaudio dbus ffmpeg ttf-dejavu
    ;;
*" suse "*)
    zypper --non-interactive install --no-recommends \
        gcc-c++ cmake ninja pkgconf-pkg-config git-core \
        qt6-base-devel qt6-declarative-devel qt6-multimedia-devel \
        qt6-svg-devel qt6-linguist-devel qt6-quickcontrols2-devel \
        qt6-quicktest-devel qt6-test-devel qt6-widgets-devel qt6-dbus-devel \
        qt6-network-devel qt6-qmlmodels-devel \
        avahi-devel alsa \
        pulseaudio dbus-1-daemon ffmpeg dejavu-fonts
    ;;
*)
    echo "install-test-deps.sh: no package list for '$ID'" >&2
    exit 1
    ;;
esac
