// Last.fm scrobbling: api_sig and the form as the docs give them, the desktop
// sign-in through the browser, and the answers to Last.fm's error codes. Also
// both services at once, each with its own queue. Every request goes to a
// server on loopback, signed with an invented key; nothing reaches last.fm.

#include <QTest>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <algorithm>
#include <functional>
#include <memory>

#include "scrobble/LastFm.h"
#include "scrobble/ListenBrainz.h"
#include "scrobble/PlayTracker.h"
#include "scrobble/ScrobbleSink.h"
#include "scrobble/Scrobbler.h"

namespace {

// All invented.
const QString kKey     = QStringLiteral("0123456789abcdef-test-key");
const QString kSecret  = QStringLiteral("fedcba9876543210-test-secret");
const QString kToken   = QStringLiteral("req-token-5e1f");
const QString kSession = QStringLiteral("sess-key-9a7c");
const QString kUser    = QStringLiteral("listener");

Listen track(qint64 id, int seconds, const QString &title = QStringLiteral("Weit weg")) {
    Listen l;
    l.trackId     = id;
    l.artist      = QStringLiteral("Erika Mustermann");
    l.title       = title;
    l.album       = QStringLiteral("Nachtfahrt");
    l.durationMs  = qint64(seconds) * 1000;
    l.trackNumber = 4;
    l.isrc        = QStringLiteral("XX0000000001");
    l.listenedAt  = 1'700'000'000 + id;
    return l;
}

QString md5(const QByteArray &text) {
    return QString::fromLatin1(QCryptographicHash::hash(text, QCryptographicHash::Md5).toHex());
}

// A form body as a server decodes it.
QList<QPair<QString, QString>> parseForm(const QByteArray &body) {
    QList<QPair<QString, QString>> out;
    for (const QByteArray &item : body.split('&')) {
        if (item.isEmpty()) continue;
        const qsizetype eq = item.indexOf('=');
        out << qMakePair(QUrl::fromPercentEncoding(item.left(eq)),
                         QUrl::fromPercentEncoding(eq < 0 ? QByteArray() : item.mid(eq + 1)));
    }
    return out;
}

// An HTTP server on loopback. Each request is recorded; `answer` picks the reply.
class FakeHttp : public QTcpServer {
public:
    struct Request {
        QByteArray verb, path, auth, body;
        QString param(const QString &name) const {
            for (const auto &p : parseForm(body)) if (p.first == name) return p.second;
            return {};
        }
        QString method() const { return param(QStringLiteral("method")); }
        // Signed as the docs say, worked out here on its own.
        bool signedWith(const QString &secret) const {
            QList<QPair<QString, QString>> items = parseForm(body);
            std::sort(items.begin(), items.end());
            QByteArray text;
            for (const auto &p : items)
                if (p.first != QLatin1String("api_sig") && p.first != QLatin1String("format"))
                    text += p.first.toUtf8() + p.second.toUtf8();
            return param(QStringLiteral("api_sig")) == md5(text + secret.toUtf8());
        }
    };
    struct Reply {
        int status = 200;
        QByteArray body = "{}";
    };

    std::function<Reply(const Request &)> answer;
    QList<Request> seen;

    FakeHttp() {
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
                    const Reply a = answer ? answer(r) : Reply{};
                    seen << r;
                    QByteArray out = "HTTP/1.0 " + QByteArray::number(a.status) + " Answer\r\n"
                                     "Content-Type: application/json\r\n"
                                     "Content-Length: " + QByteArray::number(a.body.size()) + "\r\n\r\n" + a.body;
                    sock->write(out);
                    sock->flush();
                    sock->disconnectFromHost();
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
        if (!listen(QHostAddress::LocalHost)) qFatal("no loopback server");
    }

    QUrl base() const { return QUrl(QStringLiteral("http://127.0.0.1:%1/2.0/").arg(serverPort())); }

    QList<Request> calls(const QString &method) const {
        QList<Request> out;
        for (const Request &r : seen) if (r.method() == method) out << r;
        return out;
    }
    // Scrobbles in the calls Last.fm took.
    int scrobblesTaken = 0;
};

// Last.fm as the docs describe it: a token, a session once allowed, and
// every scrobble taken. `allowed` is the user's yes in the browser.
struct FakeLastFm {
    FakeHttp http;
    bool allowed = true;
    QString user = kUser;
    // Answers track.scrobble and track.updateNowPlaying when set.
    std::function<FakeHttp::Reply(const FakeHttp::Request &)> tracks;

    FakeLastFm() {
        http.answer = [this](const FakeHttp::Request &r) -> FakeHttp::Reply {
            if (!r.signedWith(kSecret) || r.param(QStringLiteral("api_key")) != kKey)
                return {403, R"({"error":13,"message":"Invalid method signature supplied"})"};
            const QString m = r.method();
            if (m == QLatin1String("auth.getToken"))
                return {200, ("{\"token\":\"" + kToken + "\"}").toUtf8()};
            if (m == QLatin1String("auth.getSession")) {
                if (!allowed)
                    return {403, R"({"error":14,"message":"This token has not been authorized"})"};
                return {200, ("{\"session\":{\"name\":\"" + user + "\",\"key\":\"" + kSession
                              + "\",\"subscriber\":0}}").toUtf8()};
            }
            if (tracks) return tracks(r);
            if (m == QLatin1String("track.scrobble")) {
                int n = 0;
                while (!r.param(QStringLiteral("artist[%1]").arg(n)).isEmpty()) ++n;
                http.scrobblesTaken += n;
                return {200, QStringLiteral(R"({"scrobbles":{"@attr":{"accepted":%1,"ignored":0}}})")
                                 .arg(n).toUtf8()};
            }
            return {200, R"({"nowplaying":{}})"};
        };
    }
    static FakeHttp::Reply error(int code, int status = 200) {
        return {status, QStringLiteral(R"({"error":%1,"message":"Said by the fake"})").arg(code).toUtf8()};
    }
};

QStringList g_log;
QtMessageHandler g_previous = nullptr;
void keepLog(QtMsgType type, const QMessageLogContext &ctx, const QString &msg) {
    g_log << msg;
    if (g_previous) g_previous(type, ctx, msg);
}

} // namespace

class TestLastFm : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

    ScrobbleSink::Paths paths(const QString &key = QStringLiteral("lastfm")) const {
        return { m_dir.filePath(QStringLiteral("config/scrobbling-%1.json").arg(key)),
                 m_dir.filePath(QStringLiteral("data/scrobble-queue-%1.json").arg(key)) };
    }

    std::unique_ptr<ScrobbleSink> sink(FakeLastFm &server, int retryMs = 100) {
        auto *fm = new LastFm;
        fm->setBaseUrl(server.http.base());
        fm->setAppCredentials(kKey, kSecret);
        auto s = std::make_unique<ScrobbleSink>(fm, paths());
        s->setTimingForTest(10, retryMs);
        s->setEnabled(true);
        return s;
    }

    // Through the browser and back, with the user's yes.
    std::unique_ptr<ScrobbleSink> connectedSink(FakeLastFm &server, int retryMs = 100) {
        auto s = sink(server, retryMs);
        s->startBrowserSignIn();
        if (!QTest::qWaitFor([&] { return s->awaitingBrowser(); }, 5000)) return nullptr;
        s->finishBrowserSignIn();
        if (!QTest::qWaitFor([&] { return s->connected(); }, 5000)) return nullptr;
        server.http.seen.clear();
        return s;
    }

private slots:
    void initTestCase() {
        QVERIFY(m_dir.isValid());
        qputenv("HOME", m_dir.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", m_dir.filePath(QStringLiteral(".config")).toUtf8());
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_lastfm"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
        g_previous = qInstallMessageHandler(keepLog);
    }

    void init() {
        for (const QString &key : {QStringLiteral("lastfm"), QStringLiteral("listenbrainz")}) {
            QFile::remove(paths(key).secret);
            QFile::remove(paths(key).queue);
        }
        QSettings().clear();
    }

    // Neither the session key nor the shared secret is ever logged.
    void cleanup() {
        for (const QString &line : std::as_const(g_log)) {
            QVERIFY2(!line.contains(kSession), qPrintable("the session key was logged: " + line));
            QVERIFY2(!line.contains(kSecret), qPrintable("the shared secret was logged: " + line));
        }
        g_log.clear();
    }

    // ── the request, against the docs ────────────────────────────────────

    // https://www.last.fm/api/authspec, section 8: sorted by name, name and
    // value run together, the secret on the end, md5 in hex.
    void theSignatureIsTheDocumentedMd5() {
        const LastFm::Params p = {
            {QStringLiteral("method"), QStringLiteral("auth.getSession")},
            {QStringLiteral("token"), QStringLiteral("t0k")},
            {QStringLiteral("api_key"), QStringLiteral("k3y")},
            {QStringLiteral("format"), QStringLiteral("json")},
        };
        QCOMPARE(LastFm::signature(p, QStringLiteral("s3cret")),
                 md5("api_keyk3ymethodauth.getSessiontokent0ks3cret"));
    }

    // Non-ASCII is signed as UTF-8, and indexed names sort as text.
    void theSignatureTakesUtf8AndIndexedNames() {
        const LastFm::Params p = {
            {QStringLiteral("track[1]"), QStringLiteral("B")},
            {QStringLiteral("artist[0]"), QStringLiteral("Mötley")},
            {QStringLiteral("track[0]"), QStringLiteral("A")},
        };
        QCOMPARE(LastFm::signature(p, QStringLiteral("s")),
                 md5(QStringLiteral("artist[0]Mötleytrack[0]Atrack[1]Bs").toUtf8()));
    }

    // '+' and '&' in a title survive the form.
    void theFormEncodesWhatAFormDecoderWouldMisread() {
        const QByteArray body = LastFm::formBody({{QStringLiteral("track[0]"), QStringLiteral("A+B & C/D")}});
        QCOMPARE(body, QByteArray("track%5B0%5D=A%2BB%20%26%20C%2FD"));
        QCOMPARE(parseForm(body).value(0).second, QStringLiteral("A+B & C/D"));
    }

    void aBatchIsIndexedAndLeavesOutWhatIsNotKnown() {
        Listen bare;
        bare.trackId = 2; bare.artist = QStringLiteral("A"); bare.title = QStringLiteral("T");
        bare.listenedAt = 1'700'000'500;
        const LastFm::Params p = LastFm::scrobbleParams({track(1, 215), bare});
        const auto value = [&p](const QString &name) {
            for (const auto &e : p) if (e.first == name) return e.second;
            return QStringLiteral("<none>");
        };
        QCOMPARE(value("artist[0]"), QStringLiteral("Erika Mustermann"));
        QCOMPARE(value("track[0]"), QStringLiteral("Weit weg"));
        QCOMPARE(value("album[0]"), QStringLiteral("Nachtfahrt"));
        QCOMPARE(value("timestamp[0]"), QStringLiteral("1700000001"));
        QCOMPARE(value("trackNumber[0]"), QStringLiteral("4"));
        // Seconds, as the docs ask.
        QCOMPARE(value("duration[0]"), QStringLiteral("215"));
        QCOMPARE(value("artist[1]"), QStringLiteral("A"));
        QCOMPARE(value("timestamp[1]"), QStringLiteral("1700000500"));
        for (const char *name : {"album[1]", "trackNumber[1]", "duration[1]"})
            QCOMPARE(value(QLatin1String(name)), QStringLiteral("<none>"));
    }

    void playingNowCarriesNoTimestamp() {
        const LastFm::Params p = LastFm::nowPlayingParams(track(1, 200));
        for (const auto &e : p) QVERIFY2(!e.first.startsWith(QLatin1String("timestamp")), qPrintable(e.first));
        QVERIFY(p.contains(qMakePair(QStringLiteral("artist"), QStringLiteral("Erika Mustermann"))));
        QVERIFY(p.contains(qMakePair(QStringLiteral("duration"), QStringLiteral("200"))));
    }

    void theAuthPageCarriesKeyAndToken() {
        const QUrl url = LastFm::authPage(QStringLiteral("k3y"), QStringLiteral("t0k"));
        QCOMPARE(url.scheme(), QStringLiteral("https"));
        QCOMPARE(url.host(), QStringLiteral("www.last.fm"));
        QCOMPARE(url.path(), QStringLiteral("/api/auth/"));
        const QUrlQuery q(url);
        QCOMPARE(q.queryItemValue(QStringLiteral("api_key")), QStringLiteral("k3y"));
        QCOMPARE(q.queryItemValue(QStringLiteral("token")), QStringLiteral("t0k"));
    }

    // The app's own key is in the source, and a real one, not a placeholder.
    void theAppKeyIsBuiltIn() {
        QVERIFY(LastFm::hasAppKey());
    }

    void classify_data() {
        QTest::addColumn<int>("status");
        QTest::addColumn<QByteArray>("body");
        QTest::addColumn<int>("kind");
        QTest::newRow("ok")                << 200 << QByteArray(R"({"scrobbles":{}})") << int(ScrobbleReply::Ok);
        QTest::newRow("no answer")         << 0   << QByteArray() << int(ScrobbleReply::Retry);
        QTest::newRow("503, no body")      << 503 << QByteArray() << int(ScrobbleReply::Retry);
        QTest::newRow("9 invalid session") << 403 << QByteArray(R"({"error":9,"message":"m"})") << int(ScrobbleReply::AuthFailed);
        QTest::newRow("11 offline")        << 503 << QByteArray(R"({"error":11,"message":"m"})") << int(ScrobbleReply::Retry);
        QTest::newRow("16 unavailable")    << 200 << QByteArray(R"({"error":16,"message":"m"})") << int(ScrobbleReply::Retry);
        QTest::newRow("29 rate limit")     << 429 << QByteArray(R"({"error":29,"message":"m"})") << int(ScrobbleReply::Retry);
        QTest::newRow("8 operation failed")<< 200 << QByteArray(R"({"error":8,"message":"m"})") << int(ScrobbleReply::Retry);
        QTest::newRow("6 bad parameters")  << 400 << QByteArray(R"({"error":6,"message":"m"})") << int(ScrobbleReply::Rejected);
        QTest::newRow("14 not allowed yet")<< 403 << QByteArray(R"({"error":14,"message":"m"})") << int(ScrobbleReply::Pending);
        QTest::newRow("15 token expired")  << 403 << QByteArray(R"({"error":15,"message":"m"})") << int(ScrobbleReply::AuthFailed);
    }
    void classify() {
        QFETCH(int, status);
        QFETCH(QByteArray, body);
        QFETCH(int, kind);
        QCOMPARE(int(LastFm::classify(status, body).kind), kind);
    }

    // ── the sign-in ──────────────────────────────────────────────────────

    void theDefaultPlaceIsBesideListenBrainz() {
        const ScrobbleSink::Paths fm = ScrobbleSink::defaultPaths(QStringLiteral("lastfm"));
        const ScrobbleSink::Paths lb = ScrobbleSink::defaultPaths(QStringLiteral("listenbrainz"));
        QCOMPARE(QFileInfo(fm.secret).fileName(), QStringLiteral("scrobbling-lastfm.json"));
        QCOMPARE(QFileInfo(fm.queue).fileName(), QStringLiteral("scrobble-queue-lastfm.json"));
        QCOMPARE(QFileInfo(fm.secret).absolutePath(), QFileInfo(lb.secret).absolutePath());
    }

    // A token, the browser at the page that allows it, and once the user
    // says so the session, kept owner-only with the name it belongs to.
    void theBrowserSignInKeepsTheSession() {
        FakeLastFm server;
        auto s = sink(server);
        QVERIFY(s->browserSignIn());
        QSignalSpy opened(s.get(), &ScrobbleSink::openPage);
        s->startBrowserSignIn();
        QVERIFY(s->checking());
        QTRY_VERIFY(s->awaitingBrowser());
        QVERIFY(!s->checking());
        QCOMPARE(opened.count(), 1);
        const QUrl page = opened.at(0).at(0).toUrl();
        QCOMPARE(page, LastFm::authPage(kKey, kToken));
        QCOMPARE(QUrl(s->signInPage()), page);
        QCOMPARE(server.http.seen.size(), 1);
        QCOMPARE(server.http.seen.at(0).verb, QByteArray("POST"));
        QCOMPARE(server.http.seen.at(0).method(), QStringLiteral("auth.getToken"));
        QCOMPARE(server.http.seen.at(0).param("format"), QStringLiteral("json"));
        QVERIFY(server.http.seen.at(0).signedWith(kSecret));

        s->finishBrowserSignIn();
        QTRY_VERIFY(s->connected());
        QVERIFY(!s->awaitingBrowser());
        QCOMPARE(s->userName(), kUser);
        const auto session = server.http.calls(QStringLiteral("auth.getSession"));
        QCOMPARE(session.size(), 1);
        QCOMPARE(session.at(0).param("token"), kToken);
        QVERIFY(QFile::exists(paths().secret));
        QCOMPARE(QFile::permissions(paths().secret),
                 QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ReadUser | QFileDevice::WriteUser);
        QFile f(paths().secret);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QVERIFY(f.readAll().contains(kSession.toUtf8()));
        // A second start reads it back.
        s.reset();
        auto again = sink(server);
        QVERIFY(again->connected());
        QCOMPARE(again->userName(), kUser);
    }

    // "I've allowed access" before the yes: still waiting, and the status
    // says what is missing.
    void finishingBeforeTheYesKeepsWaiting() {
        FakeLastFm server;
        server.allowed = false;
        auto s = sink(server);
        s->startBrowserSignIn();
        QTRY_VERIFY(s->awaitingBrowser());
        s->finishBrowserSignIn();
        QTRY_VERIFY(!s->checking());
        QVERIFY(s->awaitingBrowser());
        QVERIFY(!s->connected());
        QVERIFY(!s->lastError().isEmpty());
        server.allowed = true;
        s->finishBrowserSignIn();
        QTRY_VERIFY(s->connected());
        QVERIFY(s->lastError().isEmpty());
    }

    void cancelEndsTheSignIn() {
        FakeLastFm server;
        auto s = sink(server);
        s->startBrowserSignIn();
        QTRY_VERIFY(s->awaitingBrowser());
        s->cancelBrowserSignIn();
        QVERIFY(!s->awaitingBrowser());
        QVERIFY(s->signInPage().isEmpty());
        s->finishBrowserSignIn();
        QTest::qWait(100);
        QVERIFY(!s->connected());
        QCOMPARE(server.http.calls(QStringLiteral("auth.getSession")).size(), 0);
    }

    // ── sending ──────────────────────────────────────────────────────────

    void aListenIsScrobbledWithTheSession() {
        FakeLastFm server;
        auto s = connectedSink(server);
        QVERIFY(s);
        s->nowPlaying(track(1, 200));
        QTRY_COMPARE(server.http.calls(QStringLiteral("track.updateNowPlaying")).size(), 1);
        s->add(track(1, 200));
        QTRY_COMPARE(s->queuedCount(), 0);
        const auto sent = server.http.calls(QStringLiteral("track.scrobble"));
        QCOMPARE(sent.size(), 1);
        QCOMPARE(sent.at(0).param("sk"), kSession);
        QCOMPARE(sent.at(0).param("timestamp[0]"), QStringLiteral("1700000001"));
        QVERIFY(sent.at(0).signedWith(kSecret));
        QCOMPARE(server.http.calls(QStringLiteral("track.updateNowPlaying")).at(0).param("sk"), kSession);
    }

    // At most 50 per call, oldest first.
    void aLongQueueGoesOutInFifties() {
        FakeLastFm server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.tracks = [](const FakeHttp::Request &) { return FakeLastFm::error(16); };
        for (int i = 1; i <= 120; ++i) s->add(track(i, 200));
        QTRY_COMPARE(s->queuedCount(), 120);
        QTRY_VERIFY(!s->lastError().isEmpty());
        server.tracks = nullptr;
        server.http.seen.clear();
        s->setTimingForTest(10, 50);
        s->disconnectAccount();
        s->startBrowserSignIn();
        QTRY_VERIFY(s->awaitingBrowser());
        s->finishBrowserSignIn();
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        const auto sent = server.http.calls(QStringLiteral("track.scrobble"));
        QCOMPARE(sent.size(), 3);
        QVERIFY(!sent.at(0).param("artist[49]").isEmpty());
        QVERIFY(sent.at(0).param("artist[50]").isEmpty());
        QCOMPARE(sent.at(0).param("timestamp[0]"), QStringLiteral("1700000001"));
        QVERIFY(!sent.at(2).param("artist[19]").isEmpty());
        QVERIFY(sent.at(2).param("artist[20]").isEmpty());
        QCOMPARE(server.http.scrobblesTaken, 120);
    }

    // 11 and 16: the listens wait and go out on a later try.
    void offlineAndUnavailableAreRetried_data() {
        QTest::addColumn<int>("code");
        QTest::newRow("11") << 11;
        QTest::newRow("16") << 16;
    }
    void offlineAndUnavailableAreRetried() {
        QFETCH(int, code);
        FakeLastFm server;
        auto s = connectedSink(server, 100);
        QVERIFY(s);
        int fails = 2;
        server.tracks = [&fails, &server, code](const FakeHttp::Request &) {
            if (fails-- > 0) return FakeLastFm::error(code, 503);
            server.http.scrobblesTaken += 1;
            return FakeHttp::Reply{200, R"({"scrobbles":{"@attr":{"accepted":1,"ignored":0}}})"};
        };
        s->add(track(1, 200));
        QTRY_VERIFY(!s->lastError().isEmpty());
        QCOMPARE(s->queuedCount(), 1);
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        QCOMPARE(server.http.calls(QStringLiteral("track.scrobble")).size(), 3);
        QVERIFY(s->lastError().isEmpty());
    }

    // Any other error drops the listen it was about, and only that one.
    void anotherErrorDropsTheListenAlone() {
        FakeLastFm server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.tracks = [](const FakeHttp::Request &) { return FakeLastFm::error(16); };
        s->add(track(1, 200, QStringLiteral("Gut")));
        s->add(track(2, 200, QStringLiteral("Kaputt")));
        s->add(track(3, 200, QStringLiteral("Auch gut")));
        QTRY_VERIFY(!s->lastError().isEmpty());
        server.tracks = [&server](const FakeHttp::Request &r) {
            if (r.body.contains("Kaputt")) return FakeLastFm::error(6, 400);
            int n = 0;
            while (!r.param(QStringLiteral("artist[%1]").arg(n)).isEmpty()) ++n;
            server.http.scrobblesTaken += n;
            return FakeHttp::Reply{200, R"({"scrobbles":{}})"};
        };
        // Connecting again starts the sending at once.
        s->setTimingForTest(10, 50);
        s->disconnectAccount();
        s->startBrowserSignIn();
        QTRY_VERIFY(s->awaitingBrowser());
        s->finishBrowserSignIn();
        QTRY_COMPARE_WITH_TIMEOUT(s->queuedCount(), 0, 10000);
        QCOMPARE(server.http.scrobblesTaken, 2);
        QVERIFY(s->lastError().contains(QStringLiteral("Kaputt")));
    }

    // 9: the session is gone. The account is disconnected and the user told;
    // the listens wait for the same account to connect again.
    void anInvalidSessionDisconnects() {
        FakeLastFm server;
        auto s = connectedSink(server, 60'000);
        QVERIFY(s);
        server.tracks = [](const FakeHttp::Request &) { return FakeLastFm::error(9, 403); };
        s->add(track(1, 200));
        QTRY_VERIFY(!s->connected());
        QVERIFY(!QFile::exists(paths().secret));
        QCOMPARE(s->queuedCount(), 1);
        QVERIFY(!s->lastError().isEmpty());
        QVERIFY(s->statusText().contains(s->lastError()));
        server.tracks = nullptr;
        s->startBrowserSignIn();
        QTRY_VERIFY(s->awaitingBrowser());
        s->finishBrowserSignIn();
        QTRY_COMPARE(s->queuedCount(), 0);
        QCOMPARE(server.http.scrobblesTaken, 1);
        QVERIFY(s->lastError().isEmpty());
    }

    // ── both at once ─────────────────────────────────────────────────────

    // One play reaches both services, and each keeps its own queue: one
    // that is down holds nothing back at the other.
    void bothServicesGetEveryListen() {
        FakeLastFm fmServer;
        FakeHttp lbServer;
        lbServer.answer = [](const FakeHttp::Request &r) -> FakeHttp::Reply {
            if (r.path == "/1/validate-token")
                return {200, R"({"code":200,"message":"Token valid.","valid":true,"user_name":"listener"})"};
            return {503, "{}"};
        };
        auto fm = connectedSink(fmServer);
        QVERIFY(fm);
        auto *lb = new ListenBrainz;
        lb->setBaseUrl(QUrl(QStringLiteral("http://127.0.0.1:%1").arg(lbServer.serverPort())));
        ScrobbleSink lbSink(lb, paths(QStringLiteral("listenbrainz")));
        lbSink.setTimingForTest(10, 60'000);
        lbSink.setEnabled(true);
        lbSink.signIn(QStringLiteral("lb-token"));
        QTRY_VERIFY(lbSink.connected());

        Scrobbler scrobbler;
        scrobbler.addSink(fm.get());
        scrobbler.addSink(&lbSink);
        PlayTracker *t = scrobbler.tracker();
        t->setTrack(track(1, 200));
        t->setPlaying(true, 0);
        for (qint64 p = 0, clock = 0; p <= 100000; p += 500, clock += 500)
            t->position(p, clock, 1'700'000'000 + clock / 1000);

        QTRY_COMPARE(fmServer.http.scrobblesTaken, 1);
        QTRY_COMPARE(fm->queuedCount(), 0);
        QTRY_VERIFY(!lbSink.lastError().isEmpty());
        QCOMPARE(lbSink.queuedCount(), 1);
        QVERIFY(QFile::exists(paths(QStringLiteral("listenbrainz")).queue));
        QVERIFY(!QFile::exists(paths().queue));
        QCOMPARE(fmServer.http.calls(QStringLiteral("track.updateNowPlaying")).size(), 1);
    }
};

QTEST_GUILESS_MAIN(TestLastFm)
#include "tst_lastfm.moc"
