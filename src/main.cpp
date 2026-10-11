// SPDX-License-Identifier: GPL-3.0-or-later

#include "ui/Application.h"
#include <QApplication>
#include <QByteArray>

namespace {

// Qt below 6.5 defaults to GStreamer, which crashes on a system without its
// plugins. The FFmpeg plugin ships inside the Qt multimedia package. A backend
// the user set in the environment wins.
void preferFfmpegMediaBackendOnQt64() {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
        qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif
}

} // namespace

int main(int argc, char **argv) {
    // Before the QApplication: QtMultimedia resolves its backend off the
    // environment, and nothing should be able to read it first.
    preferFfmpegMediaBackendOnQt64();

    // Also before it: Qt reads the scale factor once, while the QApplication
    // is constructed.
    Application::applyScaleFactor();

    QApplication qapp(argc, argv);
    Application app;
    return app.run(argc, argv);
}
