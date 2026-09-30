// QtQuickTest runner for the tst_qml target: it discovers tests/qml/tst_*.qml
// (QUICK_TEST_SOURCE_DIR, set in tests/CMakeLists.txt) and runs each TestCase.
//
// The setup object below installs the same context properties the app installs
// in Application::run() — auth, bridge, player, downloader, cast, app — as the
// stubs from TestStubs.h, so pages out of the TidalWave module instantiate
// without a live Tidal session, network access, or an audio backend.

#include <QtQuickTest/quicktest.h>

#include <QObject>
#include <QQmlEngine>

#include "TestStubs.h"

class QmlTestSetup : public QObject {
    Q_OBJECT

public:
    QmlTestSetup() = default;

public slots:
    // Called by QtQuickTest once per QML test file, before that file is loaded.
    void qmlEngineAvailable(QQmlEngine *engine) {
        m_stubs = installTestStubs(engine, this);
    }

private:
    TestStubs m_stubs;
};

QUICK_TEST_MAIN_WITH_SETUP(tidalwave, QmlTestSetup)
#include "tst_qml.moc"
