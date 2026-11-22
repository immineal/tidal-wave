// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include "QtRuntime.h"
#include <QString>
#include <QVersionNumber>

// The app's code under test takes the Qt it runs on to be this one, for as
// long as the object lives. An empty version leaves the real one.
struct QtRuntimeAs {
    explicit QtRuntimeAs(const QString &version) {
        const QVersionNumber v = QVersionNumber::fromString(version);
        if (!v.isNull())
            QtRuntime::setVersionForTests(
                QT_VERSION_CHECK(v.majorVersion(), v.minorVersion(), v.microVersion()));
    }
    ~QtRuntimeAs() { QtRuntime::setVersionForTests(0); }
    QtRuntimeAs(const QtRuntimeAs &) = delete;
    QtRuntimeAs &operator=(const QtRuntimeAs &) = delete;
};
