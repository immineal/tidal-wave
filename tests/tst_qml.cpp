// QtQuickTest runner: discovers tests/qml/tst_*.qml and runs each TestCase.
// The setup object installs the stubs from TestStubs.h as the context
// properties the app installs, so pages load without a Tidal session, the
// network or an audio backend.

#include <QtQuickTest/quicktest.h>

#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>

#include "A11yProbe.h"
#include "TestStubs.h"

class QmlTestSetup : public QObject {
    Q_OBJECT

public:
    QmlTestSetup() = default;

public slots:
    // Called by QtQuickTest once per QML test file, before that file is loaded.
    void qmlEngineAvailable(QQmlEngine *engine) {
        m_stubs = installTestStubs(engine, this);
        engine->rootContext()->setContextProperty(QStringLiteral("a11y"), &m_a11y);
    }

private:
    TestStubs m_stubs;
    A11yProbe m_a11y;
};

QUICK_TEST_MAIN_WITH_SETUP(tidalwave, QmlTestSetup)
#include "tst_qml.moc"
