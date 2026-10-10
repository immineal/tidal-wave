// QtQuickTest runner for the stress suite. Like tests/tst_qml.cpp, plus the
// real Prefs and I18n as context properties, with Prefs wired into
// ThemePalette as Application::run() does: theme and language switching need
// them. The QSettings identity is deliberately not the app's, so a failed
// sandbox cannot overwrite live settings. Everything else comes from
// tests/TestStubs.h unchanged.

#include <QtQuickTest/quicktest.h>

#include <QCoreApplication>
#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>

#include "TestStubs.h"

#include "I18n.h"
#include "Prefs.h"
#include "ThemePalette.h"

class StressSetup : public QObject {
    Q_OBJECT

public:
    StressSetup() {
        // Before any QSettings is constructed: see the file header.
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveStress"));
        QCoreApplication::setApplicationName(QStringLiteral("Tidal Wave Stress"));
    }

public slots:
    // Called by QtQuickTest once per QML test file, before that file is loaded.
    void qmlEngineAvailable(QQmlEngine *engine) {
        installTestStubs(engine, this);

        m_prefs = new Prefs(this);
        m_i18n  = new I18n(m_prefs, this);
        m_i18n->setEngine(engine);
        ThemePalette::instance()->setPrefs(m_prefs);

        QQmlContext *ctx = engine->rootContext();
        ctx->setContextProperty(QStringLiteral("prefs"), m_prefs);
        ctx->setContextProperty(QStringLiteral("i18n"), m_i18n);
    }

private:
    Prefs *m_prefs = nullptr;
    I18n  *m_i18n  = nullptr;
};

QUICK_TEST_MAIN_WITH_SETUP(tidalwave_stress, StressSetup)
#include "tst_stress_main.moc"
