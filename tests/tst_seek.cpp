// Seeking inside a lossless track, through the app's own Player. The fixture is
// FLAC in DASH segments, and DashFetcher joins them as it does for the app. The
// Player's output is muted before it opens, so nothing here is audible.

#include <QTest>
#include <QByteArray>
#include <QFile>
#include <QHostAddress>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QUrl>
#include <QVector>
#include <QtEndian>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/DashFetcher.h"
#include "player/Player.h"

// The fixture's timeline, with segment n at @BASE@n and the initialization
// segment at @BASE@0.
constexpr auto kSeekManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
<MPD type="static" mediaPresentationDuration="PT4.0S">
  <Period id="0">
    <AdaptationSet id="0" contentType="audio">
      <Representation id="0" mimeType="audio/mp4" codecs="flac" audioSamplingRate="16000">
        <SegmentTemplate timescale="16000" startNumber="1"
                         initialization="@BASE@0" media="@BASE@$Number$">
          <SegmentTimeline>
            <S t="0" d="8064" r="6"/>
            <S d="8192"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

namespace {

#include "progressive_fixture.inc"

QByteArray be32(quint32 v) { QByteArray b(4, '\0'); qToBigEndian(v, b.data()); return b; }

QByteArray box(const QByteArray &type, const QByteArray &body)
{
    return be32(quint32(body.size() + 8)) + type + body;
}

// A run of the fixture's boxes as Tidal packages a track: no edit list, the
// whole duration in an mehd box, and media segments of a bare moof and mdat.
QByteArray inTidalsLayout(const QByteArray &boxes)
{
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
            out += box(type, box("mehd", be32(0) + be32(quint32(kProgDurationMs))) + body);
        else
            out += box(type, body);
    }
    return out;
}

// Answers GET /n on loopback with the nth of its segments.
class SegmentServer : public QTcpServer {
public:
    explicit SegmentServer(const QVector<QByteArray> &segments) : m_segments(segments)
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock] { answer(sock); });
            }
        });
    }

private:
    void answer(QTcpSocket *sock)
    {
        if (!sock->canReadLine()) return;
        // The request line is all that is read; one answer per connection.
        QObject::disconnect(sock, &QTcpSocket::readyRead, nullptr, nullptr);
        const QList<QByteArray> request = sock->readLine().split(' ');
        bool ok = false;
        const int n = request.value(1).mid(1).toInt(&ok);
        if (!ok || n < 0 || n >= m_segments.size()) {
            sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        } else {
            sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                        + QByteArray::number(m_segments.at(n).size()) + "\r\n\r\n"
                        + m_segments.at(n));
        }
        sock->disconnectFromHost();
    }

    QVector<QByteArray> m_segments;
};

// What one Player's QMediaPlayer did, as the test needs to ask about it.
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
    // The Player stops at the end of an empty queue, which resets the position.
    qint64 furthest = 0;
    bool   ended    = false;
};

} // namespace

class TestSeek : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_seek"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        QVector<QByteArray> packaged, tidal;
        for (int i = 0; i < kProgSegmentCount; ++i) {
            packaged.append(QByteArray::fromBase64(QByteArray(kProgSegmentsB64[i])));
            tidal.append(inTidalsLayout(packaged.last()));
        }
        QVERIFY(tidal.at(1).mid(4, 4) == "moof");
        m_packaged = joined(packaged);
        QVERIFY(!m_packaged.isEmpty());
        m_tidal = joined(tidal);
        QVERIFY(!m_tidal.isEmpty());
    }

    void cleanupTestCase()
    {
        for (const QString &track : { m_packaged, m_tidal })
            if (!track.isEmpty()) QFile::remove(track);
    }

    void aSeekWhilePlayingPlaysOnToTheEndOfTheTrack_data() { layouts(); }

    // Twice, because the second seek is the one made after a seek.
    void aSeekWhilePlayingPlaysOnToTheEndOfTheTrack()
    {
        QFETCH(QString, track);
        if (const char *why = obstacle(track)) QSKIP(why);
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QMediaPlayer *mp = startPlaying(player, track);
        QVERIFY(mp);
        Watch watch(mp);

        // Long enough for a backend to have read all of so small a file.
        QTRY_VERIFY_WITH_TIMEOUT(mp->position() >= 500, 10000);

        QSignalSpy told(&player, &Player::playingChanged);
        player.seek(2000);
        QCOMPARE(told.count(), 0);
        QCOMPARE(mp->playbackState(), QMediaPlayer::PlayingState);
        QTRY_VERIFY2_WITH_TIMEOUT(watch.furthest >= 2500,
                                  "the position stayed where the seek put it", 5000);

        watch.furthest = 0;
        player.seek(1000);
        QCOMPARE(told.count(), 0);
        QTRY_VERIFY2_WITH_TIMEOUT(watch.furthest >= 1500,
                                  "the position stayed where the second seek put it", 5000);

        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
        QVERIFY2(watch.furthest >= kProgDurationMs - 500,
                 qPrintable(QStringLiteral("the track ended at %1 ms").arg(watch.furthest)));
    }

    void aSeekWhilePausedStaysPaused_data() { layouts(); }

    void aSeekWhilePausedStaysPaused()
    {
        QFETCH(QString, track);
        if (const char *why = obstacle(track)) QSKIP(why);
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QMediaPlayer *mp = startPlaying(player, track);
        QVERIFY(mp);
        Watch watch(mp);

        QTRY_VERIFY_WITH_TIMEOUT(mp->position() >= 300, 10000);
        mp->pause();
        QTRY_COMPARE_WITH_TIMEOUT(mp->playbackState(), QMediaPlayer::PausedState, 5000);

        player.seek(2000);
        QTest::qWait(400);
        QCOMPARE(mp->playbackState(), QMediaPlayer::PausedState);
        QVERIFY2(mp->position() < 2300,
                 qPrintable(QStringLiteral("paused, and yet at %1 ms").arg(mp->position())));

        mp->play();
        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
    }

    void theEndOfTheLastTrackIsReportedOnce_data() { layouts(); }

    // No seek here: the track plays from its start to its end, and the queue
    // has nothing after it.
    void theEndOfTheLastTrackIsReportedOnce()
    {
        QFETCH(QString, track);
        if (const char *why = obstacle(track)) QSKIP(why);
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QMediaPlayer *mp = startPlaying(player, track);
        QVERIFY(mp);

        // Counted from the first report of the end on.
        int ends = 0, positions = 0;
        connect(mp, &QMediaPlayer::mediaStatusChanged, &player,
                [&ends](QMediaPlayer::MediaStatus s) {
            if (s == QMediaPlayer::EndOfMedia) ++ends;
        });
        connect(&player, &Player::positionChanged, &player, [&ends, &positions] {
            if (ends > 0) ++positions;
        });
        QTRY_VERIFY2_WITH_TIMEOUT(ends > 0, "the track never reached its end", 15000);
        QSignalSpy plays(&player, &Player::playingChanged);
        QTest::qWait(1500);

        QCOMPARE(ends, 1);
        // The position goes back to the start, once.
        QVERIFY2(positions <= 1,
                 qPrintable(QStringLiteral("the position was told %1 times").arg(positions)));
        QCOMPARE(plays.count(), 0);
        QCOMPARE(mp->playbackState(), QMediaPlayer::StoppedState);
        QVERIFY(!player.playing());
        QCOMPARE(player.position(), 0);

        // A press on play starts the track over.
        player.playPause();
        QTRY_VERIFY2_WITH_TIMEOUT(mp->position() >= 300 && mp->position() < 2000,
                                  "the track did not start over", 10000);
        QVERIFY(player.playing());
    }

private:
    // Why this Qt on this machine cannot run these tests on a track, or null.
    const char *obstacle(const QString &track) const
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // With no audio device one backend crashes in play() and the other
        // runs through the track unpaced.
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
        // ffmpeg's packager writes no mehd box, so its file states no duration.
        if (track == m_packaged && qgetenv("QT_MEDIA_BACKEND") != "ffmpeg")
            return "Qt 6.4's GStreamer backend cannot seek in fragments that state no duration";
#else
        Q_UNUSED(track)
#endif
        return nullptr;
    }

    // The same track in the two layouts a joined file comes in.
    void layouts()
    {
        QTest::addColumn<QString>("track");
        QTest::newRow("as ffmpeg packages it") << m_packaged;
        QTest::newRow("as Tidal packages it")  << m_tidal;
    }

    // Serves the segments and has DashFetcher join them, as the app does for
    // a lossless track. Returns the joined file, or nothing when that failed.
    static QString joined(const QVector<QByteArray> &segments)
    {
        SegmentServer srv(segments);
        if (!srv.listen(QHostAddress::LocalHost)) return {};
        QString mpd = QString::fromUtf8(kSeekManifest);
        mpd.replace(QStringLiteral("@BASE@"),
                    QStringLiteral("http://127.0.0.1:%1/").arg(srv.serverPort()));

        TidalApi    api;
        TidalClient client{&api};
        DashFetcher fetcher(&client, mpd);
        if (fetcher.partCount() != segments.size() || !fetcher.openedTempFile()) return {};
        bool    done = false;
        QString path;
        fetcher.start([&](QTemporaryFile *file, const QString &) {
            done = true;
            if (!file) return;
            path = file->fileName();
            delete file;
        });
        return QTest::qWaitFor([&done] { return done; }, 20000) ? path : QString();
    }

    // Loads a track into the Player's own QMediaPlayer and starts it.
    QMediaPlayer *startPlaying(Player &player, const QString &track)
    {
        player.setMuted(true);
        player.setVolume(0.0);
        // The Player builds its audio objects on the first turn of the loop.
        QTest::qWait(30);
        auto *mp = player.findChild<QMediaPlayer *>();
        if (!mp) return nullptr;
        mp->setSource(QUrl::fromLocalFile(track));
        mp->play();
        return mp;
    }

    QTemporaryDir m_dir;
    QString       m_packaged;
    QString       m_tidal;
};

QTEST_MAIN(TestSeek)
#include "tst_seek.moc"
