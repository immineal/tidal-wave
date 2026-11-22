// SPDX-License-Identifier: GPL-3.0-or-later

#include "QtRuntime.h"

#include <QLibraryInfo>
#include <QVersionNumber>
#include <QtGlobal>
#include <atomic>

namespace {

std::atomic<int> g_testVersion{0};

int loadedVersion() {
    // Static: QLibraryInfo needs no application object, and main() asks
    // before there is one.
    static const int packed = [] {
        const QVersionNumber v = QLibraryInfo::version();
        return QT_VERSION_CHECK(v.majorVersion(), v.minorVersion(), v.microVersion());
    }();
    return packed;
}

} // namespace

int QtRuntime::version() {
    const int pretended = g_testVersion.load(std::memory_order_relaxed);
    return pretended ? pretended : loadedVersion();
}

void QtRuntime::setVersionForTests(int version) {
    g_testVersion.store(version, std::memory_order_relaxed);
}
