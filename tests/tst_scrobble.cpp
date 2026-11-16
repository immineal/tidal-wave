// Scrobbling: the rule for when a play counts, the ListenBrainz payload as its
// docs give it, and the queue on disk with its answers to 429, 5xx and 401.
// Every request goes to a server on loopback; nothing reaches listenbrainz.org.

#include <QTest>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <functional>
#include <memory>

#include "api/Auth.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#ifdef Q_OS_LINUX
#include "cast/CastSession.h"
#endif
#include "player/Player.h"
#include "scrobble/ListenBrainz.h"
#include "scrobble/PlayTracker.h"
#include "scrobble/ScrobbleSink.h"
#include "scrobble/Scrobbler.h"

namespace {

// All invented.
const QString kToken = QStringLiteral("7f3c-test-token-e21b");
const QString kUser  = QStringLiteral("listener");

Listen track(qint64 id, int seconds, const QString &title = QStringLiteral("Weit weg")) {
    Listen l;
    l.trackId     = id;
    l.artist      = QStringLiteral("Erika Mustermann");
    l.title       = title;
    l.album       = QStringLiteral("Nachtfahrt");
    l.durationMs  = qint64(seconds) * 1000;
    l.trackNumber = 4;
    l.isrc        = QStringLiteral("XX0000000001");
    return l;
}

// Plays the tracker on from `from` to `to` in steps of `step` ms, the clock
// keeping pace. Returns the clock.
qint64 play(PlayTracker &t, qint64 from, qint64 to, qint64 clock, qint64 step = 500) {
    for (qint64 p = from; p <= to; p += step) {
        t.position(p, clock, 1'700'000'000 + clock / 1000);
        clock += step;
    }
    return clock;
}

// ListenBrainz on loopback. Each request is recorded; `answer` picks the reply.
class FakeListenBrainz : public QTcpServer {
public:
    struct Request {
        QByteArray verb, path, auth, body;
        int status = 0;
        QJsonObject json() const { return QJsonDocument::fromJson(body).object(); }
    };
    struct Reply {
        int status = 200;
        QByteArray body = R"({"status":"ok"})";
        QList<QPair<QByteArray, QByteArray>> headers;
        // Held back this long, as a slow server would.
        int delayMs = 0;
    };

    // The token is valid and every listen taken.
    static Reply fine(const Request &r) {
        Reply a;
        if (r.path == "/1/validate-token")
            a.body = R"({"code":200,"message":"Token valid.","valid":true,"user_name":"listener"})";
        return a;
    }
    // The token is valid and every listen answered with `status`.
    static std::function<Reply(const Request &)> failing(int status) {
        return [status](const Request &r) {
            return r.path == "/1/validate-token" ? fine(r) : Reply{status};
        };
    }
    std::function<Reply(const Request &)> answer = fine;
    QList<Request> seen;
    QList<qint64> when;
    QElapsedTimer clock;

    FakeListenBrainz() {
        clock.start();
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    const qsizetype end = buf->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    const QList<QByteArray> lines = buf->left(end).split('\n');
                    qsizetype length = 0;
                    Request r;
                    for (const QByteArray &raw : lines.mid(1)) {
                        const QByteArray line = raw.trimmed();
                        const QByteArray name = line.left(line.indexOf(':')).toLower();
                        const QByteArray value = line.mid(line.indexOf(':') + 1).trimmed();
                        if (name == "content-length") length = value.toLongLong();
                        if (name == "authorization") r.auth = value;
                    }
                    if (buf->size() < end + 4 + length) return;
                    const QList<QByteArray> first = lines.first().trimmed().split(' ');
                    r.verb = first.value(0);
                    r.path = first.value(1);
                    r.body = buf->mid(end + 4, length);
                    buf->clear();
                    const Reply a = answer(r);
                    r.status = a.status;
                    seen << r;
                    when << clock.elapsed();
                    QByteArray out = "HTTP/1.0 " + QByteArray::number(a.status) + " Answer\r\n"
                                     "Content-Type: application/json\r\n";
                    for (const auto &h : a.headers) out += h.first + ": " + h.second + "\r\n";
                    out += "Content-Length: " + QByteArray::number(a.body.size()) + "\r\n\r\n" + a.body;
                    QTimer::singleShot(a.delayMs, sock, [sock, out] {
                        sock->write(out);
                        sock->flush();
                        sock->disconnectFromHost();
                    });
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
        if (!listen(QHostAddress::LocalHost)) qFatal("no loopback server");
    }

    QUrl base() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(serverPort())); }

    QList<Request> submits() const {
        QList<Request> out;
        for (const Request &r : seen)
            if (r.path == "/1/submit-listens" && r.json().value("listen_type") != QLatin1String("playing_now"))
                out << r;
        return out;
    }
    // Listens the server took.
    int listensTaken() const {
        int n = 0;
        for (const Request &r : submits())
            if (r.status == 200) n += int(r.json().value("payload").toArray().size());
        return n;
    }
};

// Everything the app logs while a test runs, to look for the token in.
QStringList g_log;
QtMessageHandler g_previous = nullptr;
void keepLog(QtMsgType type, const QMessageLogContext &ctx, const QString &msg) {
    g_log << msg;
    if (g_previous) g_previous(type, ctx, msg);
}

} // namespace

class TestScrobble : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

    ScrobbleSink::Paths paths() const {
        return { m_dir.filePath(QStringLiteral("config/scrobbling-listenbrainz.json")),
                 m_dir.filePath(QStringLiteral("data/scrobble-queue-listenbrainz.json")) };
    }

    // A sink on the fake server, switched on, with short waits.
    std::unique_ptr<ScrobbleSink> sink(FakeListenBrainz &server, int retryMs = 100) {
        auto *lb = new ListenBrainz;
        lb->setBaseUrl(server.base());
        auto s = std::make_unique<ScrobbleSink>(lb, paths());
        s->setTimingForTest(10, retryMs);
        s->setEnabled(true);
        return s;
    }

    std::unique_ptr<ScrobbleSink> connectedSink(FakeListenBrainz &server, int retryMs = 100) {
        auto s = sink(server, retryMs);
        s->signIn(kToken);
        if (!QTest::qWaitFor([&] { return s->connected(); }, 5000)) return nullptr;
        server.seen.clear();
        server.when.clear();
        return s;
    }

private slots:
    void initTestCase() {
        QVERIFY(m_dir.isValid());
        qputenv("HOME", m_dir.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", m_dir.filePath(QStringLiteral(".config")).toUtf8());
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_scrobble"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
        g_previous = qInstallMessageHandler(keepLog);
    }

    void init() {
        QFile::remove(paths().secret);
        QFile::remove(paths().queue);
        QSettings().clear();
    }

    // Whatever was logged, the token never was.
    void cleanup() {
        for (const QString &line : std::as_const(g_log))
            QVERIFY2(!line.contains(kToken), qPrintable("the token was logged: " + line));
        g_log.clear();
    }

    // ── the rule ─────────────────────────────────────────────────────────

    void threshold_data() {
        QTest::addColumn<int>("seconds");
        QTest::addColumn<qint64>("needed");
        QTest::newRow("30 s is too short") << 30 << qint64(-1);
        QTest::newRow("31 s, half")        << 31 << qint64(15500);
        QTest::newRow("3:20, half")        << 200 << qint64(100000);
        QTest::newRow("8:00, 4 min")       << 480 << qint64(240000);
        QTest::newRow("12:00, 4 min")      << 720 << qint64(240000);
    }
    void threshold() {
        QFETCH(int, seconds);
        QFETCH(qint64, needed);
        QCOMPARE(PlayTracker::thresholdMs(qint64(seconds) * 1000), needed);
    }

    // Half of a 3:20 track: counted at 1:40 and not a step before.
    void halfOfTheTrackCounts() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 99500, 0);
        QCOMPARE(listened.count(), 0);
        play(t, 100000, 100000, clock);
        QCOMPARE(listened.count(), 1);
        // Once per play, however long it goes on.
        play(t, 100500, 199500, clock + 500);
        QCOMPARE(listened.count(), 1);
    }

    // A long track counts at 4 minutes.
    void fourMinutesCount() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 720));
        t.setPlaying(true, 0);
        const qint64 clock = play(t, 0, 239500, 0);
        QCOMPARE(listened.count(), 0);
        play(t, 240000, 240000, clock);
        QCOMPARE(listened.count(), 1);
    }

    void aShortTrackNeverCounts() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 30));
        t.setPlaying(true, 0);
        play(t, 0, 30000, 0);
        QCOMPARE(listened.count(), 0);
    }

    // A pause is no play, however long, and the position stands still in it.
    void aPauseAddsNothing() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 50000, 0);
        t.setPlaying(false, clock);
        // Reports in the pause, an hour of it.
        for (int i = 0; i < 10; ++i) { clock += 360000; t.position(50000, clock, 0); }
        t.setPlaying(true, clock);
        clock = play(t, 50500, 99500, clock);
        QCOMPARE(t.playedMs(), qint64(99500));
        QCOMPARE(listened.count(), 0);
        play(t, 100000, 100000, clock);
        QCOMPARE(listened.count(), 1);
    }

    // Seeking ahead skips the part between; only what is heard counts.
    void aSeekAddsNothing() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 10000, 0);
        t.seeked();
        t.position(150000, clock, 0);
        clock = play(t, 150500, 199500, clock + 500);
        QCOMPARE(listened.count(), 0);
        QVERIFY2(t.playedMs() < 60000, qPrintable(QString::number(t.playedMs())));
    }

    // A small seek is still a seek: the step it makes is not played.
    void aShortSeekAddsNothing() {
        PlayTracker t;
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        const qint64 clock = play(t, 0, 10000, 0);
        t.seeked();
        t.position(11500, clock, 0);
        QCOMPARE(t.playedMs(), qint64(10000));
    }

    // A jump the player did not announce counts as a seek too.
    void aJumpAddsNothing() {
        PlayTracker t;
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 10000, 0);
        t.position(90000, clock, 0);
        QCOMPARE(t.playedMs(), qint64(10000));
    }

    // Skipped after 20 s: no listen, and the next track starts from nothing.
    void aSkippedTrackDoesNotCount() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        QSignalSpy started(&t, &PlayTracker::started);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 20000, 0);
        t.setTrack(track(2, 200));
        QCOMPARE(t.playedMs(), qint64(0));
        play(t, 0, 100000, clock);
        QCOMPARE(listened.count(), 1);
        QCOMPARE(listened.at(0).at(0).value<Listen>().trackId, qint64(2));
        QCOMPARE(started.count(), 2);
    }

    // Repeat-one plays the track out and starts it over: two listens.
    void aRepeatCountsTwice() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        QSignalSpy started(&t, &PlayTracker::started);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 200000, 0);
        // What Player::startOver() says: the start, then that it was a seek.
        t.position(0, clock, 0);
        t.seeked();
        t.setTrack(track(1, 200));
        clock = play(t, 50, 200000, clock + 50);
        QCOMPARE(listened.count(), 2);
        QCOMPARE(started.count(), 2);
        QVERIFY(listened.at(1).at(0).value<Listen>().listenedAt
                > listened.at(0).at(0).value<Listen>().listenedAt);
    }

    // Back at the start and then on to where it was, as a cast hands back:
    // still the one play.
    void backToTheStartAndOnIsNoNewPlay() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 600));
        t.setPlaying(true, 0);
        qint64 clock = play(t, 0, 250000, 0);
        QCOMPARE(listened.count(), 1);
        t.position(0, clock, 0);
        t.position(250000, clock + 100, 0);
        play(t, 250500, 600000, clock + 600);
        QCOMPARE(listened.count(), 1);
    }

    // A session restored paused says nothing until it plays.
    void playingNowWaitsForPlay() {
        PlayTracker t;
        QSignalSpy started(&t, &PlayTracker::started);
        t.setTrack(track(1, 200));
        t.position(80000, 0, 0);
        t.position(80000, 5000, 0);
        QCOMPARE(started.count(), 0);
        t.setPlaying(true, 6000);
        play(t, 80500, 81000, 6500);
        QCOMPARE(started.count(), 1);
        QCOMPARE(started.at(0).at(0).value<Listen>().listenedAt, qint64(0));
    }

    // listened_at is when the play started, not when it crossed the line.
    void theListenIsStampedWithItsStart() {
        PlayTracker t;
        QSignalSpy listened(&t, &PlayTracker::listened);
        t.setTrack(track(1, 200));
        t.setPlaying(true, 0);
        play(t, 0, 100000, 0);
        QCOMPARE(listened.count(), 1);
        QCOMPARE(listened.at(0).at(0).value<Listen>().listenedAt, qint64(1'700'000'000));
    }

    // ── the payload, against users/json.html ─────────────────────────────

    void aSingleListenHasTheDocumentedShape() {
        Listen l = track(58990486, 215);
        l.listenedAt = 1'700'000'123;
        const QJsonObject doc = QJsonDocument::fromJson(
            ListenBrainz::payload(QStringLiteral("single"), {l})).object();
        QCOMPARE(doc.value("listen_type").toString(), QStringLiteral("single"));
        const QJsonArray payload = doc.value("payload").toArray();
        QCOMPARE(payload.size(), 1);
        const QJsonObject entry = payload.at(0).toObject();
        QVERIFY(entry.value("listened_at").isDouble());
        QCOMPARE(entry.value("listened_at").toInteger(), qint64(1'700'000'123));
        const QJsonObject meta = entry.value("track_metadata").toObject();
        QCOMPARE(meta.value("artist_name").toString(), l.artist);
        QCOMPARE(meta.value("track_name").toString(), l.title);
        QCOMPARE(meta.value("release_name").toString(), l.album);
        const QJsonObject info = meta.value("additional_info").toObject();
        QVERIFY(info.value("duration_ms").isDouble());
        QCOMPARE(info.value("duration_ms").toInteger(), qint64(215000));
        QVERIFY2(!info.contains("duration"), "only one of duration and duration_ms");
        QCOMPARE(info.value("tracknumber").toString(), QStringLiteral("4"));
        QCOMPARE(info.value("isrc").toString(), l.isrc);
        QCOMPARE(info.value("media_player").toString(), QStringLiteral("Tidal Wave"));
        QCOMPARE(info.value("submission_client").toString(), QStringLiteral("Tidal Wave"));
        QCOMPARE(info.value("media_player_version").toString(), QStringLiteral(TIDALWAVE_VERSION));
        QCOMPARE(info.value("submission_client_version").toString(), QStringLiteral(TIDALWAVE_VERSION));
        QCOMPARE(info.value("music_service").toString(), QStringLiteral("tidal.com"));
        QCOMPARE(info.value("origin_url").toString(), QStringLiteral("https://tidal.com/track/58990486"));
        // Names carry no version number, as the docs ask.
        QVERIFY(!info.value("media_player").toString().contains(QStringLiteral(TIDALWAVE_VERSION)));
    }

    void playingNowHasNoTimestamp() {
        const QJsonObject doc = QJsonDocument::fromJson(
            ListenBrainz::payload(QStringLiteral("playing_now"), {track(1, 200)})).object();
        QCOMPARE(doc.value("listen_type").toString(), QStringLiteral("playing_now"));
        QVERIFY(!doc.value("payload").toArray().at(0).toObject().contains("listened_at"));
    }

    // What is not known is left out, never sent empty.
    void emptyFieldsAreLeftOut() {
        Listen l;
        l.trackId = 9; l.artist = QStringLiteral("A"); l.title = QStringLiteral("T");
        l.listenedAt = 1'700'000'000;
        const QJsonObject meta = ListenBrainz::listenJson(l, true).value("track_metadata").toObject();
        QVERIFY(!meta.contains("release_name"));
        const QJsonObject info = meta.value("additional_info").toObject();
        for (const char *key : {"duration_ms", "tracknumber", "isrc"})
            QVERIFY2(!info.contains(QLatin1String(key)), key);
    }

    void aBatchIsAnImport() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.answer = FakeListenBrainz::failing(503);
        for (int i = 1; i <= 3; ++i) { Listen l = track(i, 200); l.listenedAt = 1'700'000'000 + i * 300; s->add(l); }
        QTRY_COMPARE(s->queuedCount(), 3);
        QTRY_VERIFY(!server.seen.isEmpty());
        server.answer = FakeListenBrainz::fine;
        server.seen.clear();
        s->setTimingForTest(10, 50);
        s->signIn(kToken);   // a new token starts the sending again
        QTRY_COMPARE(s->queuedCount(), 0);
        const auto submits = server.submits();
        QCOMPARE(submits.size(), 1);
        QCOMPARE(submits.at(0).json().value("listen_type").toString(), QStringLiteral("import"));
        const QJsonArray p = submits.at(0).json().value("payload").toArray();
        QCOMPARE(p.size(), 3);
        // In the order they were played.
        QCOMPARE(p.at(0).toObject().value("listened_at").toInteger(), qint64(1'700'000'300));
        QCOMPARE(p.at(2).toObject().value("listened_at").toInteger(), qint64(1'700'000'900));
    }

    // ── the account ──────────────────────────────────────────────────────

    // The token is checked, the name it belongs to shown, and it is kept
    // owner-only beside the Tidal credentials.
    void aTokenIsCheckedAndKept() {
        FakeListenBrainz server;
        auto s = sink(server);
        s->signIn(QStringLiteral("  ") + kToken + QStringLiteral("\n"));
        QVERIFY(s->checking());
        QTRY_VERIFY(s->connected());
        QVERIFY(!s->checking());
        QCOMPARE(s->userName(), kUser);
        QCOMPARE(server.seen.size(), 1);
        QCOMPARE(server.seen.at(0).verb, QByteArray("GET"));
        QCOMPARE(server.seen.at(0).path, QByteArray("/1/validate-token"));
        QCOMPARE(server.seen.at(0).auth, "Token " + kToken.toUtf8());
        QVERIFY(QFile::exists(paths().secret));
        QCOMPARE(QFile::permissions(paths().secret),
                 QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ReadUser | QFileDevice::WriteUser);
        // A second start reads it back.
        s.reset();
        auto again = sink(server);
        QVERIFY(again->connected());
        QCOMPARE(again->userName(), kUser);
    }

    void theDefaultPlaceIsBesideTheTidalCredentials() {
        const ScrobbleSink::Paths p = ScrobbleSink::defaultPaths(QStringLiteral("listenbrainz"));
        QCOMPARE(QFileInfo(p.secret).absolutePath(), QFileInfo(Auth::credentialsPath()).absolutePath());
    }

    void anUnknownTokenIsNotKept() {
        FakeListenBrainz server;
        server.answer = [](const FakeListenBrainz::Request &) {
            return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token invalid.","valid":false})", {}};
        };
        auto s = sink(server);
        s->signIn(kToken);
        QTRY_VERIFY(!s->checking());
        QVERIFY(!s->connected());
        QVERIFY(!s->lastError().isEmpty());
        QCOMPARE(s->statusText(), s->lastError());
        QVERIFY(!QFile::exists(paths().secret));
    }

    // Disconnect forgets the token and keeps what was not sent; the same
    // account connecting again sends it, after a restart too.
    void disconnectKeepsTheQueueForTheSameAccount() {
        FakeListenBrainz server;
        {
            auto s = connectedSink(server, 60'000);
            QVERIFY(s);
            server.answer = FakeListenBrainz::failing(503);
            s->add(track(1, 200));
            QTRY_VERIFY(!server.seen.isEmpty());
            QVERIFY(QFile::exists(paths().queue));
            s->disconnectAccount();
            QVERIFY(!s->connected());
            QVERIFY(!QFile::exists(paths().secret));
            QCOMPARE(s->queuedCount(), 1);
            QVERIFY(QFile::exists(paths().queue));
            QVERIFY2(s->statusText().contains(kUser), qPrintable(s->statusText()));
        }
        server.answer = FakeListenBrainz::fine;
        server.seen.clear();
        auto s = sink(server);
        QVERIFY(!s->connected());
        QCOMPARE(s->queuedCount(), 1);
        QTest::qWait(100);
        QCOMPARE(server.seen.size(), 0);
        s->signIn(kToken);
        QTRY_COMPARE(s->queuedCount(), 0);
        QCOMPARE(server.listensTaken(), 1);
    }

    // Another account after a disconnect starts with an empty queue.
    void anotherAccountAfterDisconnectDropsTheKeptQueue() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.answer = FakeListenBrainz::failing(503);
        s->add(track(1, 200));
        QTRY_VERIFY(!server.seen.isEmpty());
        s->disconnectAccount();
        QCOMPARE(s->queuedCount(), 1);
        server.seen.clear();
        server.answer = [](const FakeListenBrainz::Request &r) {
            if (r.path == "/1/validate-token")
                return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"someone-else"})", {}};
            return FakeListenBrainz::Reply{};
        };
        s->signIn(QStringLiteral("other-token"));
        QTRY_COMPARE(s->userName(), QStringLiteral("someone-else"));
        QCOMPARE(s->queuedCount(), 0);
        QVERIFY(!QFile::exists(paths().queue));
        QTest::qWait(100);
        QCOMPARE(server.submits().size(), 0);
    }

    // A batch on its way when Disconnect is pressed: its answer still counts,
    // so the same account connecting again does not send it twice.
    void aBatchAnsweredAfterDisconnectIsNotSentTwice() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        server.answer = [](const FakeListenBrainz::Request &r) {
            FakeListenBrainz::Reply a = FakeListenBrainz::fine(r);
            a.delayMs = 300;
            return a;
        };
        s->add(track(1, 200));
        QTRY_COMPARE(server.seen.size(), 1);
        s->disconnectAccount();
        QCOMPARE(s->queuedCount(), 1);
        QTRY_COMPARE(s->queuedCount(), 0);
        server.answer = FakeListenBrainz::fine;
        s->signIn(kToken);
        QTRY_VERIFY(s->connected());
        QTest::qWait(100);
        QCOMPARE(server.listensTaken(), 1);
    }

    // Off, nothing is recorded and nothing goes out.
    void offSendsNothing() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        s->setEnabled(false);
        s->nowPlaying(track(1, 200));
        s->add(track(1, 200));
        QTest::qWait(300);
        QCOMPARE(server.seen.size(), 0);
        QCOMPARE(s->queuedCount(), 0);
    }

    void offIsTheDefault() {
        FakeListenBrainz server;
        auto *lb = new ListenBrainz;
        ScrobbleSink s(lb, paths());
        QVERIFY(!s.enabled());
    }

    // ── sending ──────────────────────────────────────────────────────────

    void aListenGoesOutAsASingle() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        Listen l = track(1, 200);
        l.listenedAt = 1'700'000'000;
        s->add(l);
        QTRY_COMPARE(s->queuedCount(), 0);
        QCOMPARE(server.seen.size(), 1);
        const auto &r = server.seen.at(0);
        QCOMPARE(r.verb, QByteArray("POST"));
        QCOMPARE(r.path, QByteArray("/1/submit-listens"));
        QCOMPARE(r.auth, "Token " + kToken.toUtf8());
        QCOMPARE(r.json().value("listen_type").toString(), QStringLiteral("single"));
        QVERIFY(s->lastError().isEmpty());
        QVERIFY(!QFile::exists(paths().queue));
    }

    // Playing now goes out once; a failure is not tried again.
    void playingNowIsSentOnceAndNotRetried() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        server.answer = FakeListenBrainz::failing(503);
        s->nowPlaying(track(1, 200));
        QTRY_COMPARE(server.seen.size(), 1);
        QCOMPARE(server.seen.at(0).json().value("listen_type").toString(), QStringLiteral("playing_now"));
        QTest::qWait(400);
        QCOMPARE(server.seen.size(), 1);
        QCOMPARE(s->queuedCount(), 0);
    }

    // Unsent listens wait on disk and go out after a restart.
    void theQueueOutlivesARestart() {
        FakeListenBrainz server;
        {
            auto s = connectedSink(server, 60'000);
            QVERIFY(s);
            server.answer = FakeListenBrainz::failing(503);
            Listen a = track(1, 200, QStringLiteral("Erster")); a.listenedAt = 1'700'000'000;
            Listen b = track(2, 200, QStringLiteral("Zweiter")); b.listenedAt = 1'700'000'300;
            s->add(a);
            s->add(b);
            QTRY_VERIFY(!server.seen.isEmpty());
            QCOMPARE(s->queuedCount(), 2);
        }
        server.answer = FakeListenBrainz::fine;
        server.seen.clear();
        auto s = sink(server);
        QCOMPARE(s->queuedCount(), 2);
        QCOMPARE(s->queued().at(0).title, QStringLiteral("Erster"));
        QCOMPARE(s->queued().at(1).listenedAt, qint64(1'700'000'300));
        QTRY_COMPARE(s->queuedCount(), 0);
        QCOMPARE(server.listensTaken(), 2);
    }

    // 5xx and no answer at all: the listens wait and are tried again later,
    // and the status says why in words.
    void aServerErrorIsRetried_data() {
        QTest::addColumn<int>("status");
        QTest::newRow("500") << 500;
        QTest::newRow("503") << 503;
    }
    void aServerErrorIsRetried() {
        QFETCH(int, status);
        FakeListenBrainz server;
        auto s = connectedSink(server, 200);
        QVERIFY(s);
        int fails = 2;
        server.answer = [&fails, status](const FakeListenBrainz::Request &) {
            return fails-- > 0 ? FakeListenBrainz::Reply{status} : FakeListenBrainz::Reply{};
        };
        s->add(track(1, 200));
        QTRY_VERIFY(!s->lastError().isEmpty());
        QCOMPARE(server.seen.size(), 1);
        QCOMPARE(s->queuedCount(), 1);
        QVERIFY(s->statusText().contains(s->lastError()));
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        QCOMPARE(server.seen.size(), 3);
        // The second wait is longer than the first.
        QVERIFY(server.when.at(2) - server.when.at(1) >= 390);
        QVERIFY(server.when.at(1) - server.when.at(0) >= 190);
        QVERIFY(s->lastError().isEmpty());
    }

    void offlineIsRetried() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 200);
        QVERIFY(s);
        // A port nothing listens on any more.
        auto *lb = s->findChild<ListenBrainz *>();
        QVERIFY(lb);
        QTcpServer gone;
        QVERIFY(gone.listen(QHostAddress::LocalHost));
        lb->setBaseUrl(QUrl(QStringLiteral("http://127.0.0.1:%1").arg(gone.serverPort())));
        gone.close();
        s->add(track(1, 200));
        QTRY_VERIFY(!s->lastError().isEmpty());
        QCOMPARE(s->queuedCount(), 1);
        lb->setBaseUrl(server.base());
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        QVERIFY(s->lastError().isEmpty());
    }

    // 429: the wait its X-RateLimit-Reset-In names, then the same listens.
    void tooManyRequestsWaitsAsTold() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        int fails = 1;
        server.answer = [&fails](const FakeListenBrainz::Request &) {
            if (fails-- > 0)
                return FakeListenBrainz::Reply{429, R"({"code":429,"error":"Too many requests"})",
                    {{"X-RateLimit-Limit", "30"}, {"X-RateLimit-Remaining", "0"}, {"X-RateLimit-Reset-In", "2"}}};
            return FakeListenBrainz::Reply{};
        };
        s->add(track(1, 200));
        QTRY_VERIFY(!s->lastError().isEmpty());
        QCOMPARE(server.seen.size(), 1);
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        QCOMPARE(server.seen.size(), 2);
        QVERIFY2(server.when.at(1) - server.when.at(0) >= 1900,
                 qPrintable(QString::number(server.when.at(1) - server.when.at(0))));
    }

    // A window used up on a success holds the next request back as well.
    void anEmptyWindowHoldsTheNextRequest() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        server.answer = [](const FakeListenBrainz::Request &) {
            return FakeListenBrainz::Reply{200, R"({"status":"ok"})",
                {{"X-RateLimit-Remaining", "0"}, {"X-RateLimit-Reset-In", "1"}}};
        };
        s->add(track(1, 200));
        QTRY_COMPARE(server.seen.size(), 1);
        s->add(track(2, 200));
        QTRY_COMPARE_WITH_TIMEOUT(server.seen.size(), 2, 5000);
        QVERIFY2(server.when.at(1) - server.when.at(0) >= 900,
                 qPrintable(QString::number(server.when.at(1) - server.when.at(0))));
    }

    // 401: sending stops, Settings says so, and nothing is lost. A new token
    // for the same account sends what waited.
    void aRefusedTokenStopsSending() {
        FakeListenBrainz server;
        auto s = connectedSink(server);
        QVERIFY(s);
        server.answer = [](const FakeListenBrainz::Request &r) {
            if (r.path == "/1/validate-token")
                return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"listener"})", {}};
            if (r.auth.endsWith("new"))
                return FakeListenBrainz::Reply{};
            return FakeListenBrainz::Reply{401, R"({"code":401,"error":"Invalid authorization token."})", {}};
        };
        s->add(track(1, 200));
        QTRY_VERIFY(s->authFailed());
        QVERIFY(!s->lastError().isEmpty());
        QVERIFY(s->statusText().contains(s->lastError()));
        s->add(track(2, 200));
        s->nowPlaying(track(3, 200));
        QTest::qWait(400);
        QCOMPARE(server.seen.size(), 1);
        QCOMPARE(s->queuedCount(), 2);

        s->signIn(kToken + QStringLiteral("new"));
        QTRY_COMPARE(s->queuedCount(), 0);
        QVERIFY(!s->authFailed());
        QVERIFY(s->lastError().isEmpty());
        QCOMPARE(server.listensTaken(), 2);
        QCOMPARE(server.submits().last().json().value("payload").toArray().size(), 2);
    }

    // A token of another account does not send the old one's listens.
    void anotherAccountDropsTheOldQueue() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.answer = [](const FakeListenBrainz::Request &r) {
            if (r.path == "/1/validate-token")
                return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"someone-else"})", {}};
            return FakeListenBrainz::Reply{503};
        };
        s->add(track(1, 200));
        QTRY_COMPARE(s->queuedCount(), 1);
        s->signIn(QStringLiteral("other-token"));
        QTRY_COMPARE(s->userName(), QStringLiteral("someone-else"));
        QCOMPARE(s->queuedCount(), 0);
    }

    // One bad listen refuses its batch; the rest still go, and the status
    // names the one that was turned down.
    void aRefusedListenIsDroppedAlone() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.answer = FakeListenBrainz::failing(503);
        s->add(track(1, 200, QStringLiteral("Gut")));
        s->add(track(2, 200, QStringLiteral("Kaputt")));
        s->add(track(3, 200, QStringLiteral("Auch gut")));
        QTRY_COMPARE(s->queuedCount(), 3);
        QTRY_VERIFY(!s->lastError().isEmpty());
        server.answer = [](const FakeListenBrainz::Request &r) {
            if (r.path == "/1/validate-token")
                return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"listener"})", {}};
            if (r.body.contains("Kaputt"))
                return FakeListenBrainz::Reply{400, R"({"code":400,"error":"Invalid listen"})", {}};
            return FakeListenBrainz::Reply{};
        };
        s->signIn(kToken);
        QTRY_COMPARE(s->queuedCount(), 0);
        QCOMPARE(server.listensTaken(), 2);
        // Lost for good, so it is still said after the sends that worked.
        QVERIFY(s->lastError().contains(QStringLiteral("Kaputt")));
    }

    // More than a batch holds goes out in several, oldest first.
    void aLongQueueGoesOutInBatches() {
        FakeListenBrainz server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.answer = FakeListenBrainz::failing(503);
        const int n = ListenBrainz::kMaxBatch * 2 + 5;
        for (int i = 1; i <= n; ++i) { Listen l = track(i, 200); l.listenedAt = 1'700'000'000 + i; s->add(l); }
        QTRY_COMPARE(s->queuedCount(), n);
        QTRY_VERIFY(!s->lastError().isEmpty());
        server.answer = [](const FakeListenBrainz::Request &r) {
            if (r.path == "/1/validate-token")
                return FakeListenBrainz::Reply{200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"listener"})", {}};
            return FakeListenBrainz::Reply{};
        };
        server.seen.clear();
        s->signIn(kToken);
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        const auto submits = server.submits();
        QCOMPARE(submits.size(), 3);
        QCOMPARE(submits.at(0).json().value("payload").toArray().size(), ListenBrainz::kMaxBatch);
        QCOMPARE(submits.at(2).json().value("payload").toArray().size(), 5);
        QCOMPARE(submits.at(0).json().value("payload").toArray().at(0).toObject()
                     .value("listened_at").toInteger(), qint64(1'700'000'001));
    }

    // ── the player ───────────────────────────────────────────────────────
#ifdef Q_OS_LINUX
    // Casting counts as local play does, a repeat counts twice, and a track
    // skipped early does not count. The device is a CastSession that never
    // connects; its reports are handed to the player by hand.
    void castingCountsAndARepeatCountsTwice() {
        TidalApi api;
        QuietClient client{&api};
        Player p{&client};
        QTest::qWait(30);
        Scrobbler scrobbler;
        QSignalSpy listened(scrobbler.tracker(), &PlayTracker::listened);
        QSignalSpy started(scrobbler.tracker(), &PlayTracker::started);
        scrobbler.attach(&p);

        p.playTracks(rows(), 0);
        CastSession device;
        p.beginCast(&device);
        p.onCastPlaying(true);
        for (int s = 0; s <= 100; ++s) p.onCastPosition(s);
        QCOMPARE(listened.count(), 1);
        QCOMPARE(listened.at(0).at(0).value<Listen>().trackId, qint64(1));
        QCOMPARE(listened.at(0).at(0).value<Listen>().title, QStringLiteral("T1"));

        // Repeat-one: the device plays it out and the track starts over.
        p.setRepeatMode(2);
        for (int s = 101; s <= 200; ++s) p.onCastPosition(s);
        p.onCastFinished();
        for (int s = 0; s <= 100; ++s) p.onCastPosition(s);
        QCOMPARE(listened.count(), 2);

        // On to the next track and away from it after 20 s.
        p.setRepeatMode(0);
        p.next();
        for (int s = 0; s <= 20; ++s) p.onCastPosition(s);
        p.next();
        for (int s = 0; s <= 10; ++s) p.onCastPosition(s);
        QCOMPARE(listened.count(), 2);
        QCOMPARE(started.count(), 4);
        p.endCast();
    }
#endif

private:
    class QuietClient : public TidalClient {
    public:
        using TidalClient::TidalClient;
        void fetchStreamManifest(qint64, StreamCb) override {}
    };

    static QVariantList rows() {
        QVariantList out;
        for (qlonglong id = 1; id <= 3; ++id) {
            QVariantMap t;
            t[QStringLiteral("id")]         = id;
            t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
            t[QStringLiteral("artists")]    = QStringLiteral("Artist");
            t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
            t[QStringLiteral("duration")]   = 200;
            out.append(t);
        }
        return out;
    }
};

QTEST_GUILESS_MAIN(TestScrobble)
#include "tst_scrobble.moc"
