// First run, at the QML layer (HANDOFF section M).
//
// tests/firstrun/run.sh starts the real binary in a throwaway HOME for each
// environment the app supports, but headless it can only say "the process
// stayed up and printed nothing alarming". Whether the window that came up is
// the login page is something it can only answer from an X11 screenshot, by
// eye. This file makes that a real assertion, so CI catches it.
//
// What is covered here and nowhere else:
//   * Main.qml loads at all, against an empty settings file.
//   * A fresh install lands on the login page, not on a blank shell.
//   * That load produces no QML warnings, so an error in a binding cannot hide
//     behind a window that happens to appear anyway.
//   * A settings file that is corrupt, or written by a later version, still
//     gets a window. Prefs clamping itself is tst_prefs.cpp's job; what this
//     adds is that the QML on top of it survives the same input.
//
// Prefs, ThemePalette and the QSettings scope are the real ones, because they
// are the first-run behaviour under test. Everything that would need a network,
// a Tidal session, an audio device or D-Bus comes from TestStubs.h.
//
// Two fixture details worth knowing before editing this file:
//
//   * StubAuth defaults to a signed-in session (State::LoggedIn, saved
//     credentials, a username), which is what page tests want and the exact
//     opposite of a first run. Every test here drives it back to LoggedOut
//     first, or it would assert against the wrong screen.
//   * ThemePalette is a process-wide singleton holding a bare Prefs*, and
//     setPrefs() disconnects from the old one without checking that it is still
//     alive. A stack-allocated Prefs going out of scope between tests therefore
//     crashes the next setPrefs() call. Prefs is parented to the test object
//     here so it outlives the singleton's pointer.

#include <QTest>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>

#include "TestStubs.h"
#include "ui/Prefs.h"
#include "ui/ThemePalette.h"

namespace {

// Depth-first search for the Loader that pulls in a given page. Matching on the
// source url rather than on an object name keeps this working while qml/ is
// being reorganised.
QObject *loaderForPage(QObject *root, const QString &fileName) {
    if (!root) return nullptr;
    if (QString::fromLatin1(root->metaObject()->className()).startsWith(QLatin1String("QQuickLoader"))) {
        const QUrl src = root->property("source").toUrl();
        if (src.fileName() == fileName) return root;
    }
    for (QObject *child : root->children()) {
        if (QObject *hit = loaderForPage(child, fileName)) return hit;
    }
    return nullptr;
}

QString describe(const QList<QQmlError> &errors) {
    QStringList lines;
    for (const QQmlError &e : errors) lines << e.toString();
    return lines.join(QLatin1Char('\n'));
}

// The same version guard Application::run() carries, in one place so the two
// cannot drift: QQmlApplicationEngine::loadFromModule() arrived in Qt 6.5, and
// without this a tests build on Debian bookworm's Qt 6.4.2 fails here even
// though the app itself now builds there. The URL is the module's root
// component reached the long way round; the reasoning for the prefix and the
// "qml/" segment is written out at the call site in Application.cpp.
void loadMain(QQmlApplicationEngine &engine) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    engine.loadFromModule("TidalWave", "Main");
#else
    engine.load(QUrl(QStringLiteral("qrc:/TidalWave/qml/Main.qml")));
#endif
}

} // namespace

class TestFirstRun : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never the developer's real ~/.config/TidalWave, under any circumstance.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_firstrun"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() {
        QSettings s;
        s.clear();
        s.sync();
    }

    // A brand new install: no settings, no saved session, no cache. The window
    // has to appear and it has to be the login page.
    void freshInstallLandsOnTheLoginPage() {
        auto *prefs = new Prefs(this);
        QQmlApplicationEngine engine;
        QList<QQmlError> warnings;
        connect(&engine, &QQmlApplicationEngine::warnings, this,
                [&warnings](const QList<QQmlError> &w) { warnings += w; });

        TestStubs stubs = installTestStubs(&engine, this);
        signedOut(stubs);
        engine.rootContext()->setContextProperty(QStringLiteral("prefs"), prefs);
        // Application::run() does this before the first QML file binds Theme.*.
        ThemePalette::instance()->setPrefs(prefs);

        loadMain(engine);
        QVERIFY2(!engine.rootObjects().isEmpty(),
                 qPrintable(QStringLiteral("Main.qml produced no root object:\n%1")
                            .arg(describe(warnings))));

        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        QVERIFY2(window, "the root object of Main.qml is not a window");
        QVERIFY2(window->isVisible(),
                 "the window starts hidden, so on a desktop with no system tray "
                 "a first-time user has nothing to click");
        QVERIFY(!window->title().isEmpty());

        // Let Component.onCompleted, the stub callbacks and every binding run.
        QTest::qWait(300);

        QObject *login = loaderForPage(window, QStringLiteral("LoginPage.qml"));
        QVERIFY2(login, "no Loader in Main.qml points at pages/LoginPage.qml");
        QVERIFY2(login->property("active").toBool(),
                 "the login page is not active with no stored credentials");
        QVERIFY2(login->property("visible").toBool(),
                 "the login page is loaded but not visible");
        QVERIFY2(login->property("item").value<QObject *>() != nullptr,
                 "the login Loader is active but instantiated nothing");

        // ...and the signed-in shell is not also up behind it.
        for (const char *page : {"AlbumPage.qml", "PlaylistPage.qml", "NowPlayingPage.qml"}) {
            QObject *other = loaderForPage(window, QString::fromLatin1(page));
            if (other) QVERIFY(!other->property("active").toBool());
        }

        QVERIFY2(warnings.isEmpty(), qPrintable(describe(warnings)));
    }

    // A settings file full of junk, or one written by a build from the future,
    // must not stop the window from coming up.
    void corruptSettingsStillReachTheLoginPage() {
        {
            QSettings s;
            s.setValue(QStringLiteral("ui/theme"), QStringLiteral("chartreuse-from-2027"));
            s.setValue(QStringLiteral("ui/language"), QStringLiteral("klingon"));
            s.setValue(QStringLiteral("ui/sidebarWidth"), 999999);
            s.setValue(QStringLiteral("ui/softwareRendering"), QStringLiteral("maybe"));
            s.setValue(QStringLiteral("ui/somethingFromALaterVersion"), QVariantList{1, 2, 3});
            s.sync();
        }

        auto *prefs = new Prefs(this);
        // What tst_prefs.cpp proves about the numbers, restated here only as the
        // precondition for the QML assertions below.
        QVERIFY(prefs->sidebarWidth() >= Prefs::minSidebarWidth);
        QVERIFY(prefs->sidebarWidth() <= Prefs::maxSidebarWidth);

        QQmlApplicationEngine engine;
        QList<QQmlError> warnings;
        connect(&engine, &QQmlApplicationEngine::warnings, this,
                [&warnings](const QList<QQmlError> &w) { warnings += w; });

        TestStubs stubs = installTestStubs(&engine, this);
        signedOut(stubs);
        engine.rootContext()->setContextProperty(QStringLiteral("prefs"), prefs);
        ThemePalette::instance()->setPrefs(prefs);

        loadMain(engine);
        QVERIFY2(!engine.rootObjects().isEmpty(),
                 qPrintable(QStringLiteral("a corrupt settings file stopped Main.qml loading:\n%1")
                            .arg(describe(warnings))));

        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        QVERIFY(window);
        QTest::qWait(300);

        // An unknown theme name still has to paint something, or the window is
        // a black rectangle with black text on it.
        QVERIFY(!ThemePalette::instance()->current().isEmpty());
        QVERIFY(window->color().isValid());

        QObject *login = loaderForPage(window, QStringLiteral("LoginPage.qml"));
        QVERIFY(login);
        QVERIFY(login->property("active").toBool());

        QVERIFY2(warnings.isEmpty(), qPrintable(describe(warnings)));
    }

private:
    // No saved session, no username, no stored credentials: what the app sees
    // the very first time it is started.
    static void signedOut(const TestStubs &stubs) {
        stubs.auth->setStateForTest(StubAuth::State::LoggedOut);
        stubs.auth->setHasSavedCredentialsForTest(false);
        stubs.auth->setUsernameForTest(QString());
    }

    QTemporaryDir m_dir;
};

QTEST_MAIN(TestFirstRun)
#include "tst_firstrun.moc"
