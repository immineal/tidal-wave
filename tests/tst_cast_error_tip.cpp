// A cast that fails says why above the output button, the control the cast
// was started from. The application window runs on the stubs; StubCast
// raises the errors CastManager would.

#include <QTest>
#include <QDir>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QTemporaryDir>
#include <QVariantMap>
#include <memory>

#include "TestStubs.h"

namespace {

const QString kLost = QStringLiteral("The connection to the cast device was lost.");

QQuickItem *itemNamed(QQuickItem *from, const QString &name) {
    if (!from) return nullptr;
    if (from->objectName() == name) return from;
    const QList<QQuickItem *> kids = from->childItems();
    for (QQuickItem *kid : kids)
        if (QQuickItem *found = itemNamed(kid, name)) return found;
    return nullptr;
}

struct App {
    TestStubs                     stubs;
    QQmlEngine                    engine;
    std::unique_ptr<QQuickWindow> win;

    bool start(QObject *owner) {
        stubs = installTestStubs(&engine, owner);
        stubs.auth->setStateForTest(StubAuth::State::LoggedIn);
        stubs.app->setReducedMotionForTest(true);
        QVariantMap track;
        track[QStringLiteral("id")]         = qlonglong(501);
        track[QStringLiteral("title")]      = QStringLiteral("Winterabend");
        track[QStringLiteral("artists")]    = QStringLiteral("Erster Interpret");
        track[QStringLiteral("albumTitle")] = QStringLiteral("Ein Album");
        track[QStringLiteral("duration")]   = 247;
        stubs.player->setCurrentTrackForTest(track);

        // tipAt() hands out the window's one tool tip, which C++ cannot reach.
        QQmlComponent host(&engine);
        host.setData(QByteArrayLiteral(
            "import QtQuick\n"
            "import QtQuick.Controls\n"
            "import TidalWave\n"
            "Main {\n"
            "    function tipAt(item) { return item.ToolTip.toolTip }\n"
            "}\n"), QUrl(QStringLiteral("qrc:/tst_cast_error_tip/host.qml")));
        if (host.isError()) {
            qWarning() << host.errors();
            return false;
        }
        std::unique_ptr<QObject> root(host.create());
        if (!qobject_cast<QQuickWindow *>(root.get())) return false;
        win.reset(static_cast<QQuickWindow *>(root.release()));
        win->show();
        return QTest::qWaitForWindowExposed(win.get(), 5000);
    }

    QQuickItem *named(const char *name) {
        return itemNamed(win->contentItem(), QString::fromLatin1(name));
    }

    QObject *tip() {
        QVariant out;
        QMetaObject::invokeMethod(win.get(), "tipAt", Q_RETURN_ARG(QVariant, out),
                                  Q_ARG(QVariant, QVariant::fromValue(win->contentItem())));
        return out.value<QObject *>();
    }
    bool    tipUp()   { return tip() && tip()->property("visible").toBool(); }
    QString tipText() { return tip() ? tip()->property("text").toString() : QString(); }
    // The control the tip stands over: the item it is attached to, or the
    // button that item sits in.
    QString tipButton() {
        auto *at = tip() ? tip()->property("parent").value<QQuickItem *>() : nullptr;
        while (at && !at->objectName().endsWith(QLatin1String("OutputButton")))
            at = at->parentItem();
        return at ? at->objectName() : QString();
    }

    void fail(const QString &message) { stubs.cast->emitErrorForTest(message); }

    bool saveShot(const QString &name) {
        const QString dir = qEnvironmentVariable("TIDALWAVE_SHOT_DIR");
        if (dir.isEmpty()) return true;
        QTest::qWait(400);
        return win->grabWindow().save(QDir(dir).filePath(name + QStringLiteral(".png")));
    }

    bool openNowPlaying() {
        if (!QMetaObject::invokeMethod(win.get(), "navigate",
                                       Q_ARG(QVariant, QStringLiteral("nowplaying")),
                                       Q_ARG(QVariant, QVariant()), Q_ARG(QVariant, QVariant())))
            return false;
        return QTest::qWaitFor([this] {
            QQuickItem *out = named("nowPlayingOutputButton");
            return out && out->isVisible()
                && qFuzzyCompare(win->property("nowPlayingness").toReal(), 1.0);
        }, 5000);
    }
};

} // namespace

class TestCastErrorTip : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_cast_error_tip"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void aCastErrorIsSaidAboveTheOutputButton_data() {
        QTest::addColumn<QString>("theme");
        QTest::newRow("dark")  << QStringLiteral("sea");
        QTest::newRow("light") << QStringLiteral("sky");
    }

    void aCastErrorIsSaidAboveTheOutputButton() {
        QFETCH(QString, theme);
        App a;
        QVERIFY(a.start(this));
        a.stubs.prefs->setTheme(theme);
        QVERIFY2(!a.tipUp(), "a tool tip was up before anything failed");

        a.fail(kLost);

        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the cast error put nothing on the screen", 3000);
        QCOMPARE(a.tipText(), kLost);
        QCOMPARE(a.tipButton(), QStringLiteral("playerBarOutputButton"));
        QVERIFY2(a.tip()->property("timeout").toInt() >= 5000,
                 "the sentence is given no longer than a confirmation");
        QVERIFY(a.saveShot(QStringLiteral("cast-error-%1")
                               .arg(QString::fromLatin1(QTest::currentDataTag()))));
    }

    void onNowPlayingTheMessageIsAtThatPagesOutputButton() {
        App a;
        QVERIFY(a.start(this));
        QVERIFY(a.openNowPlaying());

        a.fail(kLost);

        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the cast error put nothing on the screen", 3000);
        QCOMPARE(a.tipText(), kLost);
        QCOMPARE(a.tipButton(), QStringLiteral("nowPlayingOutputButton"));
        QVERIFY(a.saveShot(QStringLiteral("cast-error-now-playing")));
    }

    // Closed to the tray when the cast fails. The message waits for the
    // window, is shown once, and not again the next time it opens.
    void aFailureBehindAHiddenWindowIsShownWhenTheWindowComesBack() {
        App a;
        QVERIFY(a.start(this));
        a.win->hide();
        a.fail(kLost);
        QTest::qWait(300);
        QVERIFY2(!a.tipUp(), "the message was spent on a window nobody could see");

        a.win->show();
        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the window came back without the message", 3000);
        QCOMPARE(a.tipText(), kLost);
        QCOMPARE(a.tipButton(), QStringLiteral("playerBarOutputButton"));

        QVERIFY(QMetaObject::invokeMethod(a.tip(), "close"));
        QTRY_VERIFY_WITH_TIMEOUT(!a.tipUp(), 2000);
        a.win->hide();
        a.win->show();
        QVERIFY(QTest::qWaitForWindowExposed(a.win.get(), 5000));
        QTest::qWait(300);
        QVERIFY2(!a.tipUp(), "one failure was reported twice");
    }

    // The tip is drawn over the window, so it would stay behind over the page
    // once the bar it points at has gone.
    void theMessageLeavesWithTheBarItIsShownAt() {
        App a;
        QVERIFY(a.start(this));
        a.fail(kLost);
        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the cast error put nothing on the screen", 3000);

        QVERIFY(a.openNowPlaying());

        QTRY_VERIFY2_WITH_TIMEOUT(!a.tipUp(), "the message stayed where the bar had been", 2000);
    }

    // A second failure while the first is up says the newer one.
    void aLaterErrorReplacesTheFirst() {
        App a;
        QVERIFY(a.start(this));
        a.fail(QStringLiteral("The cast device did not answer."));
        QTRY_VERIFY_WITH_TIMEOUT(a.tipUp(), 3000);
        a.fail(kLost);
        QTRY_COMPARE_WITH_TIMEOUT(a.tipText(), kLost, 2000);
        QVERIFY(a.tipUp());
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestCastErrorTip)
#include "tst_cast_error_tip.moc"
