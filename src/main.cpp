#include "ui/Application.h"
#include <QApplication>
#include <QByteArray>

namespace {

// Qt 6.4 still defaults QtMultimedia to the GStreamer backend; 6.5 made FFmpeg
// the default. On a minimal Debian 12 that default is fatal: libqt6multimedia6
// pulls the GStreamer libraries but not gstreamer1.0-plugins-good, so the
// pipeline Qt assembles comes back with a null element, which it then links
// anyway -
//
//     GStreamer-CRITICAL: gst_element_link_many: assertion
//     'GST_IS_ELEMENT (element_2)' failed
//
// and the process dies with SIGSEGV the moment anything touches QMediaPlayer.
// Naming the backend here makes 6.4 behave like every Qt from 6.5 on, and it
// costs no dependency: libffmpegmediaplugin.so already ships inside
// libqt6multimedia6. Adding gstreamer1.0-plugins-good to the Depends list
// instead would be ~2 MB bought to keep the backend we are leaving behind.
//
// Only below 6.5 - on a newer Qt this is already the default and pinning it
// here would quietly undo a future change of it. And only when the environment
// is silent: QT_MEDIA_BACKEND is the documented way to choose a backend, so a
// user who has set it deliberately wins.
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

    // Likewise before it, and for the same kind of reason: Qt reads the scale
    // factor once while the QApplication is being constructed. On a desktop that
    // advertises a DPI this does nothing at all.
    Application::applyScaleFactor();

    QApplication qapp(argc, argv);
    Application app;
    return app.run(argc, argv);
}
