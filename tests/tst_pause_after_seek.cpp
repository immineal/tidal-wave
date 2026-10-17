// The loading flag of a track that has started: a seek and a pause inside it
// are no load, in any order. The Player and its MPRIS service run on a private
// bus. The track is FLAC in DASH segments from a localhost server, and muted.

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QHostAddress>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QMetaEnum>
#include <QProcess>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QtEndian>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "mpris/MprisPlayer.h"
#include "player/Player.h"

// The fixture's timeline, with segment n at @BASE@n and the initialization
// segment at @BASE@0.
constexpr auto kManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
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

QString g_busAddress;

constexpr qint64 kUser     = 4242;
constexpr qint64 kSeekTo   = 1500;
constexpr qint64 kSavedAt  = 1000;
// Long enough for a report the backend queued on another thread to arrive.
constexpr int    kSettleMs = 300;

const QString kPath    = QStringLiteral("/org/mpris/MediaPlayer2");
const QString kPlayer  = QStringLiteral("org.mpris.MediaPlayer2.Player");
const QString kProps   = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kService = QStringLiteral("org.mpris.MediaPlayer2.tidalwave");

QVariantList rowsOf(int n) {
    QVariantList out;
    for (qlonglong id = 1; id <= n; ++id) {
        QVariantMap t;
        t[QStringLiteral("id")]         = id;
        t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
        t[QStringLiteral("artists")]    = QStringLiteral("Artist");
        t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
        t[QStringLiteral("albumId")]    = qlonglong(7);
        t[QStringLiteral("duration")]   = int(kProgDurationMs / 1000);
        out.append(t);
    }
    return out;
}

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
    QVector<QByteArray> segments;

    SegmentServer()
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
        if (!ok || n < 0 || n >= segments.size()) {
            sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        } else {
            sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                        + QByteArray::number(segments.at(n).size()) + "\r\n\r\n"
                        + segments.at(n));
        }
        sock->disconnectFromHost();
    }
};

// Holds each stream request until the test answers it.
class HeldClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override
    {
        m_held.append({ trackId, std::move(cb) });
    }

    bool answer(qlonglong trackId, const StreamManifest &manifest)
    {
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

// What the Player and its backend said, in order, for a failure to quote.
struct Heard {
    QStringList   said;
    QElapsedTimer clock;
    // Times the loading flag went up since the test last set this to zero.
    int           rises = 0;
    // Zeroes the count once more, when the backend has the track.
    bool          countFromLoaded = false;
    // Reports of buffering that the flag did not show.
    int           bufferingNotShown = 0;
    bool          ended = false;

    void listenTo(Player *p, QMediaPlayer *mp)
    {
        clock.start();
        QObject::connect(p, &Player::loadingChanged, mp, [this](bool on) {
            if (on) ++rises;
            note(on ? QStringLiteral("loading") : QStringLiteral("loaded"));
        });
        QObject::connect(p, &Player::playingChanged, mp, [this](bool on) {
            note(on ? QStringLiteral("plays") : QStringLiteral("plays not"));
        });
        QObject::connect(mp, &QMediaPlayer::playbackStateChanged, mp,
                         [this](QMediaPlayer::PlaybackState s) {
            note(QString::fromLatin1(
                QMetaEnum::fromType<QMediaPlayer::PlaybackState>().valueToKey(s)));
        });
        // The Player's own slot was connected first and has run by now.
        QObject::connect(mp, &QMediaPlayer::mediaStatusChanged, mp,
                         [this, p](QMediaPlayer::MediaStatus s) {
            note(QString::fromLatin1(
                QMetaEnum::fromType<QMediaPlayer::MediaStatus>().valueToKey(s)));
            if (s == QMediaPlayer::EndOfMedia) ended = true;
            if (s == QMediaPlayer::BufferingMedia && !p->loading()) ++bufferingNotShown;
            if (s == QMediaPlayer::LoadedMedia && countFromLoaded) {
                countFromLoaded = false;
                rises = 0;
            }
        });
    }

    void note(const QString &what)
    {
        said.append(QStringLiteral("%1 %2").arg(clock.elapsed()).arg(what));
    }

    QByteArray after(const char *claim) const
    {
        return QByteArray(claim) + ", after: " + said.join(QStringLiteral(", ")).toUtf8();
    }
};

// One launch of the app with its MPRIS service. With the account set first,
// the Player restores from its constructor as it does at startup.
struct Launch {
    TidalApi                      api;
    HeldClient                    client{&api};
    std::unique_ptr<Player>       player;
    std::unique_ptr<MprisManager> mpris;
    Heard                         heard;

    Launch()
    {
        client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
        mpris = std::make_unique<MprisManager>(player.get());
    }

    Player &p() { return *player; }
    QMediaPlayer *mp() { return player->findChild<QMediaPlayer *>(); }

    // The Player builds its audio objects on the first turn of the loop.
    bool audioUp()
    {
        if (!QTest::qWaitFor([this] { return mp() != nullptr; }, 10000)) return false;
        heard.listenTo(player.get(), mp());
        return true;
    }
    bool plays() { return mp()->playbackState() == QMediaPlayer::PlayingState; }

    // The user's two moves, each with a line in what was heard.
    void seek(qint64 ms)
    {
        heard.note(QStringLiteral("seek(%1)").arg(ms));
        player->seek(ms);
    }
    void press()
    {
        heard.note(QStringLiteral("playPause()"));
        player->playPause();
    }
};

// The desktop's end of the bus: it hears what the service announces and asks
// like any widget.
class Desktop : public QObject {
    Q_OBJECT
public:
    explicit Desktop(const QString &address)
        : m_bus(QDBusConnection::connectToBus(address, QStringLiteral("desktop")))
    {
        m_bus.connect(QString(), kPath, kProps, QStringLiteral("PropertiesChanged"),
                      this, SLOT(onPropertiesChanged(QString,QVariantMap,QStringList)));
    }

    bool isConnected() const { return m_bus.isConnected(); }

    // Every status announced since the last forget(), oldest first.
    QStringList statuses;

    // A call is answered after every signal the service sent before it.
    QString status()
    {
        QDBusMessage msg = QDBusMessage::createMethodCall(kService, kPath, kProps,
                                                          QStringLiteral("Get"));
        msg.setArguments({ kPlayer, QStringLiteral("PlaybackStatus") });
        QDBusPendingCallWatcher watcher(m_bus.asyncCall(msg, 5000));
        QSignalSpy finished(&watcher, &QDBusPendingCallWatcher::finished);
        if (finished.isEmpty()) finished.wait(8000);
        const QDBusMessage reply = watcher.reply();
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty())
            return QString();
        return reply.arguments().constFirst().value<QDBusVariant>().variant().toString();
    }

    void forget()
    {
        status();
        statuses.clear();
    }

public slots:
    void onPropertiesChanged(const QString &iface, const QVariantMap &changed,
                             const QStringList &)
    {
        if (iface != kPlayer) return;
        const auto it = changed.constFind(QStringLiteral("PlaybackStatus"));
        if (it != changed.cend()) statuses.append(it->toString());
    }

private:
    QDBusConnection m_bus;
};

} // namespace

// Lets a late report arrive, then asks the flag, the player, the backend and
// the bus. The flag must be down and must not have been up since the count
// was last set to zero.
#define SETTLED(l, state)                                                                  \
    do {                                                                                   \
        QTest::qWait(kSettleMs);                                                           \
        QVERIFY2(!(l).p().loading(),                                                       \
                 (l).heard.after("the player says it is loading").constData());            \
        QVERIFY2((l).heard.rises == 0,                                                     \
                 (l).heard.after("the player said it was loading").constData());           \
        QCOMPARE((l).mp()->playbackState(), QMediaPlayer::state);                          \
        QCOMPARE((l).p().playing(), QMediaPlayer::state == QMediaPlayer::PlayingState);    \
        QCOMPARE(told(l), QMediaPlayer::state == QMediaPlayer::PlayingState                \
                              ? QStringLiteral("Playing") : QStringLiteral("Paused"));     \
    } while (false)

class TestPauseAfterSeek : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_pause_after_seek"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

        for (int i = 0; i < kProgSegmentCount; ++i)
            m_server.segments.append(
                inTidalsLayout(QByteArray::fromBase64(QByteArray(kProgSegmentsB64[i]))));
        QVERIFY(m_server.segments.at(1).mid(4, 4) == "moof");
        QVERIFY(m_server.listen(QHostAddress::LocalHost));

        QString mpd = QString::fromUtf8(kManifest);
        mpd.replace(QStringLiteral("@BASE@"),
                    QStringLiteral("http://127.0.0.1:%1/").arg(m_server.serverPort()));
        m_track.type     = StreamManifest::MPD;
        m_track.url      = mpd;
        m_track.mimeType = QStringLiteral("application/dash+xml");
        m_track.codec    = QStringLiteral("LOSSLESS");

        if (g_busAddress.isEmpty()) return;
        m_desk = std::make_unique<Desktop>(g_busAddress);
        QVERIFY(m_desk->isConnected());
    }

    void init() { QSettings().clear(); }

    // With no seek before it.
    void aPauseIsNoLoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l));

        l.press();
        SETTLED(l, PausedState);
        l.press();
        SETTLED(l, PlayingState);
    }

    void aPauseAfterASeekIsNoLoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l));

        l.seek(kSeekTo);
        // The backend has long filled its buffer again by then.
        QTRY_VERIFY2_WITH_TIMEOUT(l.mp()->position() >= kSeekTo + 300,
                                  "the track did not play on from where the seek put it", 5000);
        l.press();
        SETTLED(l, PausedState);
        QVERIFY2(l.mp()->position() >= kSeekTo && l.mp()->position() < kProgDurationMs - 500,
                 qPrintable(QStringLiteral("paused at %1 ms").arg(l.mp()->position())));
        if (m_desk) QCOMPARE(m_desk->statuses, (QStringList{ QStringLiteral("Paused") }));

        l.press();
        SETTLED(l, PlayingState);
        if (m_desk)
            QCOMPARE(m_desk->statuses,
                     (QStringList{ QStringLiteral("Paused"), QStringLiteral("Playing") }));
    }

    void playAfterASeekWhilePausedIsNoLoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l));

        l.press();
        QTRY_COMPARE_WITH_TIMEOUT(l.mp()->playbackState(), QMediaPlayer::PausedState, 5000);
        l.seek(kSeekTo);
        SETTLED(l, PausedState);

        l.press();
        SETTLED(l, PlayingState);
        if (m_desk)
            QCOMPARE(m_desk->statuses,
                     (QStringList{ QStringLiteral("Paused"), QStringLiteral("Playing") }));
        QTRY_VERIFY2_WITH_TIMEOUT(l.mp()->position() >= kSeekTo + 300,
                                  "the track did not play on from where the seek put it", 5000);
    }

    // The two moves in one turn of the loop, as soon as the backend plays.
    void aSeekAndAPauseRightAfterTheStartAreNoLoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(l.audioUp());
        l.p().playTracks(rowsOf(1), 0);
        QVERIFY(l.client.answer(1, m_track));
        QTRY_VERIFY2_WITH_TIMEOUT(l.plays(), "the track never started", 10000);

        l.heard.rises = 0;
        l.seek(kSeekTo);
        l.press();
        SETTLED(l, PausedState);

        l.press();
        SETTLED(l, PlayingState);
        QTRY_VERIFY2_WITH_TIMEOUT(l.mp()->position() >= kSeekTo + 300,
                                  "the track did not play on from where the seek put it", 5000);
    }

    // A restored session waits paused where it was left.
    void aTrackHeldPausedByARestoreIsLoaded()
    {
        if (const char *why = obstacle()) QSKIP(why);
        {
            Launch a;
            QVERIFY(a.audioUp());
            a.p().playTracks(rowsOf(1), 0);
            a.p().seek(kSavedAt);
            a.p().savePlaybackState();
        }

        Launch l;
        QVERIFY(l.audioUp());
        l.heard.countFromLoaded = true;
        QVERIFY2(l.client.answer(1, m_track), "the restore asked for nothing");
        QTRY_VERIFY2_WITH_TIMEOUT(l.mp()->playbackState() == QMediaPlayer::PausedState,
                                  "the restored track never came up paused", 10000);
        SETTLED(l, PausedState);
        QVERIFY2(qAbs(l.mp()->position() - kSavedAt) < 250,
                 qPrintable(QStringLiteral("restored at %1 ms").arg(l.mp()->position())));

        l.seek(kSeekTo);
        SETTLED(l, PausedState);
        l.press();
        SETTLED(l, PlayingState);
    }

    void theEndOfATrackAfterASeekIsNoLoad_data()
    {
        QTest::addColumn<int>("rows");
        QTest::newRow("the last track of the queue") << 1;
        QTest::newRow("a track with one after it")   << 2;
    }

    void theEndOfATrackAfterASeekIsNoLoad()
    {
        QFETCH(int, rows);
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l, rows));

        l.seek(kProgDurationMs - 1000);
        QTRY_VERIFY2_WITH_TIMEOUT(l.heard.ended, "the track never reached its end", 10000);
        if (rows == 1) {
            SETTLED(l, StoppedState);
            return;
        }

        // The next track is a load of its own, and one that ends.
        QVERIFY2(l.p().loading(), l.heard.after("the next track is not loading").constData());
        QVERIFY2(l.client.answer(2, m_track), "the queue asked for no next track");
        QVERIFY2(QTest::qWaitFor([&l] {
            return l.plays() && l.mp()->position() >= 300 && !l.p().loading();
        }, 10000), l.heard.after("the next track never played").constData());
        QCOMPARE(l.p().currentTrackMap().value(QStringLiteral("id")).toLongLong(), 2);
        // The seek was in the track before, and this start buffers as a load.
        QVERIFY2(l.heard.bufferingNotShown == 0,
                 l.heard.after("the next track buffered and the flag was down").constData());
        forget(l);
        l.press();
        SETTLED(l, PausedState);
    }

    // Next on the last track stops the backend, and play starts it over.
    void aStartAfterAStopBuffersAsALoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l));

        l.seek(kSeekTo);
        QTRY_VERIFY2_WITH_TIMEOUT(l.mp()->position() >= kSeekTo + 300,
                                  "the track did not play on from where the seek put it", 5000);
        l.heard.note(QStringLiteral("next()"));
        l.p().next();
        QCOMPARE(l.mp()->playbackState(), QMediaPlayer::StoppedState);

        l.press();
        QVERIFY2(QTest::qWaitFor([&l] {
            return l.plays() && l.mp()->position() >= 300 && !l.p().loading();
        }, 10000), l.heard.after("the track did not start over").constData());
        QVERIFY2(l.heard.bufferingNotShown == 0,
                 l.heard.after("the start buffered and the flag was down").constData());
    }

    // What stays a load: buffering at a start, and buffering the backend
    // reports of itself while a track plays.
    void bufferingWhileATrackPlaysIsALoad()
    {
        if (const char *why = obstacle()) QSKIP(why);
        Launch l;
        QVERIFY(sounding(l));
        QVERIFY2(l.heard.bufferingNotShown == 0,
                 l.heard.after("the start buffered and the flag was down").constData());

        QVERIFY(reports(l, QMediaPlayer::BufferingMedia));
        QVERIFY2(l.p().loading(), "a stall while playing was not shown as a load");
        QVERIFY(l.p().playing());
        QVERIFY(reports(l, QMediaPlayer::BufferedMedia));
        QVERIFY2(!l.p().loading(), "the end of a stall left the flag up");

        // A seek is over once the backend has said its buffer is full again,
        // which it does for a pause in the same turn of the loop.
        l.seek(kSeekTo);
        l.press();
        QTest::qWait(kSettleMs);
        l.press();
        QTRY_VERIFY2_WITH_TIMEOUT(l.plays(), "the track did not play on", 5000);
        QVERIFY(reports(l, QMediaPlayer::BufferingMedia));
        QVERIFY2(l.p().loading(),
                 l.heard.after("a stall after a seek was not shown as a load").constData());
        QVERIFY(reports(l, QMediaPlayer::BufferedMedia));
        QVERIFY2(!l.p().loading(), "the end of a stall left the flag up");
    }

private:
    // Why this Qt on this machine cannot play a track at its own pace, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
#endif
        return nullptr;
    }

    // Starts the first of a queue's rows and waits until it sounds.
    bool sounding(Launch &l, int rows = 1)
    {
        if (!l.audioUp()) return false;
        l.p().playTracks(rowsOf(rows), 0);
        if (!l.client.answer(1, m_track)) return false;
        if (!QTest::qWaitFor([&l] {
                return l.plays() && l.mp()->position() >= 300 && !l.p().loading();
            }, 10000))
            return false;
        forget(l);
        return true;
    }

    // From here on a rise of the flag and a status on the bus are news.
    void forget(Launch &l)
    {
        l.heard.rises = 0;
        if (m_desk) m_desk->forget();
    }

    // What a client is told: asked over the bus where there is one.
    QString told(Launch &l)
    {
        if (m_desk) return m_desk->status();
        return l.mpris->findChild<MprisPlayer *>()->property("PlaybackStatus").toString();
    }

    // Hands the Player a status as its backend would.
    static bool reports(Launch &l, QMediaPlayer::MediaStatus status)
    {
        return QMetaObject::invokeMethod(&l.p(), "onMediaStatusChanged",
                                         Q_ARG(QMediaPlayer::MediaStatus, status));
    }

    QTemporaryDir            m_dir;
    SegmentServer            m_server;
    StreamManifest           m_track;
    std::unique_ptr<Desktop> m_desk;
};

int main(int argc, char **argv)
{
    // A bus of this test's own, so nothing here reaches the session it runs in.
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"),
                 { QStringLiteral("--session"), QStringLiteral("--nofork"),
                   QStringLiteral("--print-address") });
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        g_busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();
    if (g_busAddress.isEmpty())
        qputenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/no-bus");
    else
        qputenv("DBUS_SESSION_BUS_ADDRESS", g_busAddress.toLocal8Bit());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // The backend the app selects on this Qt.
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
        qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

    int rc = 0;
    {
        QGuiApplication app(argc, argv);
        TestPauseAfterSeek test;
        rc = QTest::qExec(&test, argc, argv);
    }
    daemon.kill();
    daemon.waitForFinished(3000);
    return rc;
}

#include "tst_pause_after_seek.moc"
