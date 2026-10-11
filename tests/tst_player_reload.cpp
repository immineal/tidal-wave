// Loads that overtake another or follow one which ended badly. The test holds
// each stream request until it answers it, and the audio is a silent WAV from
// a localhost server. Every Player is muted before its output opens.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QNetworkAccessManager>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

#ifdef Q_OS_UNIX
#include <csignal>
#include <sys/resource.h>
#endif

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

// A lossless manifest with its segments under @BASE@. No "//" inside the raw
// string: moc can take it for a comment.
constexpr auto kLosslessManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
<MPD profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static"
     mediaPresentationDuration="PT1.0S" minBufferTime="PT1.0S">
  <Period id="0" start="PT0.0S">
    <AdaptationSet id="0" contentType="audio" segmentAlignment="true">
      <Representation id="0" mimeType="audio/mp4" codecs="flac"
                      bandwidth="128000" audioSamplingRate="16000">
        <SegmentTemplate timescale="16000" startNumber="1"
                         initialization="@BASE@init.m4s"
                         media="@BASE@chunk-$Number$.m4s">
          <SegmentTimeline>
            <S t="0" d="8000" r="1"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

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

// A localhost origin for the audio. /track is the WAV, /noise is bytes no
// decoder knows, /empty answers with no bytes, /held never answers and every
// other path is not there.
class MediaServer : public QTcpServer {
public:
    explicit MediaServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &MediaServer::accept);
    }

    QByteArray track;
    int        tracksServed = 0;
    int        requestsHeld = 0;

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
                const QByteArray path = buf->mid(4, buf->indexOf(' ', 4) - 4);
                buf->clear();
                if (path == "/held") { ++requestsHeld; return; }
                if (path == "/track") ++tracksServed;
                const bool found = path == "/track" || path == "/noise" || path == "/empty";
                const QByteArray body = path == "/track" ? track
                                      : path == "/noise" ? QByteArray(4096, 'x') : QByteArray();
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

StreamManifest losslessFrom(const QString &xml) {
    StreamManifest m;
    m.type     = StreamManifest::MPD;
    m.url      = xml;
    m.mimeType = QStringLiteral("application/dash+xml");
    m.codec    = QStringLiteral("LOSSLESS");
    return m;
}

// Points TMPDIR elsewhere while it lives. At a plain file no temp file can be
// created, whoever runs the test.
struct TempDirAt {
    const bool       wasSet = qEnvironmentVariableIsSet("TMPDIR");
    const QByteArray was    = qgetenv("TMPDIR");

    explicit TempDirAt(const QString &path) {
        qputenv("TMPDIR", QFile::encodeName(path));
    }
    ~TempDirAt() {
        if (wasSet) qputenv("TMPDIR", was);
        else        qunsetenv("TMPDIR");
    }
};

#ifdef Q_OS_UNIX
// Caps the size of any file this process writes while it lives. A write
// past the cap fails the way a write to a full disk does.
struct FileSizeCap {
    rlimit was{};

    explicit FileSizeCap(rlim_t bytes) {
        std::signal(SIGXFSZ, SIG_IGN);   // the default action ends the process
        getrlimit(RLIMIT_FSIZE, &was);
        rlimit cap = was;
        cap.rlim_cur = bytes;
        setrlimit(RLIMIT_FSIZE, &cap);
    }
    ~FileSizeCap() { setrlimit(RLIMIT_FSIZE, &was); }
};
#endif

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
    // Its finished() comes with each download's own, in the same emission.
    QNetworkAccessManager *network() { return api.findChild<QNetworkAccessManager *>(); }
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

        m_plainFile = m_dir.filePath(QStringLiteral("plain-file"));
        QFile f(m_plainFile);
        QVERIFY(f.open(QIODevice::WriteOnly));
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

    // ── a track left with nothing loaded ────────────────────────────────────

    // Each of these ends a load after the stream request was answered. The
    // user is told, and the next press on play asks for the track again.
    void pressingPlayAsksAgainAfterAFailedLoad_data() {
        QTest::addColumn<QString>("stream");
        QTest::addColumn<bool>("noTempDir");
        QTest::addColumn<QString>("said");

        const QString download = QStringLiteral("Could not download the audio for this track.");
        const QString save     = QStringLiteral("Could not save the audio to a temporary file.");

        QTest::newRow("the download is refused")
            << QStringLiteral("/gone") << false << download;
        QTest::newRow("the download is empty")
            << QStringLiteral("/empty") << false
            << QStringLiteral("Could not download the audio for this track. No data came back.");
        QTest::newRow("the download cannot be saved")
            << QStringLiteral("/track") << true << save;
        QTest::newRow("the lossless details cannot be read")
            << QStringLiteral("unreadable") << false
            << QStringLiteral("Could not read the lossless stream details for this track.");
        QTest::newRow("the lossless join cannot be saved")
            << QStringLiteral("lossless") << true << save;
        QTest::newRow("a lossless segment is refused")
            << QStringLiteral("lossless") << false << download;
    }

    void pressingPlayAsksAgainAfterAFailedLoad() {
        QFETCH(QString, stream);
        QFETCH(bool, noTempDir);
        QFETCH(QString, said);

        StreamManifest manifest;
        if (stream == QLatin1String("unreadable")) {
            manifest = losslessFrom(QStringLiteral("<MPD/>"));
        } else if (stream == QLatin1String("lossless")) {
            QString xml = QString::fromUtf8(kLosslessManifest);
            xml.replace(QStringLiteral("@BASE@"), m_server.url(QStringLiteral("/gone/")));
            manifest = losslessFrom(xml);
        } else {
            manifest = oneFileAt(m_server.url(stream));
        }

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(3000, 2), 0);
        QCOMPARE(a.client.asked, (QList<qlonglong>{3000}));

        {
            std::unique_ptr<TempDirAt> full;
            if (noTempDir) full = std::make_unique<TempDirAt>(m_plainFile);
            QVERIFY(a.client.answer(3000, manifest));
            QTRY_COMPARE_WITH_TIMEOUT(errorSpy.count(), 1, 10000);
        }
        const QString msg = errorSpy.at(0).at(0).toString();
        QVERIFY2(msg.startsWith(said), qPrintable(msg));
        QVERIFY(!a.p().loading());

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{3000, 3000}));
        QVERIFY(a.p().loading());
    }

    // The second request can succeed. The track then plays, and the press
    // after that pauses it.
    void theTrackPlaysOnceTheSecondRequestSucceeds() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, oneFileAt(m_server.url(QStringLiteral("/gone")))));
        QTRY_COMPARE_WITH_TIMEOUT(errorSpy.count(), 1, 10000);

        a.p().playPause();
        QVERIFY2(a.client.answer(3000, oneFileAt(m_server.url(QStringLiteral("/track")))),
                 "the press on play asked for nothing");
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);

        a.p().playPause();
        QTRY_VERIFY_WITH_TIMEOUT(!a.p().playing(), 5000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{3000, 3000}));
        QCOMPARE(errorSpy.count(), 1);
    }

    // A restored track whose stream resolved and whose download then failed.
    // The press on play is the user's: the track plays from where it was left.
    void aRestoredTrackWhoseDownloadFailedPlaysOnThePress() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QSignalSpy errorSpy(&b.p(), &Player::error);
        QVERIFY(b.client.answer(1002, oneFileAt(m_server.url(QStringLiteral("/gone")))));
        QTRY_COMPARE_WITH_TIMEOUT(errorSpy.count(), 1, 10000);
        QCOMPARE(b.p().position(), qint64(12000));

        b.p().playPause();
        QVERIFY2(b.client.answer(1002, oneFileAt(m_server.url(QStringLiteral("/track")))),
                 "the press on play asked for nothing");
        QTRY_VERIFY2_WITH_TIMEOUT(b.p().playing(), "the press on play left it paused", 10000);
        QTRY_VERIFY_WITH_TIMEOUT(b.mp()->position() >= 11500, 5000);
        QCOMPARE(b.p().queueCount(), 5);
    }

    // A file the backend cannot open reaches the player as an error and as
    // invalid media. The user is told once, in the player's own sentence.
    void aFileTheBackendCannotOpenIsReportedOnce() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, oneFileAt(m_server.url(QStringLiteral("/noise")))));

        QTRY_VERIFY_WITH_TIMEOUT(a.mp()->mediaStatus() == QMediaPlayer::InvalidMedia, 10000);
        QTest::qWait(300);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track could not be played. "
                                "The audio format may not be supported."));
    }

    // ── replies nobody is waiting for ───────────────────────────────────────

    // Moving on aborts the download in flight, which is the player's own
    // doing. Nothing is reported, and the track now asked for shows as loading.
    void movingOnDuringADownloadReportsNothing() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        const int heldBefore = m_server.requestsHeld;

        a.p().playTracks(contextOf(5000, 2), 0);
        QVERIFY(a.client.answer(5000, oneFileAt(m_server.url(QStringLiteral("/held")))));
        QTRY_COMPARE_WITH_TIMEOUT(m_server.requestsHeld, heldBefore + 1, 5000);

        a.p().next();
        QCOMPARE(currentId(a.p()), 5001);
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY2(a.p().loading(), "the aborted download lowered the next track's loading flag");
    }

    // Two clicks on one row are two requests for one track. Only the second
    // is acted on: one download, and no file left behind for the first.
    void aTrackAskedForTwiceIsFetchedOnce() {
        if (const char *why = obstacle()) QSKIP(why);
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const TempDirAt own(tmp.path());
        const int servedBefore = m_server.tracksServed;
        {
            Launch a;
            QVERIFY(a.audioUp());
            a.p().playTracks(contextOf(5000, 2), 0);
            a.p().playTracks(contextOf(5000, 2), 0);
            QCOMPARE(a.client.asked, (QList<qlonglong>{5000, 5000}));
            QVERIFY(a.client.answer(5000, oneFileAt(m_server.url(QStringLiteral("/track")))));
            QVERIFY(a.client.answer(5000, oneFileAt(m_server.url(QStringLiteral("/track")))));

            QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
            QTest::qWait(300);
            QCOMPARE(m_server.tracksServed - servedBefore, 1);
        }
        QCOMPARE(QDir(tmp.path()).entryList(QDir::Files), QStringList());
    }

    // The first of two requests fails after the second went out. The failure
    // belongs to a load that was replaced, so it is neither reported nor owed.
    void aStaleFailureDoesNotSpeakForTheLoadThatReplacedIt() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(5000, 2), 0);
        a.p().playTracks(contextOf(5000, 2), 0);

        QVERIFY(a.client.answer(5000, StreamManifest(), QStringLiteral("Host not found")));
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY(a.p().loading());

        QVERIFY(a.client.answer(5000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        a.p().playPause();
        QTRY_VERIFY_WITH_TIMEOUT(!a.p().playing(), 5000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{5000, 5000}));
    }

    // Removing the playing row aborts the preload of the row after it, which
    // then loads as the playing one. The row after that is still fetched ahead.
    void anAbortedPreloadIsNotRememberedAsAFailedOne() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        const int heldBefore = m_server.requestsHeld;
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        a.p().playTracks(contextOf(6000, 3), 0);
        QVERIFY(a.client.answer(6000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.loaded(), 10000);
        a.mp()->setPosition(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{6000, 6001}), 5000);
        QVERIFY(a.client.answer(6001, oneFileAt(m_server.url(QStringLiteral("/held")))));
        QTRY_COMPARE_WITH_TIMEOUT(m_server.requestsHeld, heldBefore + 1, 5000);

        a.p().removeFromQueue(0);
        QCOMPARE(currentId(a.p()), 6001);
        QCOMPARE(a.client.asked, (QList<qlonglong>{6000, 6001, 6001}));
        QVERIFY(a.client.answer(6001, track));
        QTRY_VERIFY_WITH_TIMEOUT(!a.mp()->source().isEmpty() && a.loaded(), 10000);

        a.mp()->setPosition(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked,
                                  (QList<qlonglong>{6000, 6001, 6001, 6002}), 5000);
    }

    // ── a disk with no room ─────────────────────────────────────────────────

    // The temp file opens and the write into it comes up short. The user is
    // told about the disk, play asks again, and the short file is not kept.
    void aDownloadThatDoesNotFitOnDiskIsReported() {
#ifndef Q_OS_UNIX
        QSKIP("a full disk is staged with a POSIX file size limit");
#else
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const TempDirAt own(tmp.path());
        {
            Launch a;
            QVERIFY(a.audioUp());
            QSignalSpy errorSpy(&a.p(), &Player::error);
            QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
            a.p().playTracks(contextOf(7000, 2), 0);
            {
                const FileSizeCap full(4096);
                QVERIFY(a.client.answer(7000, oneFileAt(m_server.url(QStringLiteral("/track")))));
                QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 1, 10000);
            }
            QCOMPARE(errorSpy.count(), 1);
            const QString msg = errorSpy.at(0).at(0).toString();
            QVERIFY2(msg.startsWith(QStringLiteral("Could not save the audio to a temporary file.")),
                     qPrintable(msg));
            QVERIFY(!a.p().loading());
            QCOMPARE(QDir(tmp.path()).entryList(QDir::Files), QStringList());

            a.p().playPause();
            QCOMPARE(a.client.asked, (QList<qlonglong>{7000, 7000}));
        }
#endif
    }

    // The same shortfall in a preload costs only the preload. The short file
    // is not handed over: the track is asked for again when it is reached.
    void aPreloadThatDoesNotFitOnDiskIsNotHandedOver() {
#ifndef Q_OS_UNIX
        QSKIP("a full disk is staged with a POSIX file size limit");
#else
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        a.p().playTracks(contextOf(7000, 2), 0);
        QVERIFY(a.client.answer(7000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.loaded(), 10000);
        QCOMPARE(fetched.count(), 1);

        a.mp()->setPosition(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{7000, 7001}), 5000);
        {
            const FileSizeCap full(4096);
            QVERIFY(a.client.answer(7001, track));
            QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);
        }

        a.p().next();
        QCOMPARE(currentId(a.p()), 7001);
        QCOMPARE(a.client.asked, (QList<qlonglong>{7000, 7001, 7001}));
#endif
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
    QString       m_plainFile;
};

QTEST_MAIN(TestPlayerReload)
#include "tst_player_reload.moc"
