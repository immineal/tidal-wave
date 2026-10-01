// QtQuickTest runner for the stress suite (HANDOFF section I, SPEC X4/X5/X6).
//
// Same idea as tests/tst_qml.cpp, with two additions that the stress cases
// need and the layout tests do not:
//
//   * the real Prefs and the real I18n are installed as the `prefs` and `i18n`
//     context properties, and Prefs is wired into the ThemePalette singleton,
//     exactly as Application::run() does it. Theme switching and language
//     switching cannot be exercised without them: ThemePalette::current only
//     moves when Prefs::theme moves, and qsTr() only re-evaluates when
//     I18n::apply() calls QQmlEngine::retranslate().
//
//   * the QSettings identity is deliberately *not* the app's. A stress run
//     writes a theme and a language several hundred times; if the sandbox the
//     script builds ever failed to isolate HOME, writing under the app's own
//     organisation and application name would overwrite the developer's live
//     settings. A different pair cannot, whatever happens to the sandbox.
//
// Everything else (auth, bridge, player, downloader, cast, app and the offline
// "tidal" image provider) comes from tests/TestStubs.h unchanged.

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
        // Before any QSettings is constructed. See the note above.
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
