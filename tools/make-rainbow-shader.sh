#!/bin/sh
# Bake assets/toggle-rainbow.frag into the committed .qsb the colour switch
# loads (qml/components/Toggle.qml). Only needed after editing the shader.
#
# The pack is baked as QSB version 6.4, the oldest Qt the app supports; every
# later Qt reads older packs, so one file serves 6.4 to the newest and the
# build needs no Qt ShaderTools. Any qsb from Qt 6.6 on can write it.
#
# Usage: tools/make-rainbow-shader.sh [path/to/qsb]
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
qsb=${1:-$(command -v qsb || echo /usr/lib64/qt6/bin/qsb)}
"$qsb" --qt6 --qsbversion 64 -o "$repo/assets/toggle-rainbow.frag.qsb" \
    "$repo/assets/toggle-rainbow.frag"
echo "wrote assets/toggle-rainbow.frag.qsb with $("$qsb" --version)"
