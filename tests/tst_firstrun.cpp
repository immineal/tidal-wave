// First run, at the QML layer: Main.qml loads against an empty or corrupt
// settings file, lands on the login page and logs no QML warnings.
// Prefs, ThemePalette and the QSettings scope are the real ones. Everything
// that needs a network, a Tidal session, an audio device or D-Bus comes from
// TestStubs.h. StubAuth defaults to signed in, so every test signs it out, and
// Prefs is parented to the test object so it outlives ThemePalette's pointer.

#include <QTest>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>
#include <QFontDatabase>

#include "TestStubs.h"
#include "ui/Prefs.h"
#include "ui/ThemePalette.h"
#include "ui/Application.h"
#include "ui/Shortcuts.h"

namespace {

// Depth-first search for the Loader that pulls in a given page, matched on the
// source url.
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

// The version guard Application::run() carries:
// QQmlApplicationEngine::loadFromModule() arrived in Qt 6.5, so Qt 6.4 loads
// the module's root component by URL.
void loadMain(QQmlApplicationEngine &engine) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    engine.loadFromModule("TidalWave", "Main");
#else
    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/TidalWave/qml/Main.qml")));
#endif
}

} // namespace

class TestFirstRun : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never the real ~/.config/TidalWave.
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
        // The precondition for the QML assertions below. tst_prefs.cpp covers
        // the clamping itself.
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

    // Every family the UI font stack names is installed on this machine. Qt
    // answers the first missing family by populating its font-family alias
    // table on every launch. Needs a real font database, hence a GUI test.
    void uiFontFamiliesAreAllInstalled() {
        const QStringList families = Application::uiFontFamilies();
        QVERIFY2(!families.isEmpty(),
                 "the UI font stack came back empty, so QFont would fall back to "
                 "a default chosen by nobody");
        for (const QString &f : families) {
            QVERIFY2(QFontDatabase::hasFamily(f),
                     qPrintable(QStringLiteral(
                         "the UI font stack names \"%1\", which this machine does not "
                         "have; that costs ~37 ms of alias population on every launch")
                                    .arg(f)));
        }
    }

    // The key badges ask for a fixed-pitch family by name, and the name has to
    // be real. Empty is allowed and means the default font.
    void monospaceFamilyIsRealOrDeliberatelyEmpty() {
        const QString fixed = Shortcuts().monospaceFamily();
        if (fixed.isEmpty())
            return;
        QVERIFY2(QFontDatabase::hasFamily(fixed),
                 qPrintable(QStringLiteral(
                     "Shortcuts::monospaceFamily() returned \"%1\", which the font "
                     "database does not have").arg(fixed)));
    }
};

QTEST_MAIN(TestFirstRun)
#include "tst_firstrun.moc"
