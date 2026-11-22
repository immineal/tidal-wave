// SPDX-License-Identifier: GPL-3.0-or-later

#include "ui/Application.h"
#include "ui/RemoteControl.h"
#include <QApplication>
#include <QCoreApplication>

#include <cstdio>

int main(int argc, char **argv) {
    // Answered without a display: the scale probe below opens one, and a
    // terminal on another machine or a build box may have none.
    if (RemoteControl::asksForInfoOnly(argc, argv)) {
        QCoreApplication info(argc, argv);
        QCoreApplication::setApplicationName(QStringLiteral("Tidal Wave"));
        QCoreApplication::setApplicationVersion(QStringLiteral(TIDALWAVE_VERSION));
        const RemoteControl::Parsed parsed = RemoteControl::parseArguments(info.arguments());
        std::fputs(parsed.output.toLocal8Bit().constData(), stdout);
        std::fputs(parsed.error.toLocal8Bit().constData(), stderr);
        return parsed.exitCode;
    }

    // Before the QApplication: QtMultimedia resolves its backend off the
    // environment, and nothing should be able to read it first.
    Application::preferFfmpegMediaBackend();

    // Also before it: Qt reads the scale factor once, while the QApplication
    // is constructed.
    Application::applyScaleFactor();

    // Before Application::run() builds the QML engine, which reads it once.
    Application::useWholeHeapQmlCollector();

    QApplication qapp(argc, argv);
    Application app;
    return app.run(argc, argv);
}
