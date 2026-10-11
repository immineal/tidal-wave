// MPRIS as a desktop sees it. The player and its service run in this process
// on a private bus, and a second connection plays the desktop's widget. Tracks
// are a silent WAV from a localhost server, and every Player is muted.

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QDataStream>
#include <QGuiApplication>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QProcess>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "mpris/MprisPlayer.h"
#include "player/Player.h"

namespace {

QString g_busAddress;

constexpr qint64 kUser = 4242;
const QString kPath      = QStringLiteral("/org/mpris/MediaPlayer2");
const QString kPlayer    = QStringLiteral("org.mpris.MediaPlayer2.Player");
const QString kProps     = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kService   = QStringLiteral("org.mpris.MediaPlayer2.tidalwave");

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

QString trackPath(qlonglong id) {
    return QStringLiteral("/org/tidalwave/track/%1").arg(id);
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

// A localhost origin for the audio: /track is the WAV, any other path is not
// there.
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
                const QByteArray path = buf->mid(4, buf->indexOf(' ', 4) - 4);
                buf->clear();
                const bool found = path == "/track";
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

// One launch of the app with its MPRIS service. With the account set first,
// the Player restores from its constructor as it does at startup.
struct Launch {
    TidalApi                      api;
    HeldClient                    client{&api};
    std::unique_ptr<Player>       player;
    std::unique_ptr<MprisManager> mpris;

    Launch() {
        client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
        mpris = std::make_unique<MprisManager>(player.get());
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

// The desktop's end: it hears the service's signals in the order they were
// sent, and asks over the bus like any widget.
class Desktop : public QObject {
    Q_OBJECT
public:
    explicit Desktop(const QString &address)
        : m_bus(QDBusConnection::connectToBus(address, QStringLiteral("desktop")))
    {
        m_bus.connect(QString(), kPath, kProps, QStringLiteral("PropertiesChanged"),
                      this, SLOT(onPropertiesChanged(QString,QVariantMap,QStringList)));
        m_bus.connect(QString(), kPath, kPlayer, QStringLiteral("Seeked"),
                      this, SLOT(onSeeked(qlonglong)));
    }

    bool isConnected() const { return m_bus.isConnected(); }

    // Every value announced for the player interface, oldest first.
    QList<std::pair<QString, QVariant>> changes;
    QList<qlonglong>                    seeked;   // microseconds

    QVariantList announced(const QString &property) const
    {
        QVariantList out;
        for (const auto &c : changes)
            if (c.first == property) out.append(c.second);
        return out;
    }
    QStringList statuses() const
    {
        QStringList out;
        for (const QVariant &v : announced(QStringLiteral("PlaybackStatus")))
            out.append(v.toString());
        return out;
    }

    // A call is answered after every signal the service sent before it, so
    // once this returns, nothing sent earlier is still on its way.
    QDBusMessage call(const QString &iface, const QString &method,
                      const QVariantList &args = {})
    {
        QDBusMessage msg = QDBusMessage::createMethodCall(kService, kPath, iface, method);
        msg.setArguments(args);
        QDBusPendingCallWatcher watcher(m_bus.asyncCall(msg, 5000));
        QSignalSpy finished(&watcher, &QDBusPendingCallWatcher::finished);
        if (finished.isEmpty()) finished.wait(8000);
        return watcher.reply();
    }
    QDBusMessage player(const QString &method, const QVariantList &args = {})
    {
        return call(kPlayer, method, args);
    }
    QVariant get(const QString &property)
    {
        const QDBusMessage reply = call(kProps, QStringLiteral("Get"), { kPlayer, property });
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty())
            return QVariant();
        return plain(reply.arguments().constFirst().value<QDBusVariant>().variant());
    }
    QString status() { return get(QStringLiteral("PlaybackStatus")).toString(); }
    bool set(const QString &property, const QVariant &value)
    {
        const QDBusMessage reply = call(kProps, QStringLiteral("Set"),
            { kPlayer, property, QVariant::fromValue(QDBusVariant(value)) });
        return reply.type() == QDBusMessage::ReplyMessage;
    }

    // Lets what is on its way arrive, then forgets everything heard so far.
    void forget()
    {
        status();
        changes.clear();
        seeked.clear();
    }

public slots:
    void onPropertiesChanged(const QString &iface, const QVariantMap &changed,
                             const QStringList &)
    {
        if (iface != kPlayer) return;
        for (auto it = changed.cbegin(); it != changed.cend(); ++it)
            changes.append({ it.key(), plain(it.value()) });
    }
    void onSeeked(qlonglong position) { seeked.append(position); }

private:
    // A dictionary inside a variant arrives still packed.
    static QVariant plain(const QVariant &v)
    {
        if (v.userType() == qMetaTypeId<QDBusArgument>())
            return qdbus_cast<QVariantMap>(v.value<QDBusArgument>());
        return v;
    }

    QDBusConnection m_bus;
};

} // namespace

class TestMpris : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        if (g_busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");

        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_mpris"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

        m_server.track = silentWav();
        QVERIFY(m_server.listen(QHostAddress::LocalHost));

        m_desk = std::make_unique<Desktop>(g_busAddress);
        QVERIFY(m_desk->isConnected());
    }

    void init() {
        QSettings().clear();
    }

    // ── PlaybackStatus ──────────────────────────────────────────────────────

    // The specification has three values, and with no track it is Stopped.
    void withNoTrackTheStatusIsStopped() {
        Launch a;
        QVERIFY(a.audioUp());
        QCOMPARE(desk().status(), QStringLiteral("Stopped"));
    }

    // A load the user started ends in playing and is reported as playing from
    // the start. Every later change is announced, the one into Stopped too.
    void aLoadTheUserStartedIsPlayingThroughout() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        desk().forget();

        a.p().playTracks(contextOf(3000, 2), 0);
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QVERIFY(a.client.answer(3000, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        QTest::qWait(300);
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QCOMPARE(desk().statuses(), (QStringList{ QStringLiteral("Playing") }));

        a.p().playPause();
        QTRY_COMPARE_WITH_TIMEOUT(desk().statuses().count(), 2, 5000);
        QCOMPARE(desk().statuses().constLast(), QStringLiteral("Paused"));

        a.p().clearQueue();
        QTRY_COMPARE_WITH_TIMEOUT(desk().statuses().count(), 3, 5000);
        QCOMPARE(desk().statuses().constLast(), QStringLiteral("Stopped"));
        QCOMPARE(desk().status(), QStringLiteral("Stopped"));
    }

    // The next track is on its way to playing as well: nothing but Playing is
    // heard while one track follows another.
    void theStatusStaysPlayingFromOneTrackToTheNext() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        desk().forget();

        a.p().next();
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QVERIFY(a.client.answer(3001, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        QTest::qWait(300);
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QCOMPARE(desk().statuses(), QStringList());
    }

    // The same when a track runs out and the player moves on by itself.
    void theStatusStaysPlayingWhenATrackRunsOut() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        a.p().playTracks(contextOf(3000, 2), 0);
        QVERIFY(a.client.answer(3000, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        desk().forget();

        // The request made ahead of time stays unanswered, so the track is
        // asked for again when it is reached.
        a.mp()->setPosition(29000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{3000, 3001, 3001}), 10000);
        QCOMPARE(currentId(a.p()), 3001);
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QVERIFY(a.client.answer(3001, track()));
        QVERIFY(a.client.answer(3001, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing(), 10000);
        QTest::qWait(300);
        QCOMPARE(desk().statuses(), QStringList());
    }

    // A load that ends with nothing loaded is over: the track is there and
    // does not play.
    void aLoadThatFailsIsPaused() {
        Launch a;
        QVERIFY(a.audioUp());
        desk().forget();

        a.p().playTracks(contextOf(3000, 2), 0);
        QCOMPARE(desk().status(), QStringLiteral("Playing"));
        QVERIFY(a.client.answer(3000, StreamManifest(), QStringLiteral("Host not found")));
        QCOMPARE(desk().status(), QStringLiteral("Paused"));
        QCOMPARE(desk().statuses(),
                 (QStringList{ QStringLiteral("Playing"), QStringLiteral("Paused") }));
    }

    // A restored session comes back paused, so its load is never Playing.
    void aRestoredTrackIsPausedThroughout() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));
        QCOMPARE(desk().status(), QStringLiteral("Paused"));
        desk().forget();

        QVERIFY(b.client.answer(1002, track()));
        QTRY_VERIFY_WITH_TIMEOUT(b.loaded(), 10000);
        QTest::qWait(300);
        QCOMPARE(desk().status(), QStringLiteral("Paused"));
        QCOMPARE(desk().statuses(), QStringList());
    }

    // ── Play ────────────────────────────────────────────────────────────────

    // The session was restored and its track never loaded: Tidal was out of
    // reach, or the stream resolved and the download failed. Nothing is loaded
    // for Play to start, so it asks again and plays from where it was left.
    void playLoadsARestoredTrackThatNeverLoaded_data() {
        QTest::addColumn<bool>("streamResolved");
        QTest::addColumn<QString>("method");
        QTest::newRow("Play, Tidal out of reach")        << false << QStringLiteral("Play");
        QTest::newRow("PlayPause, Tidal out of reach")   << false << QStringLiteral("PlayPause");
        QTest::newRow("Play, the download failed")       << true  << QStringLiteral("Play");
    }

    void playLoadsARestoredTrackThatNeverLoaded() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(bool, streamResolved);
        QFETCH(QString, method);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        if (streamResolved) {
            QSignalSpy errorSpy(&b.p(), &Player::error);
            QVERIFY(b.client.answer(1002, oneFileAt(m_server.url(QStringLiteral("/gone")))));
            QTRY_COMPARE_WITH_TIMEOUT(errorSpy.count(), 1, 10000);
        } else {
            QVERIFY(b.client.answer(1002, StreamManifest(), QStringLiteral("Host not found")));
        }
        QCOMPARE(desk().status(), QStringLiteral("Paused"));
        QCOMPARE(desk().get(QStringLiteral("Position")).toLongLong(), 12000000LL);
        desk().forget();

        desk().player(method);
        QVERIFY2(b.client.answer(1002, track()), "Play asked for nothing");
        QTRY_VERIFY2_WITH_TIMEOUT(b.p().playing(), "Play left it paused", 10000);
        QTRY_VERIFY_WITH_TIMEOUT(b.mp()->position() >= 11500, 5000);
        QCOMPARE(desk().statuses(), (QStringList{ QStringLiteral("Playing") }));
        // The third request fetches the next row ahead of time.
        QTRY_COMPARE_WITH_TIMEOUT(b.client.asked, (QList<qlonglong>{1002, 1002, 1003}), 5000);
        QCOMPARE(b.p().queueCount(), 5);
    }

    // ── Seeked ──────────────────────────────────────────────────────────────

    // While a track plays on, a client reckons the position from the clock.
    // It is told nothing, however often the player reports where it is.
    void steadyPlaybackSendsNoSeeked() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirstOf(a, 3000));
        desk().forget();

        QSignalSpy reports(&a.p(), &Player::positionChanged);
        QTest::qWait(2000);
        desk().status();
        QVERIFY2(reports.count() >= 5, qPrintable(QString::number(reports.count())));
        QCOMPARE(desk().seeked, QList<qlonglong>());
    }

    // A seek made inside the program is a jump no client can reckon, whether
    // the track plays or is paused. It is announced once, with where it went.
    void aSeekInsideTheProgramIsAnnouncedOnce() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirstOf(a, 3000));
        desk().forget();

        a.p().seek(12000);
        QTRY_COMPARE_WITH_TIMEOUT(desk().seeked.count(), 1, 5000);
        QVERIFY2(within(desk().seeked.constFirst(), 12000, 12500),
                 qPrintable(QString::number(desk().seeked.constFirst())));
        // The track plays on from there, and nothing more is said about it.
        QTRY_VERIFY_WITH_TIMEOUT(a.mp()->position() >= 13000, 10000);
        const qlonglong position = desk().get(QStringLiteral("Position")).toLongLong();
        QVERIFY2(within(position, 13000, 15000), qPrintable(QString::number(position)));
        QCOMPARE(desk().seeked.count(), 1);

        a.p().playPause();
        QTRY_VERIFY_WITH_TIMEOUT(!a.p().playing(), 5000);
        desk().forget();
        a.p().seek(20000);
        QTRY_COMPARE_WITH_TIMEOUT(desk().seeked.count(), 1, 5000);
        QVERIFY2(within(desk().seeked.constFirst(), 19900, 20100),
                 qPrintable(QString::number(desk().seeked.constFirst())));
    }

    // A track picked again starts over under the identity it had. No change
    // of metadata tells a client so, which leaves it to Seeked.
    void aTrackThatStartsOverIsAnnounced() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        QVERIFY(playFirstOf(a, 3000));
        a.p().seek(12000);
        QTRY_VERIFY_WITH_TIMEOUT(a.mp()->position() >= 12300, 5000);
        desk().forget();

        a.p().jumpToQueue(0);
        QVERIFY(a.client.answer(3000, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing() && a.mp()->position() > 300, 10000);
        QTest::qWait(300);
        desk().status();
        QVERIFY(!desk().seeked.isEmpty());
        QVERIFY2(desk().seeked.count() <= 2, qPrintable(QString::number(desk().seeked.count())));
        for (const qlonglong at : std::as_const(desk().seeked))
            QVERIFY2(within(at, 0, 500), qPrintable(QString::number(at)));
        QCOMPARE(desk().announced(QStringLiteral("Metadata")), QVariantList());
        QCOMPARE(desk().statuses(), QStringList());
    }

    // The status is Playing while a track loads, and a client's clock runs
    // for as long. When the track does start, the client is told where.
    void aTrackThatStartsAfterALongLoadIsAnnounced() {
        if (const char *why = obstacle()) QSKIP(why);

        Launch a;
        QVERIFY(a.audioUp());
        desk().forget();

        a.p().playTracks(contextOf(3000, 2), 0);
        QTest::qWait(900);
        QVERIFY(a.client.answer(3000, track()));
        QTRY_VERIFY_WITH_TIMEOUT(a.p().playing() && a.mp()->position() > 300, 10000);
        QTest::qWait(300);
        desk().status();
        // Once when the stream resolves, and again if the download is slow too.
        QVERIFY(!desk().seeked.isEmpty());
        QVERIFY2(desk().seeked.count() <= 2, qPrintable(QString::number(desk().seeked.count())));
        for (const qlonglong at : std::as_const(desk().seeked))
            QVERIFY2(within(at, 0, 400), qPrintable(QString::number(at)));
    }

    // A restored track waits at its saved position, which a client reads.
    // Loading the track moves nothing.
    void aRestoredTrackLoadsWithoutAJump() {
        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(saveFiveRowSession());

        Launch b;
        QVERIFY(b.audioUp());
        QCOMPARE(desk().get(QStringLiteral("Position")).toLongLong(), 12000000LL);
        desk().forget();

        QVERIFY(b.client.answer(1002, track()));
        QTRY_VERIFY_WITH_TIMEOUT(b.loaded(), 10000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(b.mp()->position() - 12000) < 250, 5000);
        QTest::qWait(300);
        const qlonglong position = desk().get(QStringLiteral("Position")).toLongLong();
        QVERIFY2(within(position, 11750, 12250), qPrintable(QString::number(position)));
        QCOMPARE(desk().seeked, QList<qlonglong>());
    }

private:
    Desktop &desk() { return *m_desk; }

    // Whether a position in microseconds lies between two in milliseconds.
    static bool within(qlonglong micros, qint64 fromMs, qint64 toMs)
    {
        return micros >= fromMs * 1000 && micros <= toMs * 1000;
    }

    // Starts a two-row context and waits until its first track really plays.
    bool playFirstOf(Launch &l, qlonglong base)
    {
        l.p().playTracks(contextOf(base, 2), 0);
        if (!l.client.answer(base, track())) return false;
        return QTest::qWaitFor([&l] { return l.p().playing() && l.mp()->position() > 300; },
                               10000);
    }

    StreamManifest track() const { return oneFileAt(m_server.url(QStringLiteral("/track"))); }

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

    QTemporaryDir            m_dir;
    MediaServer              m_server;
    std::unique_ptr<Desktop> m_desk;
};

int main(int argc, char **argv) {
    // A bus of this test's own, so nothing here reaches the session it runs in.
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"),
                 { QStringLiteral("--session"), QStringLiteral("--nofork"),
                   QStringLiteral("--print-address") });
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        g_busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();
    if (g_busAddress.isEmpty())
        qunsetenv("DBUS_SESSION_BUS_ADDRESS");   // never the session's own bus
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
        TestMpris test;
        rc = QTest::qExec(&test, argc, argv);
    }
    daemon.kill();
    daemon.waitForFinished(3000);
    return rc;
}

#include "tst_mpris.moc"
