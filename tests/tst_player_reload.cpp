// A restore the user overtakes. Stream requests are held until the test
// answers them, and the audio is a silent WAV from a localhost server. Every
// Player here is muted before its output opens.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

constexpr qint64 kUser = 4242;

QVariantMap trackOf(qlonglong id) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 30;
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

// Half a minute of silence, long enough that no test reaches its end.
QByteArray silentWav() {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * 30 * channels * bits / 8;

    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };

    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16)
      << quint16(1) << quint16(channels)
      << rate << quint32(rate * channels * bits / 8)
      << quint16(channels * bits / 8) << quint16(bits);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(bytes, '\0').constData(), int(bytes));
    return d;
}

// A localhost origin for the audio. /track is the WAV and every other path
// is not there.
class MediaServer : public QTcpServer {
public:
    explicit MediaServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &MediaServer::accept);
    }

    QByteArray track;

    QString url(const QString &path) const
    {
        return QStringLiteral("http://127.0.0.1:%1%2").arg(serverPort()).arg(path);
    }

private:
    void accept()
    {
        while (QTcpSocket *sock = nextPendingConnection()) {
            auto buf = std::make_shared<QByteArray>();
            connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                buf->append(sock->readAll());
                if (buf->indexOf("\r\n\r\n") < 0) return;
                const bool found = buf->startsWith("GET /track ");
                buf->clear();
                const QByteArray body = found ? track : QByteArray();
                sock->write(found ? "HTTP/1.0 200 OK\r\n" : "HTTP/1.0 404 Not Found\r\n");
                sock->write("Content-Type: audio/wav\r\nContent-Length: "
                            + QByteArray::number(body.size()) + "\r\n\r\n");
                sock->write(body);
                sock->flush();
                sock->disconnectFromHost();
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
};

// Holds each stream request until the test answers it, as a slow Tidal does.
class HeldClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    QList<qlonglong> asked;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override
    {
        asked.append(trackId);
        m_held.append({ trackId, std::move(cb) });
    }

    // Answers the oldest request still out for this track.
    bool answer(qlonglong trackId, const StreamManifest &manifest,
                const QString &err = QString())
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

StreamManifest oneFileAt(const QString &url) {
    StreamManifest m;
    m.type     = StreamManifest::BTS;
    m.url      = url;
    m.mimeType = QStringLiteral("audio/mp4");
    m.codec    = QStringLiteral("HIGH");
    return m;
}

StreamManifest ruledOut() {
    StreamManifest m;
    m.unavailable = true;
    return m;
}

// One launch of the app. With the account set first, the Player restores
// from its constructor as it does at startup.
struct Launch {
    TidalApi                api;
    HeldClient              client{&api};
    std::unique_ptr<Player> player;

    explicit Launch(bool signedIn = true) {
        if (signedIn) client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
    }
    Player &p() { return *player; }
    QMediaPlayer *mp() { return player->findChild<QMediaPlayer *>(); }
    // The Player builds its audio objects on the first turn of the loop.
    bool audioUp() {
        return QTest::qWaitFor([this] { return mp() != nullptr; }, 10000);
    }
    bool loaded() {
        return mp()->mediaStatus() == QMediaPlayer::LoadedMedia
            || mp()->mediaStatus() == QMediaPlayer::BufferedMedia;
    }
};

} // namespace

class TestPlayerReload : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_player_reload"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        m_server.track = silentWav();
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
    }

    void init() {
        QSettings().clear();
    }

    // ── a restore the user overtakes ────────────────────────────────────────

    // The restored track's request is still out when the user presses Next.
    // The track that loads is one the user asked for, so it plays.
    void aTrackPickedWhileTheRestoreIsStillLoadingPlays() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));

        b.p().next();
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003}));
        QVERIFY(b.client.answer(1003, oneFileAt(m_server.url(QStringLiteral("/track")))));

        QTRY_VERIFY_WITH_TIMEOUT(b.loaded(), 10000);
        QTRY_VERIFY2_WITH_TIMEOUT(b.p().playing(),
                                  "the track the user picked came up paused", 5000);
        QCOMPARE(currentId(b.p()), 1003);
    }

    // Left alone, the restored track comes back paused where it was left.
    // Signing in later restores through a player that already exists.
    void theRestoredTrackComesBackPausedWhereItWasLeft_data() {
        QTest::addColumn<bool>("signedInAtStartup");
        QTest::newRow("at startup")    << true;
        QTest::newRow("on signing in") << false;
    }

    void theRestoredTrackComesBackPausedWhereItWasLeft() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(bool, signedInAtStartup);
        QVERIFY(saveFiveRowSession());

        Launch b(signedInAtStartup);
        QVERIFY(b.audioUp());
        if (!signedInAtStartup) b.client.setUserId(kUser);
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));
        QSignalSpy playingSpy(&b.p(), &Player::playingChanged);
        QVERIFY(b.client.answer(1002, oneFileAt(m_server.url(QStringLiteral("/track")))));

        QTRY_VERIFY_WITH_TIMEOUT(b.loaded(), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(b.mp()->position() - 12000) < 250, 5000);
        QTest::qWait(300);
        QCOMPARE(b.mp()->playbackState(), QMediaPlayer::PausedState);
        for (const QList<QVariant> &args : playingSpy)
            QVERIFY2(!args.at(0).toBool(), "the restored track announced that it was playing");
    }

    // A restored track Tidal has ruled out is dropped without a word, and the
    // row that takes its place is still the restore's: it comes back paused.
    void theRowAfterARuledOutRestoredTrackComesBackPaused() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QSignalSpy errorSpy(&b.p(), &Player::error);
        QSignalSpy playingSpy(&b.p(), &Player::playingChanged);

        QVERIFY(b.client.answer(1002, ruledOut(), QStringLiteral("only a preview")));
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003}));
        QCOMPARE(currentId(b.p()), 1003);
        QVERIFY(b.client.answer(1003, oneFileAt(m_server.url(QStringLiteral("/track")))));

        QTRY_VERIFY_WITH_TIMEOUT(b.loaded(), 10000);
        QTest::qWait(300);
        QCOMPARE(b.mp()->playbackState(), QMediaPlayer::PausedState);
        for (const QList<QVariant> &args : playingSpy)
            QVERIFY2(!args.at(0).toBool(), "the row after a dropped one started playing");
        QCOMPARE(errorSpy.count(), 0);
        QCOMPARE(b.p().queueCount(), 4);
    }

private:
    // Why this Qt on this machine cannot run the cases that load audio, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to load a track";
#endif
        return nullptr;
    }

    // Five rows left on the third, twelve seconds in. Nothing is answered, so
    // nothing loads.
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

QTEST_MAIN(TestPlayerReload)
#include "tst_player_reload.moc"
