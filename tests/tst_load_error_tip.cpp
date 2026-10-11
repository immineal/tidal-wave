// A load that fails says why above the play button. The application window
// runs on the stubs with the real Player in place of the stub one, and the
// test answers each stream request itself, so nothing is fetched or played.

#include <QTest>
#include <QDir>
#include <QImage>
#include <QMediaPlayer>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

#include "TestStubs.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

QVariantMap trackOf(qlonglong id, const QString &title) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = title;
    t[QStringLiteral("artists")]    = QStringLiteral("Erster Interpret");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Ein Album");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 247;
    return t;
}

QVariantList threeTracks() {
    return { trackOf(501, QStringLiteral("Winterabend")),
             trackOf(502, QStringLiteral("Nebelmeer")),
             trackOf(503, QStringLiteral("Morgenrot")) };
}

// Holds each stream request until the test answers it.
class HeldClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override
    {
        m_held.append({ trackId, std::move(cb) });
    }

    bool answer(qlonglong trackId, const StreamManifest &manifest, const QString &err)
    {
        for (int i = 0; i < m_held.count(); ++i) {
            if (m_held.at(i).first != trackId) continue;
            const StreamCb cb = m_held.takeAt(i).second;
            cb(manifest, err);
            return true;
        }
        return false;
    }

private:
    QList<std::pair<qlonglong, StreamCb>> m_held;
};

// What Qt reports for a request the server turned down.
const QString kTransferText = QStringLiteral(
    "Error transferring https://api.example.invalid/v1/tracks/501 - server replied: Bad Gateway");

QQuickItem *itemNamed(QQuickItem *from, const QString &name) {
    if (!from) return nullptr;
    if (from->objectName() == name) return from;
    const QList<QQuickItem *> kids = from->childItems();
    for (QQuickItem *kid : kids)
        if (QQuickItem *found = itemNamed(kid, name)) return found;
    return nullptr;
}

// The application window over the real Player. Declared in this order, the
// window goes first, then the engine, then the player their bindings read.
struct App {
    TidalApi                      api;
    HeldClient                    client{&api};
    Player                        player{&client};
    TestStubs                     stubs;
    QQmlEngine                    engine;
    std::unique_ptr<QQuickWindow> win;

    bool start(QObject *owner) {
        player.setMuted(true);
        player.setVolume(0.0);
        stubs = installTestStubs(&engine, owner);
        stubs.auth->setStateForTest(StubAuth::State::LoggedIn);
        stubs.app->setReducedMotionForTest(true);
        engine.rootContext()->setContextProperty(QStringLiteral("player"), &player);

        // tipAt() hands out the window's one tool tip, which C++ cannot reach.
        QQmlComponent host(&engine);
        host.setData(QByteArrayLiteral(
            "import QtQuick\n"
            "import QtQuick.Controls\n"
            "import TidalWave\n"
            "Main {\n"
            "    function tipAt(item) { return item.ToolTip.toolTip }\n"
            "}\n"), QUrl(QStringLiteral("qrc:/tst_load_error_tip/host.qml")));
        if (host.isError()) {
            qWarning() << host.errors();
            return false;
        }
        std::unique_ptr<QObject> root(host.create());
        if (!qobject_cast<QQuickWindow *>(root.get())) return false;
        win.reset(static_cast<QQuickWindow *>(root.release()));
        win->show();
        if (!QTest::qWaitForWindowExposed(win.get(), 5000)) return false;
        // The Player builds its audio objects on the first turn of the loop.
        return QTest::qWaitFor([this] { return player.findChild<QMediaPlayer *>() != nullptr; },
                               10000);
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
    bool    tipUp()     { return tip() && tip()->property("visible").toBool(); }
    QString tipText()   { return tip() ? tip()->property("text").toString() : QString(); }
    QString tipAnchor() {
        auto *at = tip() ? tip()->property("parent").value<QQuickItem *>() : nullptr;
        return at ? at->objectName() : QString();
    }

    QString loadError() { return player.property("loadError").toString(); }

    // Saves the window under TIDALWAVE_SHOT_DIR. True where that is not set.
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
            QQuickItem *play = named("nowPlayingPlayButton");
            return play && play->isVisible()
                && qFuzzyCompare(win->property("nowPlayingness").toReal(), 1.0);
        }, 5000);
    }

    // Plays the queue from its first row and has Tidal turn the request down.
    bool failTheFirstLoad() {
        player.playTracks(threeTracks(), 0);
        return client.answer(501, {}, kTransferText);
    }
};

} // namespace

class TestLoadErrorTip : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_load_error_tip"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // The sentence is the player's own, with none of the transfer text, and it
    // stays up for longer than a confirmation does.
    void aFailedLoadSaysWhyAboveThePlayButton_data() {
        QTest::addColumn<QString>("theme");
        QTest::newRow("dark")  << QStringLiteral("sea");
        QTest::newRow("light") << QStringLiteral("sky");
    }

    void aFailedLoadSaysWhyAboveThePlayButton() {
        QFETCH(QString, theme);
        App a;
        QVERIFY(a.start(this));
        a.stubs.prefs->setTheme(theme);
        QVERIFY2(!a.tipUp(), "a tool tip was up before anything failed");

        QVERIFY(a.failTheFirstLoad());

        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the failed load put nothing on the screen", 3000);
        QCOMPARE(a.tipText(), QStringLiteral("Could not load this track for playback."));
        QCOMPARE(a.tipText(), a.loadError());
        QCOMPARE(a.tipAnchor(), QStringLiteral("playerBarPlayButton"));
        QVERIFY2(a.tip()->property("timeout").toInt() >= 5000,
                 "the sentence is given no longer than a confirmation");

        QVERIFY(a.saveShot(QStringLiteral("load-error-%1")
                               .arg(QString::fromLatin1(QTest::currentDataTag()))));
    }

    void theMessageIsGoneOnceALoadStarts() {
        App a;
        QVERIFY(a.start(this));
        QVERIFY(a.failTheFirstLoad());
        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the failed load put nothing on the screen", 3000);

        a.player.playPause();

        QVERIFY(a.player.loading());
        QTRY_VERIFY2_WITH_TIMEOUT(!a.tipUp(), "the message stayed over a load that had started", 2000);
        QCOMPARE(a.loadError(), QString());
    }

    // Closed to the tray when the load fails. The message waits for the
    // window, is shown once, and is not shown again the next time it opens.
    void aFailureBehindAHiddenWindowIsShownWhenTheWindowComesBack() {
        App a;
        QVERIFY(a.start(this));
        a.win->hide();
        QVERIFY(!a.win->isVisible());

        QVERIFY(a.failTheFirstLoad());
        QTest::qWait(300);
        QVERIFY2(!a.tipUp(), "the message was spent on a window nobody could see");

        a.win->show();
        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the window came back without the message", 3000);
        QCOMPARE(a.tipText(), QStringLiteral("Could not load this track for playback."));
        QCOMPARE(a.tipAnchor(), QStringLiteral("playerBarPlayButton"));

        QVERIFY(QMetaObject::invokeMethod(a.tip(), "close"));
        QTRY_VERIFY_WITH_TIMEOUT(!a.tipUp(), 2000);
        a.win->hide();
        a.win->show();
        QVERIFY(QTest::qWaitForWindowExposed(a.win.get(), 5000));
        QTest::qWait(300);
        QVERIFY2(!a.tipUp(), "one failure was reported twice");
    }

    void onNowPlayingTheMessageIsAtThatPagesPlayButton() {
        App a;
        QVERIFY(a.start(this));
        QVERIFY(a.openNowPlaying());

        QVERIFY(a.failTheFirstLoad());

        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the failed load put nothing on the screen", 3000);
        QCOMPARE(a.tipText(), QStringLiteral("Could not load this track for playback."));
        QCOMPARE(a.tipAnchor(), QStringLiteral("nowPlayingPlayButton"));
        QVERIFY(a.saveShot(QStringLiteral("load-error-now-playing")));
    }

    // The bar leaves the screen when Now Playing opens, and the tool tip is
    // drawn over the window, so it would stay behind over the page.
    void theMessageLeavesWithTheBarItIsShownAt() {
        App a;
        QVERIFY(a.start(this));
        QVERIFY(a.failTheFirstLoad());
        QTRY_VERIFY2_WITH_TIMEOUT(a.tipUp(), "the failed load put nothing on the screen", 3000);

        QVERIFY(a.openNowPlaying());

        QTRY_VERIFY2_WITH_TIMEOUT(!a.tipUp(), "the message stayed where the bar had been", 2000);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestLoadErrorTip)
#include "tst_load_error_tip.moc"
