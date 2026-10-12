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
#include "ui/I18n.h"
#include "ui/Prefs.h"

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

    int waiting() const { return int(m_held.count()); }

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
    m.reason = StreamManifest::Gone;
    return m;
}

// What comes with a 404: Qt's text for the transfer.
const QString kGone = QStringLiteral(
    "Error transferring https://api.example.invalid/v1/tracks/1 - server replied: Not Found");

QString skipped(qlonglong id) {
    return QStringLiteral("“T%1” is no longer available on Tidal and was skipped.").arg(id);
}

// Tidal has the track and does not play it to this account.
StreamManifest notForAccount() {
    StreamManifest m;
    m.reason = StreamManifest::NotForAccount;
    return m;
}

// What comes with a preview: the client's own sentence.
const QString kPreview = QStringLiteral(
    "Tidal returned only a preview of this track, not the whole track.");

QString passedOver(qlonglong id) {
    return QStringLiteral("“T%1” is not available for your account or region and was skipped.")
        .arg(id);
}

const QString kSeveralNotForAccount = QStringLiteral(
    "Several tracks are not available for your account or region and were skipped.");

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
    // The backend plays. Player::playing() is true before that, while a load
    // is on its way there.
    bool started() { return mp()->playbackState() == QMediaPlayer::PlayingState; }
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
        QTRY_VERIFY2_WITH_TIMEOUT(b.started(),
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
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

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
        QTRY_VERIFY2_WITH_TIMEOUT(b.started(), "the press on play left it paused", 10000);
        QTRY_VERIFY_WITH_TIMEOUT(b.mp()->position() >= 11500, 5000);
        QCOMPARE(b.p().queueCount(), 5);
    }

    // A file the backend cannot open reaches the player as an error, and on
    // some Qt versions as invalid media as well. The user is told once, in
    // the player's own sentence.
    void aFileTheBackendCannotOpenIsReportedOnce() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, oneFileAt(m_server.url(QStringLiteral("/noise")))));

        QTRY_VERIFY_WITH_TIMEOUT(errorSpy.count() >= 1, 10000);
        QTest::qWait(500);
        QCOMPARE(errorSpy.count(), 1);
        QVERIFY(!a.p().loading());
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track could not be played. "
                                "The audio format may not be supported."));
    }

    // Nothing is loaded behind such a track, whichever way its file came to
    // the backend. The player does not say that it plays, and the next press
    // on play asks for the track again.
    void aFileTheBackendCannotOpenLeavesTheLoadOwed_data() {
        QTest::addColumn<QString>("how");
        QTest::newRow("a track the user picked") << QStringLiteral("picked");
        QTest::newRow("a restored track")        << QStringLiteral("restored");
        QTest::newRow("a track fetched ahead")   << QStringLiteral("ahead");
    }

    void aFileTheBackendCannotOpenLeavesTheLoadOwed() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, how);
        const StreamManifest noise = oneFileAt(m_server.url(QStringLiteral("/noise")));
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));
        if (how == QLatin1String("restored")) QVERIFY(saveFiveRowSession());

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        qlonglong id = 3000;
        if (how == QLatin1String("restored")) {
            id = 1002;
            QVERIFY(a.client.answer(id, noise));
        } else if (how == QLatin1String("ahead")) {
            // Downloaded while the track before it plays, handed over at its end.
            id = 3001;
            a.p().playTracks(contextOf(3000, 3), 0);
            QVERIFY(a.client.answer(3000, track));
            QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
            a.p().seek(6000);
            QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{3000, 3001}), 5000);
            QVERIFY(a.client.answer(id, noise));
            QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);
            a.p().seek(29000);
        } else {
            a.p().playTracks(contextOf(3000, 2), 0);
            QVERIFY(a.client.answer(id, noise));
        }

        QTRY_VERIFY_WITH_TIMEOUT(errorSpy.count() >= 1, 15000);
        QTest::qWait(500);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track could not be played. "
                                "The audio format may not be supported."));
        QCOMPARE(currentId(a.p()), id);
        QVERIFY(!a.p().loading());
        QVERIFY2(!a.p().playing(), "the player says it plays a file the backend could not open");
        QVERIFY2(a.mp()->playbackState() == QMediaPlayer::StoppedState,
                 "the backend was started on a file it could not open");

        const QList<qlonglong> asked = a.client.asked;
        a.p().playPause();
        QVERIFY2(a.client.asked == asked + QList<qlonglong>{id},
                 "the press on play asked for nothing");
        QVERIFY(a.p().loading());
        QVERIFY(a.client.answer(id, track));
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the track did not play once its file opened",
                                  10000);
        QCOMPARE(errorSpy.count(), 1);
    }

    // ── a track Tidal no longer has ─────────────────────────────────────────

    // Picked by the user, it stays where it is and is named for what it is,
    // without the transfer's text. Play asks again, as after any failed load.
    void aWithdrawnTrackTheUserPicksIsReportedInOneSentence() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 3), 1);
        QVERIFY(a.client.answer(8001, ruledOut(), kGone));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track is no longer available on Tidal."));
        QCOMPARE(currentId(a.p()), 8001);
        QCOMPARE(a.p().queueCount(), 3);
        QVERIFY(!a.p().loading());
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 8001}));
    }

    // The queue comes onto it by itself or by a step. The row is dropped, the
    // user is told once which one, and the row beyond it plays.
    void theQueueStepsOverAWithdrawnTrack_data() {
        QTest::addColumn<QString>("move");
        QTest::addColumn<qlonglong>("from");
        QTest::addColumn<qlonglong>("lands");
        QTest::newRow("Next")              << QStringLiteral("next")     << 8001LL << 8003LL;
        QTest::newRow("Previous")          << QStringLiteral("previous") << 8003LL << 8001LL;
        QTest::newRow("the track ran out") << QStringLiteral("end")      << 8001LL << 8003LL;
    }

    void theQueueStepsOverAWithdrawnTrack() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, move);
        QFETCH(qlonglong, from);
        QFETCH(qlonglong, lands);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 5), int(from - 8000));
        QVERIFY(a.client.answer(from, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        if (move == QLatin1String("next")) {
            a.p().next();
        } else if (move == QLatin1String("previous")) {
            a.p().previous();
        } else {
            // The request made ahead of time stays out, so the row is asked
            // for again when the track before it has run out.
            a.p().seek(29000);
            QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{from, 8002, 8002}), 10000);
            QVERIFY(a.client.answer(8002, ruledOut(), kGone));
        }
        QCOMPARE(currentId(a.p()), 8002);
        QVERIFY(a.client.answer(8002, ruledOut(), kGone));

        QCOMPARE(currentId(a.p()), lands);
        QCOMPARE(a.client.asked.constLast(), lands);
        QCOMPARE(a.p().queueCount(), 4);
        QVERIFY(a.p().loading());
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), skipped(8002));

        QVERIFY(a.client.answer(lands, track));
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the row beyond the withdrawn one never played",
                                  10000);
        QCOMPARE(a.p().loadError(), skipped(8002));
        QCOMPARE(errorSpy.count(), 1);
    }

    // A step taken while the restored track is still loading is a step like
    // any other: it passes over the withdrawn row, says so, and plays.
    void aStepTakenDuringARestorePassesOverAWithdrawnTrack() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QSignalSpy errorSpy(&b.p(), &Player::error);
        b.p().next();
        QVERIFY(b.client.answer(1003, ruledOut(), kGone));

        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003, 1004}));
        QCOMPARE(currentId(b.p()), 1004);
        QCOMPARE(b.p().queueCount(), 4);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), skipped(1003));
        QVERIFY(b.client.answer(1004, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY2_WITH_TIMEOUT(b.started(), "the row beyond the withdrawn one came up paused",
                                  10000);
    }

    // Nothing that plays is left ahead. The queue ends on the last row it
    // still has, stopped, and asks for nothing more until play is pressed.
    void aQueueWithNothingPlayableAheadEnds() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        a.p().next();
        QVERIFY(a.client.answer(8001, ruledOut(), kGone));
        QVERIFY(a.client.answer(8002, ruledOut(), kGone));

        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002}));
        QCOMPARE(a.p().queueCount(), 1);
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(!a.p().loading());
        QVERIFY(!a.p().playing());
        QCOMPARE(a.p().loadError(),
                 QStringLiteral("Several tracks are no longer available on Tidal and were skipped."));
        QTest::qWait(300);
        QCOMPARE(a.client.waiting(), 0);

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002, 8000}));
    }

    // Repeat and shuffle send the queue round again. Each row is still asked
    // for once, and a queue with nothing left in it is empty and at rest.
    void repeatAndShuffleDoNotGoRoundAQueueOfWithdrawnTracks_data() {
        QTest::addColumn<int>("repeat");
        QTest::addColumn<bool>("shuffle");
        QTest::newRow("repeat all")             << 1 << false;
        QTest::newRow("repeat one")             << 2 << false;
        QTest::newRow("shuffle and repeat all") << 1 << true;
    }

    void repeatAndShuffleDoNotGoRoundAQueueOfWithdrawnTracks() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(int, repeat);
        QFETCH(bool, shuffle);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().setShuffle(shuffle);
        a.p().setRepeatMode(repeat);
        a.p().playTracks(contextOf(8000, 5), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        // From here on Tidal has none of them, the one that played included.
        a.p().next();
        int answered = 0;
        while (a.client.waiting() > 0 && answered < 50) {
            QVERIFY(a.client.answer(a.client.asked.constLast(), ruledOut(), kGone));
            ++answered;
        }

        QCOMPARE(answered, 5);
        QCOMPARE(a.p().queueCount(), 0);
        QVERIFY(a.p().currentTrackMap().isEmpty());
        QVERIFY(!a.p().loading());
        QVERIFY(!a.p().playing());
    }

    // The row ahead is asked for while the current one plays. Withdrawn, it
    // must not be where the change at the end of the track lands.
    void theChangeAtTheEndOfATrackPassesOverAWithdrawnRow() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);
        QVERIFY(a.client.answer(8001, ruledOut(), kGone));

        // Tidal goes on answering the same for both rows.
        a.p().seek(29000);
        const bool arrived = QTest::qWaitFor([&] {
            while (a.client.answer(8001, ruledOut(), kGone)) {}
            while (a.client.answer(8002, track)) {}
            return currentId(a.p()) == 8002 && a.started();
        }, 15000);

        QCOMPARE(currentId(a.p()), 8002);
        QVERIFY2(arrived, "the third row was reached and did not start");
        QVERIFY(a.p().playing());
        QCOMPARE(a.p().queueCount(), 2);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), skipped(8001));
    }

    // Dropped ahead of time, the withdrawn row leaves its place to the next
    // one, which is fetched ahead and handed over without a second request.
    void theRowBeyondAWithdrawnOneIsFetchedAheadInItsPlace() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);

        QVERIFY(a.client.answer(8001, ruledOut(), kGone));
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(a.p().playing());
        QCOMPARE(a.p().queueCount(), 2);
        QCOMPARE(a.p().loadError(), skipped(8001));

        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001, 8002}), 5000);
        QVERIFY(a.client.answer(8002, track));
        QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);

        a.p().seek(29000);
        QTRY_COMPARE_WITH_TIMEOUT(currentId(a.p()), 8002, 10000);
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002}));
    }

    // ── a track Tidal has and does not play to this account ─────────────────

    // Picked by the user, it is named for what it is. Nothing says that Tidal
    // no longer has it.
    void aTrackTheAccountMayNotPlayIsNamedAsThat() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 3), 1);
        QVERIFY(a.client.answer(8001, notForAccount(), kPreview));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track is not available for your account or region."));
        QCOMPARE(currentId(a.p()), 8001);
        QCOMPARE(a.p().queueCount(), 3);
        QVERIFY(!a.p().loading());

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 8001}));
    }

    // The queue comes onto it by itself or by a step. The row stays in the
    // queue, the user is told once which one, and the row beyond it plays.
    void theQueuePassesOverATrackTheAccountMayNotPlayAndKeepsIt_data() {
        QTest::addColumn<QString>("move");
        QTest::addColumn<qlonglong>("from");
        QTest::addColumn<qlonglong>("lands");
        QTest::newRow("Next")              << QStringLiteral("next")     << 8001LL << 8003LL;
        QTest::newRow("Previous")          << QStringLiteral("previous") << 8003LL << 8001LL;
        QTest::newRow("the track ran out") << QStringLiteral("end")      << 8001LL << 8003LL;
    }

    void theQueuePassesOverATrackTheAccountMayNotPlayAndKeepsIt() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, move);
        QFETCH(qlonglong, from);
        QFETCH(qlonglong, lands);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 5), int(from - 8000));
        QVERIFY(a.client.answer(from, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        if (move == QLatin1String("next")) {
            a.p().next();
        } else if (move == QLatin1String("previous")) {
            a.p().previous();
        } else {
            // Asked for ahead of time and again when the track before it ran out.
            a.p().seek(29000);
            QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{from, 8002, 8002}), 10000);
            QVERIFY(a.client.answer(8002, notForAccount(), kPreview));
        }
        QCOMPARE(currentId(a.p()), 8002);
        QVERIFY(a.client.answer(8002, notForAccount(), kPreview));

        QCOMPARE(currentId(a.p()), lands);
        QCOMPARE(a.client.asked.constLast(), lands);
        QVERIFY2(a.p().queueCount() == 5, "the row the account may not play was removed");
        QVERIFY(a.p().loading());
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), passedOver(8002));

        QVERIFY(a.client.answer(lands, track));
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the row beyond the one passed over never played",
                                  10000);
        QCOMPARE(a.p().loadError(), passedOver(8002));
        QCOMPARE(errorSpy.count(), 1);
    }

    // Found out while it is still the row ahead, it keeps its place and
    // nothing is said. The change at the end of the track passes over it.
    void aRowAheadTheAccountMayNotPlayIsKeptUntilTheQueueReachesIt() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);

        QVERIFY(a.client.answer(8001, notForAccount(), kPreview));
        QCOMPARE(a.p().queueCount(), 3);
        QCOMPARE(a.p().loadError(), QString());
        QVERIFY(a.p().playing());
        QTest::qWait(300);
        QVERIFY2(a.client.asked == (QList<qlonglong>{8000, 8001}),
                 "the row ahead was asked for again while the track before it played");

        a.p().seek(29000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001, 8001}), 10000);
        QVERIFY(a.client.answer(8001, notForAccount(), kPreview));
        QCOMPARE(currentId(a.p()), 8002);
        QVERIFY(a.client.answer(8002, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        QCOMPARE(a.p().queueCount(), 3);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), passedOver(8001));
    }

    // Two rows passed over one after the other are told as one. The sentence
    // gives the reason where both have the same, and none where they differ.
    void rowsPassedOverTogetherAreToldAsOne_data() {
        QTest::addColumn<bool>("firstGone");
        QTest::addColumn<bool>("secondGone");
        QTest::addColumn<int>("rowsLeft");
        QTest::addColumn<QString>("said");
        QTest::newRow("neither is for this account") << false << false << 5 << kSeveralNotForAccount;
        QTest::newRow("Tidal has neither") << true << true << 3
            << QStringLiteral("Several tracks are no longer available on Tidal and were skipped.");
        const QString mixed = QStringLiteral("Several tracks are not available and were skipped.");
        QTest::newRow("gone, then not for this account") << true  << false << 4 << mixed;
        QTest::newRow("not for this account, then gone") << false << true  << 4 << mixed;
    }

    void rowsPassedOverTogetherAreToldAsOne() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(bool, firstGone);
        QFETCH(bool, secondGone);
        QFETCH(int, rowsLeft);
        QFETCH(QString, said);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(8000, 5), 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        a.p().next();
        QVERIFY(firstGone ? a.client.answer(8001, ruledOut(), kGone)
                          : a.client.answer(8001, notForAccount(), kPreview));
        QVERIFY(secondGone ? a.client.answer(8002, ruledOut(), kGone)
                           : a.client.answer(8002, notForAccount(), kPreview));

        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002, 8003}));
        QCOMPARE(currentId(a.p()), 8003);
        QCOMPARE(a.p().queueCount(), rowsLeft);
        QCOMPARE(a.p().loadError(), said);
        QVERIFY(a.client.answer(8003, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
    }

    // Nothing ahead is for this account. Every row is still there, and the
    // queue rests on the last one it asked for until play is pressed.
    void aQueueWithNothingForTheAccountAheadEndsWhole() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        a.p().next();
        QVERIFY(a.client.answer(8001, notForAccount(), kPreview));
        QVERIFY(a.client.answer(8002, notForAccount(), kPreview));

        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002}));
        QCOMPARE(a.p().queueCount(), 3);
        QCOMPARE(currentId(a.p()), 8002);
        QVERIFY(!a.p().loading());
        QVERIFY(!a.p().playing());
        QCOMPARE(a.p().loadError(), kSeveralNotForAccount);
        QTest::qWait(300);
        QCOMPARE(a.client.waiting(), 0);

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 8002, 8002}));
    }

    // Kept rows could be gone round for ever. Each is asked for once, and the
    // queue comes to rest with all of them in it.
    void repeatDoesNotGoRoundAQueueTheAccountMayNotPlay_data() {
        QTest::addColumn<int>("repeat");
        QTest::addColumn<bool>("shuffle");
        QTest::newRow("repeat all")             << 1 << false;
        QTest::newRow("repeat one")             << 2 << false;
        QTest::newRow("shuffle and repeat all") << 1 << true;
    }

    void repeatDoesNotGoRoundAQueueTheAccountMayNotPlay() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(int, repeat);
        QFETCH(bool, shuffle);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().setShuffle(shuffle);
        a.p().setRepeatMode(repeat);
        a.p().playTracks(contextOf(8000, 3), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        // From here on the account gets none of them, the one that played included.
        a.p().next();
        int answered = 0;
        while (a.client.waiting() > 0 && answered < 50) {
            QVERIFY(a.client.answer(a.client.asked.constLast(), notForAccount(), kPreview));
            ++answered;
        }

        QCOMPARE(answered, 3);
        QCOMPARE(a.p().queueCount(), 3);
        QVERIFY(!a.p().loading());
        QVERIFY(!a.p().playing());
        QCOMPARE(a.p().loadError(), kSeveralNotForAccount);
    }

    // ── a run of rows that cannot be played ─────────────────────────────────

    // Five rows in a row are passed over and the sixth is not asked for. The
    // queue rests on it, the rows beyond are as they were, and one sentence
    // says why. Play asks for the row it rests on.
    void aRunOfRowsThatCannotBePlayedEnds_data() {
        QTest::addColumn<QString>("answers");   // g: gone, a: not for this account
        QTest::addColumn<int>("rowsLeft");
        QTest::addColumn<QString>("said");
        QTest::newRow("Tidal has none of them") << QStringLiteral("ggggg") << 5
            << QStringLiteral("Several tracks in a row are no longer available on Tidal, "
                              "so playback stopped here.");
        QTest::newRow("none is for this account") << QStringLiteral("aaaaa") << 10
            << QStringLiteral("Several tracks in a row are not available for your account "
                              "or region, so playback stopped here.");
        QTest::newRow("some of each") << QStringLiteral("gagag") << 7
            << QStringLiteral("Several tracks in a row are not available, "
                              "so playback stopped here.");
    }

    void aRunOfRowsThatCannotBePlayedEnds() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, answers);
        QFETCH(int, rowsLeft);
        QFETCH(QString, said);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        a.p().playTracks(contextOf(8000, 10), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        a.p().next();
        for (int i = 0; i < answers.size(); ++i) {
            const qlonglong id = 8001 + i;
            QCOMPARE(a.client.asked.constLast(), id);
            QVERIFY(answers.at(i) == QLatin1Char('g')
                        ? a.client.answer(id, ruledOut(), kGone)
                        : a.client.answer(id, notForAccount(), kPreview));
        }

        QVERIFY2(a.client.asked == (QList<qlonglong>{8000, 8001, 8002, 8003, 8004, 8005}),
                 "a sixth row was asked for");
        QCOMPARE(a.client.waiting(), 0);
        QCOMPARE(currentId(a.p()), 8006);
        QCOMPARE(a.p().queueCount(), rowsLeft);
        QVERIFY(!a.p().loading());
        QVERIFY(!a.p().playing());
        QCOMPARE(a.p().loadError(), said);
        int told = 0;
        for (const QList<QVariant> &args : errorSpy)
            if (args.at(0).toString() == said) ++told;
        QCOMPARE(told, 1);

        a.p().playPause();
        QCOMPARE(a.client.asked.count(), 7);
        QCOMPARE(a.client.asked.constLast(), 8006);
    }

    // Rows ahead that Tidal no longer has are dropped up to the same number.
    // The next one keeps its place, and nothing beyond it is asked for.
    void rowsAheadAreDroppedUpToTheSameNumber() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(8000, 10), 0);
        QVERIFY(a.client.answer(8000, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);

        for (qlonglong id = 8001; id <= 8006; ++id) {
            QTRY_COMPARE_WITH_TIMEOUT(a.client.asked.constLast(), id, 5000);
            QVERIFY(a.client.answer(id, ruledOut(), kGone));
        }

        QVERIFY2(a.p().queueCount() == 5, "a sixth row ahead was dropped");
        QTest::qWait(500);
        QCOMPARE(a.client.asked.count(), 7);
        QVERIFY(a.p().playing());
        QCOMPARE(a.p().loadError(),
                 QStringLiteral("Several tracks are no longer available on Tidal and were skipped."));
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

            QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
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
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
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
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{6000, 6001}), 5000);
        QVERIFY(a.client.answer(6001, oneFileAt(m_server.url(QStringLiteral("/held")))));
        QTRY_COMPARE_WITH_TIMEOUT(m_server.requestsHeld, heldBefore + 1, 5000);

        a.p().removeFromQueue(0);
        QCOMPARE(currentId(a.p()), 6001);
        QCOMPARE(a.client.asked, (QList<qlonglong>{6000, 6001, 6001}));
        QVERIFY(a.client.answer(6001, track));
        QTRY_VERIFY_WITH_TIMEOUT(!a.mp()->source().isEmpty() && a.loaded(), 10000);

        a.p().seek(6000);
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

        a.p().seek(6000);
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

    // ── a press while a track loads ─────────────────────────────────────────

    // The track that is being loaded is on its way to playing, and is told as
    // playing from the step on: the play button shows no pause in between.
    void aStepToAnotherTrackIsNoPause() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        QSignalSpy playingSpy(&a.p(), &Player::playingChanged);
        a.p().next();
        const bool saidWhileLoading = a.p().playing();
        QVERIFY(a.client.answer(3001, track));
        QTRY_VERIFY_WITH_TIMEOUT(currentId(a.p()) == 3001 && a.started(), 10000);
        QTest::qWait(300);
        QVERIFY2(playingSpy.isEmpty(),
                 qPrintable(QStringLiteral("playing was announced %1 times on the way")
                                .arg(playingSpy.count())));
        QVERIFY(saidWhileLoading);
        QVERIFY(a.p().playing());
        QVERIFY(!a.p().loading());
    }

    void aPressDuringALoadDecidesWhatItEndsIn_data() {
        QTest::addColumn<QString>("load");
        QTest::addColumn<int>("presses");
        const QString held = QStringLiteral("held"), restored = QStringLiteral("restored"),
                      users = QStringLiteral("users");
        QTest::newRow("play, a step held paused")                 << held     << 1;
        QTest::newRow("play then pause, a step held paused")      << held     << 2;
        QTest::newRow("play, a restored track")                   << restored << 1;
        QTest::newRow("play then pause, a restored track")        << restored << 2;
        QTest::newRow("pause, a load the user started")           << users    << 1;
        QTest::newRow("pause then play, a load the user started") << users    << 2;
    }

    // The stream request is still out when play or pause is pressed. The press
    // decides what the load ends in, shows at once, and a second one undoes it.
    void aPressDuringALoadDecidesWhatItEndsIn() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, load);
        QFETCH(int, presses);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        std::unique_ptr<Launch> l;
        qlonglong id = 1002;
        bool plays = false;   // what the load ends in as it stands
        if (load == QLatin1String("restored")) {
            QVERIFY(saveFiveRowSession());
            l = std::make_unique<Launch>();
            QVERIFY(l->audioUp());
        } else {
            l = std::make_unique<Launch>();
            QVERIFY(l->audioUp());
            l->p().playTracks(contextOf(1000, 5), 2);
            plays = true;
        }
        if (load == QLatin1String("held")) {
            // A step MPRIS takes on a paused player.
            QVERIFY(l->client.answer(1002, track));
            QTRY_VERIFY_WITH_TIMEOUT(l->started(), 10000);
            l->p().playPause();
            QTRY_COMPARE_WITH_TIMEOUT(l->mp()->playbackState(), QMediaPlayer::PausedState, 5000);
            l->p().next(true);
            id = 1003;
            plays = false;
        }
        Player &p = l->p();
        QCOMPARE(currentId(p), id);
        QVERIFY(p.loading());
        const QList<qlonglong> asked = l->client.asked;
        const bool saidAtFirst = p.playing();
        const bool playsAtFirst = plays;

        QSignalSpy playingSpy(&p, &Player::playingChanged);
        QList<bool> said, due;
        for (int i = 0; i < presses; ++i) {
            p.playPause();
            plays = !plays;
            said.append(p.playing());
            due.append(plays);
        }

        QVERIFY(l->client.answer(id, track));
        QTRY_VERIFY_WITH_TIMEOUT(
            l->loaded() && l->mp()->playbackState() != QMediaPlayer::StoppedState, 10000);
        QTest::qWait(300);
        if (plays) {
            QVERIFY2(l->started(), "the press on play was lost and the track came up paused");
        } else {
            QVERIFY2(l->mp()->playbackState() == QMediaPlayer::PausedState,
                     "the press on pause was lost and the track plays");
        }
        QCOMPARE(saidAtFirst, playsAtFirst);
        QCOMPARE(said, due);
        // Each press was announced, and the arrival of the track changed nothing.
        QList<bool> told;
        for (const QList<QVariant> &args : playingSpy) told.append(args.at(0).toBool());
        QCOMPARE(told, due);
        QCOMPARE(p.playing(), plays);
        QVERIFY(!p.loading());
        QCOMPARE(l->client.asked.mid(0, asked.count()), asked);
        // Only the row ahead may have been asked for since.
        QVERIFY(l->client.asked.count() <= asked.count() + 1);
        if (load == QLatin1String("restored")) {
            // From where it was left, either way.
            if (plays) QTRY_VERIFY_WITH_TIMEOUT(l->mp()->position() >= 11500, 5000);
            else       QTRY_VERIFY_WITH_TIMEOUT(qAbs(l->mp()->position() - 12000) < 250, 5000);
        }
    }

    // Play pressed on a restored track makes the load the user's own. What
    // goes wrong with it then is said, and a withdrawn track keeps its row.
    void aPlayPressDuringARestoreMakesTheLoadTheUsers_data() {
        QTest::addColumn<bool>("withdrawn");
        QTest::addColumn<bool>("signedInLater");
        QTest::addColumn<QString>("sentence");
        const QString gone = QStringLiteral("This track is no longer available on Tidal.");
        QTest::newRow("Tidal is out of reach")
            << false << false << QStringLiteral("Could not load this track for playback.");
        QTest::newRow("Tidal no longer has the track") << true << false << gone;
        QTest::newRow("Tidal no longer has the track, signed in after a step")
            << true << true << gone;
    }

    void aPlayPressDuringARestoreMakesTheLoadTheUsers() {
        QFETCH(bool, withdrawn);
        QFETCH(bool, signedInLater);
        QFETCH(QString, sentence);
        QVERIFY(saveFiveRowSession());

        Launch b(!signedInLater);
        QVERIFY(b.audioUp());
        if (signedInLater) {
            // The queue was on its way forward before the account came.
            b.p().playTracks(contextOf(9000, 2), 0);
            b.p().next();
            b.p().clearQueue();
            b.client.setUserId(kUser);
        }
        QCOMPARE(currentId(b.p()), 1002);
        QList<qlonglong> asked = b.client.asked;
        QCOMPARE(asked.constLast(), 1002);
        QSignalSpy errorSpy(&b.p(), &Player::error);
        b.p().playPause();
        QVERIFY(withdrawn ? b.client.answer(1002, ruledOut(), kGone)
                          : b.client.answer(1002, StreamManifest(), QStringLiteral("Host not found")));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), sentence);
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.p().queueCount(), 5);
        QCOMPARE(b.client.asked, asked);
        QVERIFY(!b.p().loading());
        QVERIFY(!b.p().playing());

        b.p().playPause();
        asked.append(1002);
        QCOMPARE(b.client.asked, asked);
    }

    // The file is with the backend, which is still opening it. Pause pressed
    // in that moment counts as well.
    void pausePressedWhileTheBackendOpensTheFileCounts() {
        if (const char *why = obstacle()) QSKIP(why);

        bool pressed = false;
        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(3000, 2), 0);
        // On the turn of the loop after the file was handed over.
        connect(a.mp(), &QMediaPlayer::sourceChanged, &a.p(), [&](const QUrl &source) {
            if (source.isEmpty() || pressed) return;
            pressed = true;
            QMetaObject::invokeMethod(&a.p(), [&a] { a.p().playPause(); }, Qt::QueuedConnection);
        });
        QVERIFY(a.client.answer(3000, oneFileAt(m_server.url(QStringLiteral("/track")))));

        QTRY_VERIFY_WITH_TIMEOUT(
            pressed && a.loaded() && a.mp()->playbackState() != QMediaPlayer::StoppedState, 10000);
        QTest::qWait(300);
        QVERIFY2(a.mp()->playbackState() == QMediaPlayer::PausedState,
                 "the press on pause was lost and the track plays");
        QVERIFY(!a.p().playing());
        QVERIFY(!a.p().loading());
    }

    // Without its entry in the catalogue a sentence comes out in English.
    // Last, because the German stays installed.
    void theSentencesForATrackThatCannotBePlayedHaveTheirGerman_data() {
        QTest::addColumn<QString>("sentence");
        const char *const sentences[] = {
            "This track is not available for your account or region.",
            "“%1” is not available for your account or region and was skipped.",
            "Several tracks are not available for your account or region and were skipped.",
            "Several tracks are not available and were skipped.",
            "Several tracks in a row are no longer available on Tidal, so playback stopped here.",
            "Several tracks in a row are not available for your account or region, "
                "so playback stopped here.",
            "Several tracks in a row are not available, so playback stopped here.",
        };
        for (const char *s : sentences) QTest::newRow(s) << QString::fromUtf8(s);
    }

    void theSentencesForATrackThatCannotBePlayedHaveTheirGerman() {
        QFETCH(QString, sentence);
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        QVERIFY(i18n.isCatalogueLoaded());
        QVERIFY(QCoreApplication::translate("Player", sentence.toUtf8().constData()) != sentence);
    }

    // ── a seek to the end ───────────────────────────────────────────────────

    void aSeekToTheEndIsTheEndOfTheTrack_data() {
        QTest::addColumn<qint64>("beyond");
        QTest::addColumn<bool>("paused");
        QTest::addColumn<bool>("last");
        QTest::newRow("at the end")        << qint64(0)     << false << false;
        QTest::newRow("past the end")      << qint64(15000) << false << false;
        QTest::newRow("while paused")      << qint64(0)     << true  << false;
        QTest::newRow("on the last track") << qint64(0)     << false << true;
    }

    // The forward shortcut, the right edge of the seek bar and MPRIS all ask
    // for the length of the track or more.
    void aSeekToTheEndIsTheEndOfTheTrack() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(qint64, beyond);
        QFETCH(bool, paused);
        QFETCH(bool, last);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(8000, last ? 1 : 3), 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started() && a.p().duration() > 0, 10000);
        if (paused) {
            a.p().playPause();
            QTRY_COMPARE_WITH_TIMEOUT(a.mp()->playbackState(), QMediaPlayer::PausedState, 5000);
        }

        a.p().seek(a.p().duration() + beyond);
        if (last) {
            // As when it has played out: stopped, and back at its start.
            QTRY_VERIFY2_WITH_TIMEOUT(!a.p().playing(), "the end never came", 8000);
            QCOMPARE(a.mp()->playbackState(), QMediaPlayer::StoppedState);
            QCOMPARE(a.p().position(), qint64(0));
            QCOMPARE(currentId(a.p()), 8000);
            return;
        }
        QTRY_VERIFY2_WITH_TIMEOUT(currentId(a.p()) == 8001, "the end never came", 8000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001}));
        QVERIFY(a.client.answer(8001, track));
        if (paused) {
            // A paused player moves on and waits there.
            QTRY_VERIFY_WITH_TIMEOUT(!a.p().loading() && a.loaded(), 10000);
            QTest::qWait(300);
            QVERIFY2(!a.started() && !a.p().playing(), "the track after a paused one played");
        } else {
            QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the track after it never played", 10000);
        }
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
