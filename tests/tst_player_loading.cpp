// The busy flag around a track change.
//
// `loading` is what the now-playing spinner and the player bar read, and it is
// the one piece of player state that is set and cleared from two directions at
// once: loadAndPlay() raises it, and QMediaPlayer's own media-status changes
// lower it. The order of those two is the whole of this file - raising it
// before stop() means stop() reports LoadedMedia and lowers it again, leaving
// the app "not loading" for the entire fetch of the next track.
//
// The QMediaPlayer under test is the real one the Player owns, reached as its
// child, and it is fed a locally generated silent WAV. No network and no
// fixture out of the user's library.
//
// The three tests after the first one need a Tidal that has stopped answering,
// which is reached by pointing the *application* HTTP proxy at a localhost
// server of the test's own. Every QNetworkAccessManager in the process then
// opens its connections there and sends CONNECT api.tidal.com:443, and the
// server either says nothing at all or closes at once. That needs no TLS, no
// DNS, no internet and no seam in the app: the request path under test is
// exactly the one the app uses, and what it talks to is the only thing that
// changed. Counting connections at that server is also how the trigger for the
// next track's preload is observed, since the Player exposes nothing about it.
//
// Only the first test ever calls play(). The rest load media but never start it,
// so no audio device is opened.

#include <QTest>
#include <QDataStream>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QMediaPlayer>
#include <QNetworkProxy>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QPointer>
#include <QTemporaryDir>
#include <QSettings>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

QVariantMap trackOf(qlonglong id) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("A Title");
    t[QStringLiteral("artists")]    = QStringLiteral("An Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("A Record");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 200;
    return t;
}

// Half a minute of silence: valid and decodable by any backend, and long
// enough that nothing here races its end of media (which would advance the
// queue underneath the measurement).
bool writeSilentWav(const QString &path) {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * 30 * channels * bits / 8;

    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };

    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16)                            // chunk size
      << quint16(1) << quint16(channels)        // PCM, mono
      << rate << quint32(rate * channels * bits / 8)
      << quint16(channels * bits / 8) << quint16(bits);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(bytes, '\0').constData(), int(bytes));

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    return f.write(d) == d.size();
}

// A stand-in for a Tidal that has stopped answering, or for one that refuses
// every connection. As the application HTTP proxy it sees one connection per
// request the app makes, which is both the hang and the counter.
//
// Silent is the case this file exists for and the one a fixture usually cannot
// express: a 404, a refused connection and a closed socket all *answer*, and
// every one of them already worked. What never worked was a request that
// connects and then goes quiet, so the socket is accepted, read, and held.
class DeadProxy : public QTcpServer {
public:
    enum Behaviour { Silent, CloseAtOnce };

    explicit DeadProxy(Behaviour behaviour, QObject *parent = nullptr)
        : QTcpServer(parent), m_behaviour(behaviour)
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                ++m_connections;
                if (m_behaviour == CloseAtOnce) {
                    sock->close();
                    sock->deleteLater();
                } else {
                    m_held.append(sock);
                    connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                }
            }
        });
    }

    ~DeadProxy() override
    {
        for (QTcpSocket *sock : std::as_const(m_held))
            if (sock) sock->abort();
    }

    // One per request the app sent, because a proxy connection that never
    // completes its CONNECT is never reused for a second request.
    int connections() const { return m_connections; }

    void becomeTheApplicationProxy()
    {
        QNetworkProxy::setApplicationProxy(
            QNetworkProxy(QNetworkProxy::HttpProxy, QStringLiteral("127.0.0.1"),
                          quint16(serverPort())));
    }

private:
    Behaviour             m_behaviour;
    int                   m_connections = 0;
    QList<QPointer<QTcpSocket>> m_held;
};

} // namespace

class TestPlayerLoading : public QObject {
    Q_OBJECT

private slots:
    void cleanup() {
        QNetworkProxy::setApplicationProxy(QNetworkProxy(QNetworkProxy::NoProxy));
    }

    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_player_loading"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        m_wav = m_dir.filePath(QStringLiteral("silence.wav"));
        QVERIFY2(writeSilentWav(m_wav), "the test could not write its own audio file");
    }

    void startingATrackStaysLoadingUntilSomethingSaysOtherwise() {
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        // Player defers its audio init to the event loop (a PipeWire deadlock
        // guard), so the QMediaPlayer does not exist until that has run.
        QTest::qWait(30);

        auto *mp = player.findChild<QMediaPlayer *>();
        QVERIFY2(mp, "the Player has no QMediaPlayer");

        // Get the player into the state a user is actually in when they pick
        // the next track: something is loaded and playing.
        mp->setSource(QUrl::fromLocalFile(m_wav));
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::LoadedMedia
                                 || mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);
        mp->play();
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);
        QVERIFY2(!player.loading(), "the player is still busy with the file it has loaded");

        // Picking a track. The manifest fetch behind it is a network call that
        // cannot complete here, which is exactly the window being measured:
        // for as long as it is out, the app has to say it is loading.
        player.playTracks(QVariantList{ trackOf(4242) }, 0);

        QVERIFY2(player.loading(),
                 "the player stopped reporting a load the instant it started one: "
                 "stop()/setSource() reported LoadedMedia and cleared the flag");
    }

    // The regression. Before TidalApi set a transfer timeout, this flag stayed
    // true for the life of the process, and TrackRow's spinner is an indefinite
    // animation, so one stuck row held the render loop at 60 fps for as long as
    // the window was up.
    void aStreamRequestThatNeverAnswersGivesUpAndSaysSo()
    {
        DeadProxy proxy{DeadProxy::Silent};
        QVERIFY(proxy.listen(QHostAddress::LocalHost));
        proxy.becomeTheApplicationProxy();

        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QTest::qWait(30);                 // the deferred audio init
        QVERIFY(player.findChild<QMediaPlayer *>());

        QSignalSpy errors(&player, &Player::error);
        QElapsedTimer clock;
        clock.start();
        player.playTracks(QVariantList{ trackOf(4242) }, 0);
        QVERIFY2(player.loading(), "the load was never reported as started");

        // Three seconds in, a request that has not answered yet is a request
        // that is merely slow. Giving up here would be the wrong fix passing.
        QTest::qWait(3000);
        QCOMPARE(proxy.connections(), 1);    // out, and sitting at the proxy
        QVERIFY2(player.loading(),
                 "the load was abandoned within three seconds, which would kill a "
                 "slow but working one");
        QCOMPARE(errors.count(), 0);

        QTRY_VERIFY_WITH_TIMEOUT(!player.loading(),
                                 TidalApi::kTransferTimeoutMs + 10000);
        const qint64 gaveUpAfter = clock.elapsed();

        QVERIFY2(gaveUpAfter >= TidalApi::kTransferTimeoutMs - 1000,
                 qPrintable(QStringLiteral("gave up after %1 ms, sooner than the "
                                           "%2 ms timeout")
                            .arg(gaveUpAfter).arg(TidalApi::kTransferTimeoutMs)));
        // Clearing the flag is not enough on its own: a spinner that stops with
        // nothing playing and nothing said is the same dead end, quieter.
        QCOMPARE(errors.count(), 1);
        const QString msg = errors.takeFirst().at(0).toString();
        QVERIFY2(msg.startsWith(QStringLiteral("Could not load this track for playback.")),
                 qPrintable(QStringLiteral("the user was told: %1").arg(msg)));
    }

    // The preload used to start ten seconds before the end of the track. A DASH
    // join of a hi-res track was measured at a median 15.2 s (24/96) and 30.4 s
    // (24/192) on this link, worst case 69.7 s, so it could not finish; the
    // segments were thrown away and the gap between tracks was the whole join.
    //
    // There is nothing public to watch, so the proxy counts the preload's
    // manifest request. The player is positioned six seconds into a thirty
    // second track: far too early for the old trigger, which wanted
    // (duration - position) <= 10000.
    void theNextTrackIsPreloadedEarlyInThisTrackAndNotAtItsEnd()
    {
        DeadProxy proxy{DeadProxy::CloseAtOnce};
        QVERIFY(proxy.listen(QHostAddress::LocalHost));
        proxy.becomeTheApplicationProxy();

        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QTest::qWait(30);
        auto *mp = player.findChild<QMediaPlayer *>();
        QVERIFY(mp);

        player.playTracks(QVariantList{ trackOf(4242), trackOf(4243) }, 0);
        QTRY_VERIFY_WITH_TIMEOUT(!player.loading(), 5000);   // the manifest refused

        // Stand in for the current track's bytes having arrived: the local file
        // is what the player would be holding by now. It is never played.
        mp->setSource(QUrl::fromLocalFile(m_wav));
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::LoadedMedia
                                 || mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);
        QCOMPARE(mp->duration(), 30000);

        const int before = proxy.connections();
        mp->setPosition(6000);

        QTRY_VERIFY_WITH_TIMEOUT(proxy.connections() > before, 5000);
    }

    // Repeat-one's "next track" is the row already playing, whose bytes are
    // already on disk. With the trigger early in the track the preload would now
    // *succeed* at fetching a second copy of the track being listened to - the
    // whole of it, every loop, up to a few hundred megabytes on hi-res. The gap
    // that leaves on a repeat-one loop is what was already there; paying for the
    // track twice to close it would be new.
    void repeatOneDoesNotFetchASecondCopyOfTheTrackItIsAlreadyPlaying()
    {
        DeadProxy proxy{DeadProxy::CloseAtOnce};
        QVERIFY(proxy.listen(QHostAddress::LocalHost));
        proxy.becomeTheApplicationProxy();

        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QTest::qWait(30);
        auto *mp = player.findChild<QMediaPlayer *>();
        QVERIFY(mp);

        player.setRepeatMode(2);                 // repeat one
        player.playTracks(QVariantList{ trackOf(4242), trackOf(4243) }, 0);
        QTRY_VERIFY_WITH_TIMEOUT(!player.loading(), 5000);

        mp->setSource(QUrl::fromLocalFile(m_wav));
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::LoadedMedia
                                 || mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);

        const int before = proxy.connections();
        for (int i = 0; i < 8; ++i) {
            mp->setPosition(6000 + i * 200);
            QTest::qWait(60);
        }
        QCOMPARE(proxy.connections(), before);
    }

    // With the trigger six seconds in rather than ten seconds from the end, a
    // preload that cannot succeed would otherwise be started again on every
    // position update for the rest of the track - one manifest request and one
    // abandoned join per tick, for minutes.
    void aPreloadThatHasGivenUpIsNotStartedAgainOnEveryTick()
    {
        DeadProxy proxy{DeadProxy::CloseAtOnce};
        QVERIFY(proxy.listen(QHostAddress::LocalHost));
        proxy.becomeTheApplicationProxy();

        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QTest::qWait(30);
        auto *mp = player.findChild<QMediaPlayer *>();
        QVERIFY(mp);

        player.playTracks(QVariantList{ trackOf(4242), trackOf(4243) }, 0);
        QTRY_VERIFY_WITH_TIMEOUT(!player.loading(), 5000);

        mp->setSource(QUrl::fromLocalFile(m_wav));
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::LoadedMedia
                                 || mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);

        const int before = proxy.connections();
        mp->setPosition(6000);
        QTRY_VERIFY_WITH_TIMEOUT(proxy.connections() > before, 5000);
        // Let that attempt fail, so what stops the next tick is the memory of
        // the failure and not the in-progress guard.
        QTest::qWait(600);
        const int afterOneAttempt = proxy.connections();

        for (int i = 1; i <= 12; ++i) {
            mp->setPosition(6000 + i * 100);
            QTest::qWait(60);
        }

        QCOMPARE(proxy.connections(), afterOneAttempt);
    }

private:
    QTemporaryDir m_dir;
    QString       m_wav;
};

QTEST_MAIN(TestPlayerLoading)
#include "tst_player_loading.moc"
