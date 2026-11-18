// A lossless track that was not preloaded starts from the front of its join
// instead of waiting for all of it. The segments come from a loopback "link"
// that delivers them at a steady rate, the Player is muted, and nothing
// reaches the network. Each test after the first pins one of the places
// where a stream that is still growing differs from a finished file.

#include <QTest>
#include <QElapsedTimer>
#include <QHostAddress>
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
#include <QPointer>
#include <QtEndian>
#include <algorithm>
#include <functional>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#ifdef Q_OS_LINUX
#include "cast/CastSession.h"
#endif
#include "player/GrowingFileServer.h"
#include "player/Player.h"

namespace {

#include "progressive_fixture.inc"

constexpr qint64 kUser = 4242;

// The fixture's eight half-second segments twice over: eight seconds, so
// that a preload, which waits for five seconds of play, can start.
constexpr int    kMediaSegments = 2 * (kProgSegmentCount - 1);
constexpr qint64 kLengthMs      = 2 * kProgDurationMs;

// Segment n of a lane is at @BASE@<lane>/<n>, the initialization segment at 0.
constexpr auto kManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
<MPD type="static" mediaPresentationDuration="PT8.0S">
  <Period id="0">
    <AdaptationSet id="0" contentType="audio">
      <Representation id="0" mimeType="audio/mp4" codecs="flac" audioSamplingRate="16000">
        <SegmentTemplate timescale="16000" startNumber="1"
                         initialization="@BASE@0" media="@BASE@$Number$">
          <SegmentTimeline>
            <S t="0" d="8064" r="6"/>
            <S d="8192"/>
            <S t="64000" d="8064" r="6"/>
            <S d="8192"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

QByteArray fixtureSegment(int i) {
    return QByteArray::fromBase64(QByteArray(kProgSegmentsB64[i]));
}

// A media segment moved later by `ticks` and renumbered by `seq`: tfdt and
// mfhd are the only boxes that say where a fragment sits.
QByteArray shifted(const QByteArray &boxes, quint64 ticks, quint32 seq) {
    QByteArray out = boxes;
    const std::function<void(qint64, qint64)> walk = [&](qint64 from, qint64 to) {
        for (qint64 pos = from; pos + 8 <= to; ) {
            const qint64 size = qFromBigEndian<quint32>(out.constData() + pos);
            if (size < 8 || pos + size > to) return;
            const QByteArray type = out.mid(pos + 4, 4);
            char *body = out.data() + pos + 8;
            if (type == "moof" || type == "traf") {
                walk(pos + 8, pos + size);
            } else if (type == "mfhd") {
                qToBigEndian(qFromBigEndian<quint32>(body + 4) + seq, body + 4);
            } else if (type == "tfdt") {
                if (body[0] == 1)
                    qToBigEndian(qFromBigEndian<quint64>(body + 4) + ticks, body + 4);
                else
                    qToBigEndian(quint32(qFromBigEndian<quint32>(body + 4) + ticks), body + 4);
            }
            pos += size;
        }
    };
    walk(0, out.size());
    return out;
}

QByteArray be32(quint32 v) { QByteArray b(4, '\0'); qToBigEndian(v, b.data()); return b; }

QByteArray box(const QByteArray &type, const QByteArray &body) {
    return be32(quint32(body.size() + 8)) + type + body;
}

// As Tidal packages a track: no styp, sidx, edit list or udta, and the whole
// length in an mehd box. A sidx would place the second run over the first.
QByteArray inTidalsLayout(const QByteArray &boxes) {
    QByteArray out;
    for (qint64 pos = 0; pos + 8 <= boxes.size(); ) {
        const qint64 size = qFromBigEndian<quint32>(boxes.constData() + pos);
        if (size < 8) break;
        const QByteArray type = boxes.mid(pos + 4, 4);
        const QByteArray body = boxes.mid(pos + 8, size - 8);
        pos += size;
        if (type == "styp" || type == "sidx" || type == "edts" || type == "udta") continue;
        if (type == "moov" || type == "trak")
            out += box(type, inTidalsLayout(body));
        else if (type == "mvex")
            out += box(type, box("mehd", be32(0) + be32(quint32(kLengthMs))) + body);
        else
            out += box(type, body);
    }
    return out;
}

QVector<QByteArray> eightSeconds() {
    QVector<QByteArray> s{ inTidalsLayout(fixtureSegment(0)) };
    for (int i = 1; i < kProgSegmentCount; ++i) s.append(inTidalsLayout(fixtureSegment(i)));
    for (int i = 1; i < kProgSegmentCount; ++i)
        s.append(shifted(inTidalsLayout(fixtureSegment(i)), quint64(kProgFrames),
                         quint32(kProgSegmentCount - 1)));
    return s;
}

// One clock for the link and the player, so a stall of the whole process
// moves both sides of a comparison alike.
qint64 now() { QElapsedTimer t; t.start(); return t.msecsSinceReference(); }

// The link. Lane "f" answers at once. Lane "s" delivers segment n at
// (n + 1) * paceMs after its initialization segment was asked for, a steady
// rate; segments from stallAt on wait until release().
class Link : public QTcpServer {
public:
    QVector<QByteArray> segments = eightSeconds();
    int paceMs  = 450;
    int stallAt = -1;

    Link() {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock] { take(sock); });
            }
        });
    }

    QString manifest(const QString &lane) const {
        QString mpd = QString::fromUtf8(kManifest);
        mpd.replace(QStringLiteral("@BASE@"),
                    QStringLiteral("http://127.0.0.1:%1/%2/").arg(serverPort()).arg(lane));
        return mpd;
    }

    // When each segment of the last track went out, on now()'s clock.
    QVector<qint64> sentAt;

    void release() {
        stallAt = -1;
        const auto held = std::exchange(m_stalled, {});
        for (const auto &h : held) if (h.first) answer(h.first, h.second);
    }

private:
    void take(QTcpSocket *sock) {
        if (!sock->canReadLine()) return;
        QObject::disconnect(sock, &QTcpSocket::readyRead, nullptr, nullptr);
        const QList<QByteArray> path = sock->readLine().split(' ').value(1).split('/');
        const QByteArray lane = path.value(1);
        bool ok = false;
        const int n = path.value(2).toInt(&ok);
        if (!ok || n < 0 || n >= segments.size()) { answer(sock, -1); return; }
        if (lane != "s") { answer(sock, n); return; }
        if (n == 0) m_laneStart.start();
        if (stallAt >= 0 && n >= stallAt) { m_stalled.append({ sock, n }); return; }
        const qint64 due = qint64(n + 1) * paceMs - m_laneStart.elapsed();
        QPointer<QTcpSocket> guard(sock);
        QTimer::singleShot(int(qMax<qint64>(0, due)), this, [this, guard, n] {
            if (guard) answer(guard, n);
        });
    }

    void answer(QTcpSocket *sock, int n) {
        if (n == 0) sentAt.fill(-1, segments.size());
        if (n >= 0 && n < sentAt.size()) sentAt[n] = now();
        if (n < 0) {
            sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        } else {
            sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                        + QByteArray::number(segments.at(n).size()) + "\r\n\r\n" + segments.at(n));
        }
        sock->disconnectFromHost();
    }

    QElapsedTimer m_laneStart;
    QList<std::pair<QPointer<QTcpSocket>, int>> m_stalled;
};

// Answers each stream request a turn later with the lane the test gave the
// track, and counts what was asked for.
class LinkClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    Link *link = nullptr;
    QHash<qlonglong, QString> laneOf;
    QList<qlonglong> asked;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override {
        asked.append(trackId);
        QTimer::singleShot(0, this, [this, trackId, cb = std::move(cb)] {
            StreamManifest m;
            m.type     = StreamManifest::MPD;
            m.url      = link->manifest(laneOf.value(trackId, QStringLiteral("s")));
            m.mimeType = QStringLiteral("application/dash+xml");
            m.codec    = QStringLiteral("LOSSLESS");
            cb(m, QString());
        });
    }
};

QVariantList rowsOf(int n) {
    QVariantList out;
    for (qlonglong id = 1; id <= n; ++id) {
        QVariantMap t;
        t[QStringLiteral("id")]       = id;
        t[QStringLiteral("title")]    = QStringLiteral("T%1").arg(id);
        t[QStringLiteral("artists")]  = QStringLiteral("Artist");
        // Whole seconds, and on purpose not the manifest's eight.
        t[QStringLiteral("duration")] = 9;
        out.append(t);
    }
    return out;
}

// One Player, muted, on the link.
struct Rig {
    TidalApi                api;
    LinkClient              client{&api};
    std::unique_ptr<Player> player;
    QElapsedTimer           clock;
    qint64                  firstSoundMs = -1;   // the backend's position first moved
    qint64                  firstSoundAt = -1;   // the same, on now()'s clock
    qint64                  joinedMs     = -1;   // the whole file was on disk
    bool                    everLoading  = false;
    bool                    everStopped  = false;

    explicit Rig(Link *link, bool signedIn = false) {
        client.link = link;
        if (signedIn) client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
    }

    Player &p() { return *player; }
    QMediaPlayer *mp() { return player->findChild<QMediaPlayer *>(); }
    GrowingFileServer *server() { return player->findChild<GrowingFileServer *>(); }
    bool plays() { return mp() && mp()->playbackState() == QMediaPlayer::PlayingState; }
    bool onStream() { return mp() && mp()->source().scheme() == QLatin1String("http"); }
    bool onFile() { return mp() && mp()->source().isLocalFile(); }
    qlonglong currentId() { return p().currentTrackMap().value(QStringLiteral("id")).toLongLong(); }

    bool audioUp() {
        if (!QTest::qWaitFor([this] { return mp() != nullptr; }, 10000)) return false;
        QObject::connect(mp(), &QMediaPlayer::positionChanged, mp(), [this](qint64 pos) {
            if (pos > 0 && firstSoundMs < 0) { firstSoundMs = clock.elapsed(); firstSoundAt = now(); }
        });
        QObject::connect(player.get(), &Player::audioFileReady, mp(), [this](qlonglong, bool ahead) {
            if (!ahead && joinedMs < 0) joinedMs = clock.elapsed();
        });
        return true;
    }

    void start(int rows = 1) {
        clock.start();
        firstSoundMs = firstSoundAt = joinedMs = -1;
        p().playTracks(rowsOf(rows), 0);
    }

    // From here on, a raised loading flag or a moment not playing is news.
    void watchForLoads() {
        everLoading = everStopped = false;
        QObject::connect(player.get(), &Player::loadingChanged, mp(),
                         [this](bool on) { if (on) everLoading = true; });
        QObject::connect(player.get(), &Player::playingChanged, mp(),
                         [this](bool on) { if (!on) everStopped = true; });
    }
};

} // namespace

class TestStreamStart : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_stream_start"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QVERIFY(m_link.listen(QHostAddress::LocalHost));
    }

    void init() {
        QSettings().clear();
        m_link.paceMs  = 450;
        m_link.stallAt = -1;
    }

    // The headline: sound comes out after about the first two segments, not
    // after all seventeen.
    void aLosslessTrackSoundsBeforeItsJoinHasLanded() {
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QVERIFY2(QTest::qWaitFor([&r] { return r.firstSoundMs >= 0 && r.joinedMs >= 0; }, 20000),
                 qPrintable(QStringLiteral("first sound %1 ms, join %2 ms")
                                .arg(r.firstSoundMs).arg(r.joinedMs)));
        qInfo("time to first sound %lld ms; the join landed at %lld ms",
              r.firstSoundMs, r.joinedMs);
        // Counted in segments, which a stall of the process delays as well:
        // sound before the eighth of seventeen went out.
        const int k = 8;
        QVERIFY(m_link.sentAt.size() > k && m_link.sentAt.at(k) > 0);
        QVERIFY2(r.firstSoundAt < m_link.sentAt.at(k),
                 qPrintable(QStringLiteral("first sound %1 ms after segment %2 went out")
                                .arg(r.firstSoundAt - m_link.sentAt.at(k)).arg(k)));
        // And it plays on to the end of the track.
        QTRY_VERIFY_WITH_TIMEOUT(r.mp()->mediaStatus() == QMediaPlayer::EndOfMedia
                                 || r.p().stopped(), 15000);
    }

    // Site 4: the backend says one segment long; the bar, MPRIS and a cast
    // device are told the track's own length.
    void aGrowingStreamHasTheTracksLength() {
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        QSignalSpy lengths(&r.p(), &Player::durationChanged);
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.onStream(), 10000);
        QVERIFY(r.joinedMs < 0);
        QCOMPARE(r.p().duration(), kLengthMs);
        QVERIFY(!lengths.isEmpty());
        QCOMPARE(lengths.constLast().at(0).toLongLong(), kLengthMs);
        // Told the length, the backend's position runs on past one segment.
        QTRY_VERIFY_WITH_TIMEOUT(r.mp()->position() >= 1500, 5000);
        QVERIFY(r.joinedMs < 0);
        QCOMPARE(r.mp()->duration(), kLengthMs);
    }

    // Sites 1 and 2 for a restore: a position held from the last session
    // needs bytes from further in, so that load waits for the whole file
    // and starts there, never at the front of the stream.
    void aRestoredPositionWaitsForTheWholeFile() {
        if (const char *why = obstacle()) QSKIP(why);
        {
            Rig a(&m_link, true);
            QVERIFY(a.audioUp());
            a.start();
            a.p().seek(3000);
            a.p().savePlaybackState();
        }
        Rig r(&m_link, true);
        QVERIFY(r.audioUp());
        QCOMPARE(r.p().position(), qint64(3000));
        r.clock.start();
        r.p().playPause();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && !r.p().loading(), 20000);
        QVERIFY2(r.onFile(), qPrintable(r.mp()->source().toString()));
        QVERIFY(r.joinedMs >= 0);
        QVERIFY2(r.mp()->position() >= 3000 && r.mp()->position() < kLengthMs,
                 qPrintable(QString::number(r.mp()->position())));
    }

    // Site 2: a seek while the stream grows is held, not swallowed, and the
    // track goes on from there once the file is whole.
    void aSeekDuringTheJoinPlaysFromThereOnceItLands() {
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.onStream(), 10000);
        QVERIFY(r.joinedMs < 0);

        r.p().seek(6000);
        QCOMPARE(r.p().position(), qint64(6000));
        QVERIFY2(r.p().playing(), "a seek while playing is no pause");
        QVERIFY2(!r.onStream(), "the stream was asked to seek");
        QTRY_VERIFY_WITH_TIMEOUT(r.joinedMs >= 0, 20000);
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= 6000, 5000);
        QVERIFY(r.onFile());
        QVERIFY(r.mp()->position() < kLengthMs);
    }

    // The policy for a seek past what has arrived: it waits, and gives up
    // with a sentence when the bytes do not come.
    void aSeekThatTheLinkNeverServesGivesUp() {
        if (const char *why = streamObstacle()) QSKIP(why);
        m_link.stallAt = 6;
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.p().setSeekWait(1500);
        QSignalSpy errors(&r.p(), &Player::error);
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.onStream(), 10000);
        r.p().seek(6000);
        QVERIFY(r.p().loading());
        QTRY_VERIFY_WITH_TIMEOUT(!errors.isEmpty(), 5000);
        QVERIFY(!r.p().loading());
        QVERIFY(!r.p().playing());
        QCOMPARE(r.currentId(), 1);
        m_link.release();
    }

    // A seek once the whole file is on disk is a seek: no load, no pause.
    void aSeekAfterTheJoinLandedIsNoLoad() {
        if (const char *why = streamObstacle()) QSKIP(why);
        m_link.paceMs = 60;
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.joinedMs >= 0, 10000);
        QVERIFY(r.onStream());
        r.watchForLoads();
        r.p().seek(5000);
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= 5200, 5000);
        QVERIFY(r.onFile());
        QVERIFY2(!r.everLoading, "the swap to the file showed as a load");
        QVERIFY2(!r.everStopped, "the swap to the file showed as a pause");
    }

    // A pause in the same turn as a seek that swaps to the file holds, as it
    // does for a seek in a file.
    void aPauseDuringTheSwapToTheFileHolds() {
        if (const char *why = streamObstacle()) QSKIP(why);
        m_link.paceMs = 60;
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.joinedMs >= 0, 10000);
        QVERIFY(r.onStream());
        r.p().seek(4000);
        r.p().playPause();
        QTest::qWait(1000);
        QVERIFY(r.onFile());
        QVERIFY(!r.p().playing());
        QCOMPARE(r.mp()->playbackState(), QMediaPlayer::PausedState);
        QVERIFY2(qAbs(r.mp()->position() - 4000) < 200, qPrintable(QString::number(r.mp()->position())));
        r.p().playPause();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= 4300, 5000);
    }

    // Site 3: the backend calls the stream seekable. A device swap that
    // finds the position elsewhere must not seek it.
    void aDeviceSwapDoesNotSeekTheStream() {
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= 300, 10000);
        QVERIFY(r.onStream() && r.joinedMs < 0);
        QVERIFY(r.mp()->isSeekable());   // what Qt claims

        Player::AudioState s = r.p().captureAudioState();
        s.position = 3500;
        r.p().restoreAudioState(s);
        QTest::qWait(200);
        QVERIFY(r.onStream());
        QVERIFY2(r.mp()->position() < 3000,
                 qPrintable(QStringLiteral("the stream was moved to %1 ms").arg(r.mp()->position())));
        QTRY_VERIFY_WITH_TIMEOUT(r.joinedMs >= 0, 20000);
    }

    // Site 5: no preload of the next track while this one's join still
    // has the link. Its last segment is held, so it sounds past five
    // seconds, where a preload starts, before it lands.
    void noPreloadWhileTheCurrentJoinRuns() {
        if (const char *why = streamObstacle()) QSKIP(why);
        m_link.stallAt = kMediaSegments;
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start(2);
        QTRY_VERIFY_WITH_TIMEOUT(r.mp()->position() >= 5300, 20000);
        QVERIFY(r.joinedMs < 0);
        QCOMPARE(r.client.asked, (QList<qlonglong>{ 1 }));
        // Once it has landed, the preload goes ahead.
        m_link.release();
        QTRY_VERIFY_WITH_TIMEOUT(r.client.asked.contains(2), 10000);
    }

    // Site 6: a stream that ends before its join landed did not reach the
    // end of the track. The queue stays, and it goes on from there.
    void aStreamCutShortDoesNotEndTheTrack() {
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start(2);
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= 400, 10000);
        QVERIFY(r.joinedMs < 0);
        // The loopback socket goes away under the backend.
        r.server()->stop();
        QTRY_VERIFY_WITH_TIMEOUT(!r.onStream(), 5000);
        QCOMPARE(r.currentId(), 1);
        // Where it got to, not the end the backend reports for a cut stream.
        const qint64 heldAt = r.p().position();
        QVERIFY2(heldAt >= 400 && heldAt < kLengthMs / 2, qPrintable(QString::number(heldAt)));
        QTRY_VERIFY_WITH_TIMEOUT(r.joinedMs >= 0, 20000);
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() >= heldAt, 5000);
        QCOMPARE(r.currentId(), 1);
        QVERIFY(r.onFile());
        QVERIFY(r.mp()->position() < kLengthMs - 1000);
    }

    // Site 7: handing the track to a cast device mid-join lets the stream
    // go, and the join lands for the device.
    void castingMidJoinTearsTheServerDown() {
#ifdef Q_OS_LINUX
        if (const char *why = streamObstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.onStream(), 10000);
        QVERIFY(r.joinedMs < 0);
        QVERIFY(r.server()->isListening());

        QSignalSpy recast(&r.p(), &Player::castTrackChanged);
        CastSession device;
        r.p().beginCast(&device);
        QVERIFY(!r.server()->isListening());
        QVERIFY(r.mp()->source().isEmpty());
        QCOMPARE(r.p().duration(), kLengthMs);
        QTRY_VERIFY_WITH_TIMEOUT(!recast.isEmpty(), 20000);
        QVERIFY(!r.plays());
        r.p().endCast();
#else
        QSKIP("casting is built on Linux only");
#endif
    }

    // Site 8: a preload that has landed plays from its file as before, and
    // a step onto a track whose preload is still joining plays from the
    // front of that join, with no second request for it.
    void thePreloadPathStreamsAJoinStillUnderWay() {
        if (const char *why = streamObstacle()) QSKIP(why);
        m_link.paceMs = 480;
        Rig r(&m_link);
        r.client.laneOf.insert(1, QStringLiteral("f"));
        QVERIFY(r.audioUp());
        r.start(3);
        QTRY_VERIFY_WITH_TIMEOUT(r.client.asked.contains(2), 15000);
        // Its join is under way on the slow lane.
        QTest::qWait(3 * m_link.paceMs);
        r.p().next();
        QTRY_VERIFY_WITH_TIMEOUT(r.currentId() == 2 && r.plays() && r.onStream(), 10000);
        QCOMPARE(r.client.asked.count(2), 1);
        QCOMPARE(r.p().duration(), kLengthMs);
    }

    void aLandedPreloadPlaysFromItsFile() {
        if (const char *why = obstacle()) QSKIP(why);
        Rig r(&m_link);
        r.client.laneOf.insert(1, QStringLiteral("f"));
        r.client.laneOf.insert(2, QStringLiteral("f"));
        QVERIFY(r.audioUp());
        QSignalSpy ready(&r.p(), &Player::audioFileReady);
        r.start(2);
        QTRY_VERIFY_WITH_TIMEOUT(
            std::any_of(ready.cbegin(), ready.cend(),
                        [](const QList<QVariant> &a) { return a.at(1).toBool(); }), 15000);
        r.p().next();
        QTRY_VERIFY_WITH_TIMEOUT(r.currentId() == 2 && r.plays(), 10000);
        QVERIFY(r.onFile());
        QCOMPARE(r.client.asked.count(2), 1);
    }

    // Where the Player does not stream a join, the track waits for all of it.
    void aTrackPlaysFromItsFileWhereNoJoinIsStreamed() {
        if (Player::kStreamsJoins) QSKIP("this Qt streams a join; the cases above cover it");
        if (const char *why = obstacle()) QSKIP(why);
        Rig r(&m_link);
        QVERIFY(r.audioUp());
        r.start();
        QTRY_VERIFY_WITH_TIMEOUT(r.plays() && r.mp()->position() > 0, 20000);
        QVERIFY2(r.onFile(), qPrintable(r.mp()->source().toString()));
        QVERIFY(r.joinedMs >= 0 && r.joinedMs <= r.firstSoundMs);
        QVERIFY(!r.server());
    }

private:
    // The cases that need a join streamed, which Player::kStreamsJoins gates.
    static const char *streamObstacle() {
        if (!Player::kStreamsJoins)
            return "below Qt 6.6 the Player does not stream a join (Player::kStreamsJoins)";
        return obstacle();
    }

    static const char *obstacle() {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
#endif
        return nullptr;
    }

    QTemporaryDir m_dir;
    Link          m_link;
};

QTEST_MAIN(TestStreamStart)
#include "tst_stream_start.moc"
