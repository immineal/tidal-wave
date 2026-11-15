// What playback costs the account. Tidal answers a few hundred stream requests
// in a while and then refuses playback for a time, so these tests count the
// stream requests and the downloads, and assert the ones that must not happen.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QPointer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

constexpr qint64 kUser = 4242;

// The silent WAV below is 30 s long, and so is each row unless told otherwise.
QVariantMap trackOf(qlonglong id, int seconds = 30) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = seconds;
    return t;
}

QVariantList contextOf(qlonglong base, int n) {
    QVariantList out;
    for (int i = 0; i < n; ++i) out.append(trackOf(base + i));
    return out;
}

qlonglong currentId(const Player &p) {
    return p.currentTrackMap().value(QStringLiteral("id")).toLongLong();
}

QByteArray silentWav() {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * 30 * channels * bits / 8;
    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };
    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16) << quint16(1) << quint16(channels) << rate
      << quint32(rate * channels * bits / 8) << quint16(channels * bits / 8) << quint16(bits);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(bytes, '\0').constData(), int(bytes));
    return d;
}

// /track is the WAV at once, /later is the WAV once the test releases it.
// Each download is counted, so a test can say how many files were fetched.
class MediaServer : public QTcpServer {
public:
    explicit MediaServer(QObject *parent = nullptr) : QTcpServer(parent) {
        connect(this, &QTcpServer::newConnection, this, &MediaServer::accept);
    }

    QByteArray track;
    int        served = 0;
    int        waitingLater() const { return int(m_later.count()); }

    QString url(const QString &path) const {
        return QStringLiteral("http://127.0.0.1:%1%2").arg(serverPort()).arg(path);
    }
    void releaseLater() {
        const QList<QPointer<QTcpSocket>> held = std::exchange(m_later, {});
        for (const QPointer<QTcpSocket> &sock : held)
            if (sock) send(sock);
    }

private:
    void send(QTcpSocket *sock) {
        ++served;
        sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: "
                    + QByteArray::number(track.size()) + "\r\n\r\n");
        sock->write(track);
        sock->flush();
        sock->disconnectFromHost();
    }
    void accept() {
        while (QTcpSocket *sock = nextPendingConnection()) {
            auto buf = std::make_shared<QByteArray>();
            connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                buf->append(sock->readAll());
                if (buf->indexOf("\r\n\r\n") < 0) return;
                const QByteArray path = buf->mid(4, buf->indexOf(' ', 4) - 4);
                buf->clear();
                if (path == "/later") { m_later.append(sock); return; }
                send(sock);
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
    QList<QPointer<QTcpSocket>> m_later;
};

// Holds each stream request until the test answers it, and counts them.
class HeldClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    QList<qlonglong> asked;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override {
        asked.append(trackId);
        m_held.append({ trackId, std::move(cb) });
    }
    bool answer(qlonglong trackId, const StreamManifest &manifest) {
        for (int i = 0; i < m_held.count(); ++i) {
            if (m_held.at(i).first != trackId) continue;
            const StreamCb cb = m_held.takeAt(i).second;
            cb(manifest, QString());
            return true;
        }
        return false;
    }

private:
    QList<std::pair<qlonglong, StreamCb>> m_held;
};

StreamManifest oneFileAt(const QString &url) {
    StreamManifest m;
    m.type     = StreamManifest::BTS;
    m.url      = url;
    m.mimeType = QStringLiteral("audio/mp4");
    m.codec    = QStringLiteral("HIGH");
    return m;
}

struct Launch {
    TidalApi                api;
    HeldClient              client{&api};
    std::unique_ptr<Player> player;

    Launch() {
        client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
    }
    Player &p() { return *player; }
    QMediaPlayer *mp() { return player->findChild<QMediaPlayer *>(); }
    bool audioUp() { return QTest::qWaitFor([this] { return mp() != nullptr; }, 10000); }
    bool started() { return mp()->playbackState() == QMediaPlayer::PlayingState; }
    bool loaded() {
        return mp()->mediaStatus() == QMediaPlayer::LoadedMedia
            || mp()->mediaStatus() == QMediaPlayer::BufferedMedia;
    }
};

} // namespace

class TestPlayerBudget : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_player_budget"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif
        m_server.track = silentWav();
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
    }

    void init() { QSettings().clear(); }

    // ── a launch ────────────────────────────────────────────────────────────

    // The session comes back on its track and position, and nothing is asked
    // for until play: a launch that is not listened to costs nothing.
    void aRestoredSessionFetchesNothingUntilPlay() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());
        const int servedBefore = m_server.served;

        Launch b;
        QVERIFY(b.audioUp());
        QTest::qWait(500);
        QCOMPARE(b.client.asked, QList<qlonglong>());
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.p().position(), qint64(12000));
        QCOMPARE(b.p().duration(), qint64(30000));
        QVERIFY(!b.p().playing());

        b.p().playPause();
        QVERIFY(QTest::qWaitFor([&] { return b.client.answer(1002, track()); }, 5000));
        QTRY_VERIFY2_WITH_TIMEOUT(b.started(), "play did not start the restored track", 10000);
        QTRY_VERIFY_WITH_TIMEOUT(b.mp()->position() >= 11500, 5000);
        QCOMPARE(m_server.served - servedBefore, 1);
    }

    // A paused track fetches nothing ahead, even past the point where a
    // playing one would. Playing again does.
    void nothingIsFetchedAheadWhilePaused() {
        if (const char *why = obstacle()) QSKIP(why);
        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirst(a, contextOf(8000, 3)));
        a.p().playPause();
        QTRY_COMPARE_WITH_TIMEOUT(a.mp()->playbackState(), QMediaPlayer::PausedState, 5000);

        a.p().seek(8000);
        QTest::qWait(600);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000}));

        a.p().playPause();
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);
    }

    // ── repeat-one ──────────────────────────────────────────────────────────

    // Next under repeat-one goes to the next track, as it does with repeat
    // off; the press is a wish to hear something else.
    void nextUnderRepeatOneMovesOn() {
        if (const char *why = obstacle()) QSKIP(why);
        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirst(a, contextOf(2000, 3)));
        a.p().setRepeatMode(2);

        a.p().next();
        QCOMPARE(currentId(a.p()), 2001);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{2000, 2001}), 5000);
    }

    // A track that runs out under repeat-one starts over from the file it
    // has. Nothing is asked for and nothing downloaded.
    void aTrackThatRunsOutUnderRepeatOneStartsOverWithoutAFetch_data() {
        QTest::addColumn<bool>("bySeek");
        QTest::newRow("played to its end")    << false;
        QTest::newRow("a seek to its end")    << true;
    }
    void aTrackThatRunsOutUnderRepeatOneStartsOverWithoutAFetch() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(bool, bySeek);
        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirst(a, contextOf(2000, 3)));
        const int servedBefore = m_server.served;
        a.p().setRepeatMode(2);

        if (bySeek) a.p().seek(a.p().duration());
        else        a.p().seek(a.p().duration() - 400);
        QTRY_VERIFY2_WITH_TIMEOUT(a.started() && a.mp()->position() > 0 && a.mp()->position() < 3000
                                      && !a.p().loading(),
                                  "the track did not start over", 10000);
        QTest::qWait(300);
        QCOMPARE(currentId(a.p()), 2000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{2000}));
        QCOMPARE(m_server.served - servedBefore, 0);
    }

    // ── removing the row that plays ─────────────────────────────────────────

    // The last row of the queue is removed while it plays. The queue has
    // ended: nothing plays and nothing is fetched. Under repeat-all it wraps,
    // and a paused player stays paused on the row it wrapped to.
    void removingTheLastRowWhileItPlays_data() {
        QTest::addColumn<bool>("paused");
        QTest::addColumn<int>("repeat");
        QTest::addColumn<qlonglong>("landsOn");
        QTest::addColumn<bool>("fetches");
        QTest::newRow("playing")                 << false << 0 << qlonglong(3001) << false;
        QTest::newRow("paused")                  << true  << 0 << qlonglong(3001) << false;
        QTest::newRow("playing, repeat all")     << false << 1 << qlonglong(3000) << true;
        QTest::newRow("paused, repeat all")      << true  << 1 << qlonglong(3000) << false;
    }
    void removingTheLastRowWhileItPlays() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(bool, paused);
        QFETCH(int, repeat);
        QFETCH(qlonglong, landsOn);
        QFETCH(bool, fetches);
        Launch a;
        QVERIFY(a.audioUp());
        a.p().setRepeatMode(repeat);
        a.p().playTracks(contextOf(3000, 3), 2);
        QVERIFY(QTest::qWaitFor([&] { return a.client.answer(3002, track()); }, 5000));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        if (paused) {
            a.p().playPause();
            QTRY_COMPARE_WITH_TIMEOUT(a.mp()->playbackState(), QMediaPlayer::PausedState, 5000);
        }

        a.p().removeFromQueue(2);
        QCOMPARE(currentId(a.p()), landsOn);
        QTest::qWait(500);
        if (fetches) {
            QCOMPARE(a.client.asked, (QList<qlonglong>{3002, 3000}));
            QVERIFY(a.p().playing());
        } else {
            QCOMPARE(a.client.asked, (QList<qlonglong>{3002}));
            QVERIFY2(!a.p().playing(), "a removed row left something playing");
            QVERIFY(!a.started());
        }
    }

    // The playing row is removed while paused: the queue moves onto the row
    // after it and waits there, fetching nothing until play.
    void removingThePausedRowWaitsOnTheNextOne() {
        if (const char *why = obstacle()) QSKIP(why);
        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirst(a, contextOf(3000, 3)));
        a.p().playPause();
        QTRY_COMPARE_WITH_TIMEOUT(a.mp()->playbackState(), QMediaPlayer::PausedState, 5000);

        a.p().removeFromQueue(0);
        QCOMPARE(currentId(a.p()), 3001);
        QTest::qWait(500);
        QCOMPARE(a.client.asked, (QList<qlonglong>{3000}));
        QVERIFY(!a.p().playing());

        a.p().playPause();
        QVERIFY(QTest::qWaitFor([&] { return a.client.answer(3001, track()); }, 5000));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
    }

private:
    static const char *obstacle() {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to load a track";
#endif
        return nullptr;
    }

    StreamManifest track() const { return oneFileAt(m_server.url(QStringLiteral("/track"))); }

    // Plays the first row of `rows` and waits until it plays.
    bool playFirst(Launch &a, const QVariantList &rows) {
        a.p().playTracks(rows, 0);
        const qlonglong first = rows.constFirst().toMap().value(QStringLiteral("id")).toLongLong();
        if (!QTest::qWaitFor([&] { return a.client.answer(first, track()); }, 5000)) return false;
        return QTest::qWaitFor([&] { return a.started() && a.mp()->duration() > 0; }, 10000);
    }

    // Five rows left on the third, twelve seconds in.
    static bool saveFiveRowSession() {
        Launch a;
        if (!a.audioUp()) return false;
        a.p().playTracks(contextOf(1000, 5), 2);
        a.p().seek(12000);
        a.p().savePlaybackState();
        return true;
    }

    QTemporaryDir m_dir;
    MediaServer   m_server;
};

QTEST_MAIN(TestPlayerBudget)
#include "tst_player_budget.moc"
