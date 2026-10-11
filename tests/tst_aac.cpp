// Tidal's two lossy formats, AAC LC and HE-AAC. Each comes from a localhost
// server as one MP4 file, goes through the Player's own load path, is sought
// in once and plays to its end. Every Player is muted before its output opens.

#include <QTest>
#include <QByteArray>
#include <QHash>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

#include "aac_fixture.inc"

namespace {

// How far a backend's duration and last position may be from the file's own.
constexpr int kSlackMs = 300;

QVariantMap oneTrack() {
    QVariantMap t;
    t[QStringLiteral("id")]       = qlonglong(1);
    t[QStringLiteral("title")]    = QStringLiteral("Tone");
    t[QStringLiteral("artists")]  = QStringLiteral("Artist");
    t[QStringLiteral("duration")] = kAacDurationMs / 1000;
    return t;
}

// A localhost origin for the audio: GET <path> answers with that file.
class FileServer : public QTcpServer {
public:
    FileServer()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock] { answer(sock); });
            }
        });
    }

    QHash<QByteArray, QByteArray> files;
    int                           served = 0;

    QString url(const QString &path) const
    {
        return QStringLiteral("http://127.0.0.1:%1%2").arg(serverPort()).arg(path);
    }

private:
    void answer(QTcpSocket *sock)
    {
        if (!sock->canReadLine()) return;
        // The request line is all that is read; one answer per connection.
        QObject::disconnect(sock, &QTcpSocket::readyRead, nullptr, nullptr);
        const QByteArray path = sock->readLine().split(' ').value(1);
        const auto file = files.constFind(path);
        if (file == files.constEnd()) {
            sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        } else {
            ++served;
            sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                        + QByteArray::number(file->size()) + "\r\n\r\n" + *file);
        }
        sock->disconnectFromHost();
    }
};

// Answers every stream request with one file, as Tidal does for a lossy tier.
class OneFileClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    StreamManifest manifest;

    void fetchStreamManifest(qint64, StreamCb cb) override
    {
        QTimer::singleShot(0, this, [this, cb = std::move(cb)] { cb(manifest, QString()); });
    }
};

// What the Player's QMediaPlayer did, as the test needs to ask about it.
struct Watch {
    explicit Watch(QMediaPlayer *mp)
    {
        QObject::connect(mp, &QMediaPlayer::positionChanged, mp, [this](qint64 pos) {
            if (pos > furthest) furthest = pos;
        });
        QObject::connect(mp, &QMediaPlayer::mediaStatusChanged, mp,
                         [this](QMediaPlayer::MediaStatus s) {
            if (s == QMediaPlayer::EndOfMedia) ended = true;
        });
    }
    // The Player stops at the end of its queue, which resets the position.
    qint64 furthest = 0;
    bool   ended    = false;
};

} // namespace

class TestAac : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_aac"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        m_server.files.insert("/lc.mp4", QByteArray::fromBase64(QByteArray(kAacLcB64)));
        m_server.files.insert("/he.mp4", QByteArray::fromBase64(QByteArray(kHeAacB64)));
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
    }

    void aLossyTrackSeeksAndPlaysToItsEnd_data()
    {
        QTest::addColumn<QString>("file");
        QTest::addColumn<QString>("tier");
        QTest::newRow("AAC LC, the High tier") << QStringLiteral("/lc.mp4") << QStringLiteral("HIGH");
        QTest::newRow("HE-AAC, the Low tier")  << QStringLiteral("/he.mp4") << QStringLiteral("LOW");
    }

    void aLossyTrackSeeksAndPlaysToItsEnd()
    {
        QFETCH(QString, file);
        QFETCH(QString, tier);
        if (const char *why = obstacle()) QSKIP(why);

        TidalApi      api;
        OneFileClient client{&api};
        client.manifest.type     = StreamManifest::BTS;
        client.manifest.url      = m_server.url(file);
        client.manifest.mimeType = QStringLiteral("audio/mp4");
        client.manifest.codec    = tier;

        Player player{&client};
        player.setMuted(true);
        player.setVolume(0.0);
        // The Player builds its audio objects on the first turn of the loop.
        QTRY_VERIFY_WITH_TIMEOUT(player.findChild<QMediaPlayer *>(), 10000);
        auto *mp = player.findChild<QMediaPlayer *>();
        Watch watch(mp);
        QSignalSpy errorSpy(&player, &Player::error);
        const int servedBefore = m_server.served;

        player.playTracks(QVariantList{ oneTrack() }, 0);
        QTRY_VERIFY2_WITH_TIMEOUT(player.duration() > 0 || !errorSpy.isEmpty(),
                                  "the track neither loaded nor failed", 10000);
        QVERIFY2(errorSpy.isEmpty(), qPrintable(errorSpy.value(0).value(0).toString()));
        QCOMPARE(m_server.served - servedBefore, 1);
        QVERIFY2(qAbs(player.duration() - kAacDurationMs) <= kSlackMs,
                 qPrintable(QStringLiteral("the track is %1 ms long").arg(player.duration())));

        QTRY_VERIFY2_WITH_TIMEOUT(mp->position() >= 600 || watch.ended,
                                  "the track did not start playing", 10000);
        QVERIFY2(!watch.ended, "the track ended before it could be sought in");

        // Backwards, so a seek that did nothing is told from one that worked.
        watch.furthest = 0;
        player.seek(200);
        QTRY_VERIFY2_WITH_TIMEOUT(mp->position() < 600 || watch.ended,
                                  "the position never left where it was", 5000);
        QVERIFY2(!watch.ended, "the track ran to its end past the seek");
        QCOMPARE(mp->playbackState(), QMediaPlayer::PlayingState);

        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
        QVERIFY2(watch.furthest >= kAacDurationMs - kSlackMs,
                 qPrintable(QStringLiteral("the track ended at %1 ms").arg(watch.furthest)));
        QVERIFY2(errorSpy.isEmpty(), qPrintable(errorSpy.value(0).value(0).toString()));
    }

private:
    // Why this Qt on this machine cannot play a track, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // With no audio device one backend crashes in play() and the other
        // runs through the track unpaced.
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
#endif
        return nullptr;
    }

    QTemporaryDir m_dir;
    FileServer    m_server;
};

QTEST_MAIN(TestAac)
#include "tst_aac.moc"
