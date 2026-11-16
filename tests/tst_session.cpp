// A signed-in session whose access token runs out while the program lives:
// after a suspend, after the clock was set, in the last minute before the
// expiry, and when the server refuses the token first. Everything is served
// from loopback and the home directory is a scratch one.

#include <QTest>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QSet>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QTimerEvent>
#include <QUrlQuery>
#include <functional>
#include <memory>
#include <utility>

#include "api/Auth.h"
#include "api/TidalApi.h"

namespace {

const QByteArray kExpired =
    R"j({"status":401,"subStatus":11003,"userMessage":"The token has expired. (Expired on time)"})j";

// Tidal on loopback: the login host under /auth/, the API under /api/, a
// media host under /media/. The API takes the tokens in goodTokens.
class FakeTidal : public QTcpServer {
public:
    struct Seen { QByteArray verb; QString path; QByteArray bearer; QByteArray body; };
    enum TokenAnswer { Issue, Refuse, Hold, BadGateway, RateLimited, Unavailable };

    FakeTidal()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    const qsizetype end = buf->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    const QList<QByteArray> lines = buf->left(end).split('\n');
                    Seen seen;
                    qsizetype length = 0;
                    for (const QByteArray &raw : lines.mid(1)) {
                        const QByteArray line = raw.trimmed();
                        const QByteArray name = line.left(line.indexOf(':')).toLower();
                        const QByteArray value = line.mid(line.indexOf(':') + 1).trimmed();
                        if (name == "content-length") length = value.toLongLong();
                        if (name == "authorization") seen.bearer = value.mid(7);
                    }
                    if (buf->size() < end + 4 + length) return;
                    const QList<QByteArray> request = lines.first().trimmed().split(' ');
                    const QString target = QString::fromUtf8(request.value(1));
                    seen.verb = request.value(0);
                    seen.path = target.left(target.indexOf(QLatin1Char('?')));
                    seen.body = buf->mid(end + 4);
                    buf->clear();
                    serve(sock, seen);
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }

    // The requests for `path`, in the order they came.
    QList<Seen> seenFor(const QString &path) const
    {
        QList<Seen> out;
        for (const Seen &s : api)
            if (s.path == path) out << s;
        return out;
    }

    void releaseProfiles()
    {
        for (const QPointer<QTcpSocket> &sock : std::exchange(heldProfiles, {}))
            if (sock) answer(sock, 200, R"({"userId":7,"countryCode":"DE","firstName":"Robin"})");
    }

    // Answers the token requests that Hold kept waiting.
    void release()
    {
        for (QTcpSocket *sock : std::exchange(held, {})) issue(sock);
    }

    QSet<QByteArray> goodTokens{"old"};
    bool        issuedTokensAreGood = true;
    bool        refuseAll = false;      // 401 for a good token as well
    QByteArray  refusal = kExpired;
    TokenAnswer tokenAnswer = Issue;
    // The profile answer waits for releaseProfiles(), or comes this late.
    bool        holdProfile = false;
    int         profileDelayMs = 0;
    int         tokenRequests = 0;
    int         refused = 0;            // 401 answers given by the API
    QList<Seen> api;

private:
    void serve(QTcpSocket *sock, const Seen &seen)
    {
        if (seen.path.startsWith(QLatin1String("/auth/"))) {
            ++tokenRequests;
            switch (tokenAnswer) {
            case Hold:   held << sock; return;
            // What a proxy says when the login host cannot be reached.
            case BadGateway: answer(sock, 502, "<html>Bad Gateway</html>"); return;
            case Refuse: answer(sock, 400, R"({"error":"invalid_grant","error_description":"gone"})"); return;
            // Busy or down, said in the login host's own JSON.
            case RateLimited:
                answer(sock, 429, R"({"error":"too_many_requests","error_description":"slow down"})",
                       "Retry-After: 1\r\n");
                return;
            case Unavailable:
                answer(sock, 503, R"({"error":"server_error","error_description":"down"})");
                return;
            case Issue:  issue(sock); return;
            }
        }
        api << seen;
        if (!refuseAll && goodTokens.contains(seen.bearer)) {
            const QByteArray body = R"({"userId":7,"countryCode":"DE","firstName":"Robin"})";
            const bool profile = seen.path.startsWith(QLatin1String("/api/users/"));
            if (profile && holdProfile)
                heldProfiles << sock;
            else if (profile && profileDelayMs > 0)
                QTimer::singleShot(profileDelayMs, sock, [sock, body] { answer(sock, 200, body); });
            else
                answer(sock, 200, body);
        } else {
            ++refused;
            answer(sock, 401, refusal);
        }
    }

    void issue(QTcpSocket *sock)
    {
        const QByteArray n = QByteArray::number(++m_issued);
        const QByteArray token = "token-" + n;
        if (issuedTokensAreGood) goodTokens << token;
        answer(sock, 200, "{\"access_token\":\"token-" + n + "\",\"refresh_token\":\"refresh-"
                              + n + "\",\"expires_in\":3600}");
    }

    static void answer(QTcpSocket *sock, int status, const QByteArray &body,
                       const QByteArray &extra = {})
    {
        sock->write("HTTP/1.0 " + QByteArray::number(status) + " Answer\r\n" + extra +
                    "Content-Type: application/json\r\nETag: \"e1\"\r\n"
                    "Content-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
        sock->flush();
        sock->disconnectFromHost();
    }

    QList<QTcpSocket *> held;
    QList<QPointer<QTcpSocket>> heldProfiles;
    int m_issued = 0;
};

// The real TidalApi with every host on the local server.
class LocalApi : public TidalApi {
public:
    QString local;
    bool    tokens = true;   // false: the server is a host that takes none

protected:
    QString baseUrl(const QString &base) const override
    {
        return local + (base == QLatin1String(kAuthBase) ? QLatin1String("auth/")
                                                         : QLatin1String("api/"));
    }
    bool takesTokens(const QUrl &url) const override
    {
        return tokens && url.path().startsWith(QLatin1String("/api/"));
    }
};

// The real Auth with a wall clock the test can move.
class ClockedAuth : public Auth {
public:
    using Auth::Auth;
    qint64 aheadSecs = 0;

protected:
    QDateTime now() const override
    {
        return QDateTime::currentDateTimeUtc().addSecs(aheadSecs);
    }
};

// Auth's running timer that is due first, or nullptr.
QTimer *nextTimer(const Auth &auth)
{
    QTimer *next = nullptr;
    const auto timers = auth.findChildren<QTimer *>(QString(), Qt::FindDirectChildrenOnly);
    for (QTimer *t : timers)
        if (t->isActive() && (!next || t->remainingTime() < next->remainingTime())) next = t;
    return next;
}

// What that timer does when it is due, without the wait.
void wakeUp(const Auth &auth)
{
    QTimer *t = nextTimer(auth);
    QVERIFY2(t, "no timer is running");
    QTimerEvent due(t->timerId());
    QCoreApplication::sendEvent(t, &due);
}

struct Rig {
    FakeTidal   tidal;
    LocalApi    api;
    ClockedAuth auth{&api};

    Rig()
    {
        if (!tidal.listen(QHostAddress::LocalHost)) qFatal("no loopback server");
        api.local = tidal.base();
    }

    // One request of each kind TidalApi has. done() gets the error.
    void send(const QString &kind, std::function<void(QString)> done)
    {
        const auto json = [done](QJsonObject, QString err) { done(err); };
        const auto status = [done](QJsonObject, QString err, int) { done(err); };
        QUrlQuery form;
        form.addQueryItem(QStringLiteral("trackIds"), QStringLiteral("1"));
        const QString etag = QStringLiteral("\"e1\"");
        if (kind == QLatin1String("get")) api.get(QStringLiteral("x"), {}, json);
        else if (kind == QLatin1String("getV2")) api.getV2(QStringLiteral("x"), {}, json);
        else if (kind == QLatin1String("getOpenApi")) api.getOpenApi(QStringLiteral("x"), {}, json);
        else if (kind == QLatin1String("getWithStatus")) api.getWithStatus(QStringLiteral("x"), {}, status);
        else if (kind == QLatin1String("getOpenApiWithStatus")) api.getOpenApiWithStatus(QStringLiteral("x"), {}, status);
        else if (kind == QLatin1String("getArray"))
            api.getArray(QStringLiteral("x"), {}, [done](QJsonArray, QString err) { done(err); });
        else if (kind == QLatin1String("getEtag"))
            api.getEtag(QStringLiteral("x"), [done](QString tag, QString err) {
                done(err.isEmpty() && tag.isEmpty() ? QStringLiteral("no ETag") : err);
            });
        else if (kind == QLatin1String("putV2")) api.putV2(QStringLiteral("x"), form, json);
        else if (kind == QLatin1String("postApiForm")) api.postApiForm(QStringLiteral("x"), form, json);
        else if (kind == QLatin1String("postApiFormEtag")) api.postApiFormEtag(QStringLiteral("x"), form, etag, json);
        else if (kind == QLatin1String("deleteApiWithStatus"))
            api.deleteApiWithStatus(QStringLiteral("x"), form,
                                    [json](QJsonObject o, QString e, int) { json(o, e); });
        else if (kind == QLatin1String("deleteApiEtag")) api.deleteApiEtag(QStringLiteral("x"), form, etag, json);
        else qFatal("unknown kind of request");
    }
};

} // namespace

class TestSession : public QObject {
    Q_OBJECT

    std::unique_ptr<QTemporaryDir> m_home;
    QByteArray m_realHome;
    QByteArray m_realConfig;
    bool m_hadConfig = false;

    QString credsPath() const
    {
        return m_home->path() + QStringLiteral("/.config/tidal-wave/credentials.json");
    }

    QJsonObject savedCreds() const
    {
        QFile f(credsPath());
        if (!f.open(QIODevice::ReadOnly)) return {};
        return QJsonDocument::fromJson(f.readAll()).object();
    }

    // A saved session whose token "old" expires `inSecs` from now.
    void saveSession(qint64 inSecs)
    {
        QVERIFY(QDir(m_home->path()).mkpath(QStringLiteral(".config/tidal-wave")));
        QFile creds(credsPath());
        QVERIFY(creds.open(QIODevice::WriteOnly));
        creds.write(QJsonDocument(QJsonObject{
            {QStringLiteral("access_token"),  QStringLiteral("old")},
            {QStringLiteral("refresh_token"), QStringLiteral("refresh-old")},
            {QStringLiteral("expires_at"),
             Auth::expiryToString(QDateTime::fromSecsSinceEpoch(
                 QDateTime::currentSecsSinceEpoch() + inSecs))},
            {QStringLiteral("user_id"),       7},
            {QStringLiteral("country_code"),  QStringLiteral("DE")},
        }).toJson());
    }

    // Signs in from a saved session and waits until the start-up requests
    // (sessions, users/7) are answered.
    void signIn(Rig &rig, qint64 expiresInSecs = 3600)
    {
        saveSession(expiresInSecs);
        rig.auth.loadCredentials();
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QTRY_COMPARE_WITH_TIMEOUT(rig.tidal.seenFor(QStringLiteral("/api/users/7")).size(), 1, 5000);
        QTest::qWait(20);
        rig.tidal.api.clear();
    }

private slots:
    void init()
    {
        m_realHome = qgetenv("HOME");
        m_hadConfig = qEnvironmentVariableIsSet("XDG_CONFIG_HOME");
        m_realConfig = qgetenv("XDG_CONFIG_HOME");
        m_home = std::make_unique<QTemporaryDir>();
        QVERIFY(m_home->isValid());
        qputenv("HOME", m_home->path().toUtf8());
        // Both, or the credentials of the account on this machine are read,
        // written and deleted.
        qputenv("XDG_CONFIG_HOME", (m_home->path() + QStringLiteral("/.config")).toUtf8());
        QCOMPARE(QDir::homePath(), m_home->path());
    }

    void cleanup()
    {
        qputenv("HOME", m_realHome);
        if (m_hadConfig) qputenv("XDG_CONFIG_HOME", m_realConfig);
        else qunsetenv("XDG_CONFIG_HOME");
        m_home.reset();
    }

    // ── signing in ──────────────────────────────────────────────────────
    // A saved token that is still good: the session is checked behind it,
    // and that check must not announce the sign-in a second time, which
    // would load the whole library twice.
    void aSavedSessionSignsInOnce()
    {
        Rig rig;
        QSignalSpy signedIn(&rig.auth, &Auth::loginSucceeded);
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        QTest::qWait(100);
        QCOMPARE(signedIn.count(), 1);
    }

    // ── where the session is kept ───────────────────────────────────────
    // XDG_CONFIG_HOME is honoured, and a session saved by an earlier version
    // under ~/.config is still read, then moved.
    void theSessionIsKeptWhereTheDesktopKeepsSettings()
    {
        const QString elsewhere = m_home->path() + QStringLiteral("/xdg");
        qputenv("XDG_CONFIG_HOME", elsewhere.toUtf8());
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;

        const QString moved = elsewhere + QStringLiteral("/tidal-wave/credentials.json");
        QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(moved), 2000);
        QFile f(moved);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(QJsonDocument::fromJson(f.readAll()).object()[QStringLiteral("user_id")].toInt(), 7);
        QCOMPARE(QFileInfo(moved).permissions() & ~(QFileDevice::ReadUser | QFileDevice::WriteUser),
                 QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        QVERIFY2(!QFile::exists(credsPath()), "the old copy of the tokens was left behind");

        rig.auth.logout();
        QVERIFY(!QFile::exists(moved));
    }

    // ── the clock runs past the expiry while the process lives ──────────
    void theWallClockPassedTheExpiry_data()
    {
        QTest::addColumn<qint64>("jumpSecs");
        // A suspend and a clock that is set look the same from inside: the
        // wall clock is further on and no timer has counted the difference.
        QTest::newRow("the laptop slept eight hours")   << qint64(8) * 3600;
        QTest::newRow("the clock was set a day ahead")  << qint64(86400);
    }

    void theWallClockPassedTheExpiry()
    {
        QFETCH(qint64, jumpSecs);
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;

        rig.auth.aheadSecs = jumpSecs;
        rig.tidal.goodTokens.clear();

        QTimer *next = nextTimer(rig.auth);
        QVERIFY2(next && next->remainingTime() <= 60000,
                 qPrintable(QStringLiteral("the token is dead and is next looked at after %1 s "
                                           "of running time")
                                .arg(next ? next->remainingTime() / 1000 : -1)));
        wakeUp(rig.auth);
        QTRY_COMPARE_WITH_TIMEOUT(rig.auth.accessToken(), QStringLiteral("token-1"), 5000);
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(savedCreds()[QStringLiteral("access_token")].toString(), QStringLiteral("token-1"));
        QCOMPARE(savedCreds()[QStringLiteral("refresh_token")].toString(), QStringLiteral("refresh-1"));

        QString err = QStringLiteral("unanswered");
        rig.send(QStringLiteral("get"), [&err](QString e) { err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(err != QLatin1String("unanswered"), 5000);
        QVERIFY2(err.isEmpty(), qPrintable(err));
        QCOMPARE(rig.tidal.seenFor(QStringLiteral("/api/x")).size(), 1);
        QCOMPARE(rig.tidal.seenFor(QStringLiteral("/api/x")).first().bearer, QByteArray("token-1"));
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
    }

    // ── the server refuses the token before the clock says it is due ────
    // The state a clock that was set back leaves, and the first request
    // after a resume: an hour left by the clock, dead at the server.
    void aRequestRefusedForTheTokenIsSentAgain_data()
    {
        QTest::addColumn<QByteArray>("verb");
        for (const char *get : {"get", "getV2", "getOpenApi", "getWithStatus",
                                "getOpenApiWithStatus", "getArray", "getEtag"})
            QTest::newRow(get) << QByteArray("GET");
        QTest::newRow("putV2")           << QByteArray("PUT");
        QTest::newRow("postApiForm")     << QByteArray("POST");
        QTest::newRow("postApiFormEtag") << QByteArray("POST");
        QTest::newRow("deleteApiWithStatus") << QByteArray("DELETE");
        QTest::newRow("deleteApiEtag")   << QByteArray("DELETE");
    }

    void aRequestRefusedForTheTokenIsSentAgain()
    {
        QFETCH(QByteArray, verb);
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();

        QString err = QStringLiteral("unanswered");
        int answers = 0;
        rig.send(QString::fromLatin1(QTest::currentDataTag()),
                 [&](QString e) { err = e; ++answers; });
        QTRY_VERIFY_WITH_TIMEOUT(answers > 0, 5000);
        QTest::qWait(50);

        const QList<FakeTidal::Seen> seen = rig.tidal.seenFor(QStringLiteral("/api/x"));
        QVERIFY2(seen.size() == 2 && rig.tidal.tokenRequests == 1,
                 qPrintable(QStringLiteral("refused for the token: sent %1 time(s), asked for "
                                           "%2 new token(s), ended with \"%3\"")
                                .arg(seen.size()).arg(rig.tidal.tokenRequests).arg(err)));
        QVERIFY2(err.isEmpty(), qPrintable(err));
        QCOMPARE(answers, 1);
        QCOMPARE(seen.at(0).bearer, QByteArray("old"));
        QCOMPARE(seen.at(1).bearer, QByteArray("token-1"));
        QCOMPARE(seen.at(1).verb, verb);
        QCOMPARE(seen.at(1).body, seen.at(0).body);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QCOMPARE(savedCreds()[QStringLiteral("access_token")].toString(), QStringLiteral("token-1"));
    }

    void requestsRefusedTogetherShareOneRefresh()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.tokenAnswer = FakeTidal::Hold;

        QStringList errors;
        for (const char *kind : {"get", "getV2", "getArray", "postApiForm", "deleteApiWithStatus"})
            rig.send(QString::fromLatin1(kind), [&errors](QString e) { errors << e; });
        // All five are refused while the one refresh is still on its way.
        QTRY_COMPARE_WITH_TIMEOUT(rig.tidal.refused, 5, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(rig.tidal.tokenRequests, 1, 5000);
        QTest::qWait(50);
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QVERIFY(errors.isEmpty());

        rig.tidal.tokenAnswer = FakeTidal::Issue;
        rig.tidal.release();
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 5, 5000);
        QCOMPARE(errors.join(QString()), QString());
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.tidal.api.size(), 10);
    }

    // ── the last minute ─────────────────────────────────────────────────
    void theProgramStartedInTheTokensLastMinute()
    {
        Rig rig;
        saveSession(30);
        rig.auth.loadCredentials();
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);

        QTRY_COMPARE_WITH_TIMEOUT(rig.tidal.tokenRequests, 1, 3000);
        QTRY_COMPARE_WITH_TIMEOUT(rig.auth.accessToken(), QStringLiteral("token-1"), 5000);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QCOMPARE(savedCreds()[QStringLiteral("access_token")].toString(), QStringLiteral("token-1"));
        QTimer *next = nextTimer(rig.auth);
        QVERIFY(next && next->remainingTime() <= 60000);
        QTest::qWait(50);
        QCOMPARE(rig.tidal.tokenRequests, 1);
    }

    // ── what must not refresh ───────────────────────────────────────────
    void aHealthyTokenIsLeftAlone_data()
    {
        QTest::addColumn<qint64>("aheadSecs");
        QTest::newRow("two minutes") << qint64(120);
        QTest::newRow("an hour")     << qint64(3600);
        // Past what an int of milliseconds holds, about 24.8 days.
        QTest::newRow("30 days")     << qint64(30) * 86400;
        QTest::newRow("50 days")     << qint64(50) * 86400;
        QTest::newRow("a year")      << qint64(365) * 86400;
    }

    // The wake-up with nothing due: no request and no write to disk.
    void aHealthyTokenIsLeftAlone()
    {
        QFETCH(qint64, aheadSecs);
        Rig rig;
        signIn(rig, aheadSecs);
        if (QTest::currentTestFailed()) return;
        const QDateTime written = QFileInfo(credsPath()).lastModified();
        const QJsonObject creds = savedCreds();

        QTimer *next = nextTimer(rig.auth);
        QVERIFY2(next && next->remainingTime() <= 60000, "no wake-up within a minute");
        for (int i = 0; i < 3; ++i) wakeUp(rig.auth);
        QTest::qWait(100);

        QCOMPARE(rig.tidal.tokenRequests, 0);
        QCOMPARE(rig.tidal.api.size(), 0);
        QCOMPARE(rig.auth.accessToken(), QStringLiteral("old"));
        QCOMPARE(savedCreds(), creds);
        QCOMPARE(QFileInfo(credsPath()).lastModified(), written);
        QVERIFY(nextTimer(rig.auth));
    }

    void aTokenFarAheadIsReplacedInItsLastMinute_data() { aHealthyTokenIsLeftAlone_data(); }

    void aTokenFarAheadIsReplacedInItsLastMinute()
    {
        QFETCH(qint64, aheadSecs);
        Rig rig;
        signIn(rig, aheadSecs);
        if (QTest::currentTestFailed()) return;

        rig.auth.aheadSecs = aheadSecs - 90;
        wakeUp(rig.auth);
        QTest::qWait(50);
        QCOMPARE(rig.tidal.tokenRequests, 0);

        rig.auth.aheadSecs = aheadSecs - 30;
        wakeUp(rig.auth);
        QTRY_COMPARE_WITH_TIMEOUT(rig.auth.accessToken(), QStringLiteral("token-1"), 5000);
        QCOMPARE(rig.tidal.tokenRequests, 1);
    }

    void aRefusalAboutSomethingElseStaysWhatItIs_data()
    {
        QTest::addColumn<int>("subStatus");
        QTest::newRow("an asset that is not ready, 4005") << 4005;
        QTest::newRow("another code of Tidal's")          << 4010;
    }

    void aRefusalAboutSomethingElseStaysWhatItIs()
    {
        QFETCH(int, subStatus);
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.refuseAll = true;
        rig.tidal.refusal = QJsonDocument(QJsonObject{{QStringLiteral("status"), 401},
                                                      {QStringLiteral("subStatus"), subStatus}})
                                .toJson(QJsonDocument::Compact);
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        int answers = 0, httpStatus = 0, sub = 0;
        rig.api.getWithStatus(QStringLiteral("x"), {}, [&](QJsonObject body, QString, int s) {
            ++answers; httpStatus = s; sub = body[QStringLiteral("subStatus")].toInt();
        });
        QTRY_COMPARE_WITH_TIMEOUT(answers, 1, 5000);
        QTest::qWait(50);

        QCOMPARE(httpStatus, 401);
        QCOMPARE(sub, subStatus);
        QCOMPARE(rig.tidal.tokenRequests, 0);
        QCOMPARE(rig.tidal.api.size(), 1);
        QCOMPARE(expired.count(), 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
    }

    // The audio hosts and the covers are asked without a token, and so is
    // the API by a program that is signed out.
    void aRequestWithoutATokenAsksForNoRefresh()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;

        QString mediaErr;
        int answers = 0;
        QVERIFY(rig.api.getRaw(QUrl(rig.tidal.base() + QStringLiteral("media/1.mp4")),
                               [&](QByteArray, QString e) { mediaErr = e; ++answers; }));
        QTRY_COMPARE_WITH_TIMEOUT(answers, 1, 5000);
        QVERIFY(!mediaErr.isEmpty());
        QCOMPARE(rig.tidal.seenFor(QStringLiteral("/media/1.mp4")).first().bearer, QByteArray());

        Rig signedOut;
        QString apiErr;
        signedOut.send(QStringLiteral("get"), [&](QString e) { apiErr = e; ++answers; });
        QTRY_COMPARE_WITH_TIMEOUT(answers, 2, 5000);
        QTest::qWait(50);
        QVERIFY(!apiErr.isEmpty());
        QCOMPARE(signedOut.tidal.api.size(), 1);
        QCOMPARE(signedOut.tidal.api.first().bearer, QByteArray());

        // Signed in, and the JSON path asks a host that takes no token.
        rig.api.tokens = false;
        rig.send(QStringLiteral("get"), [&](QString) { ++answers; });
        QTRY_COMPARE_WITH_TIMEOUT(answers, 3, 5000);
        QTest::qWait(50);
        QCOMPARE(rig.tidal.seenFor(QStringLiteral("/api/x")).size(), 1);

        QCOMPARE(rig.tidal.tokenRequests, 0);
        QCOMPARE(signedOut.tidal.tokenRequests, 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
    }

    // ── the session's real end ──────────────────────────────────────────

    // A request cannot end a session, whatever the refusal says: ending one
    // removes the saved sign-in. Only the login host's own no does that.
    void aNewTokenRefusedAsExpiredIsAnOrdinaryError()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.issuedTokensAreGood = false;
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        QStringList errors;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        rig.send(QStringLiteral("getV2"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 2, 5000);
        QTest::qWait(100);

        QVERIFY(!errors.at(0).isEmpty() && !errors.at(1).isEmpty());
        QCOMPARE(expired.count(), 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QVERIFY(rig.auth.hasSavedCredentials());
        QCOMPARE(savedCreds()[QStringLiteral("refresh_token")].toString(), QStringLiteral("refresh-1"));
        // One refresh and one resend each, and then nothing more.
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.tidal.api.size(), 4);
    }

    // A token issued a moment ago and refused all the same is refused for
    // something else. The next request must not ask the login host again.
    void aTokenJustIssuedAndRefusedAsksForNoSecondRefresh()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.issuedTokensAreGood = false;
        rig.tidal.refusal = R"({"errors":[{"code":"UNAUTHORIZED"}]})";

        QStringList errors;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 1, 5000);
        QCOMPARE(rig.tidal.tokenRequests, 1);

        for (int i = 0; i < 3; ++i)
            rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 4, 5000);
        QTest::qWait(100);
        QVERIFY(!errors.at(3).isEmpty());
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
    }

    // A refusal that names nothing is taken for the token once. It is too
    // little to end a session on.
    void aNewTokenRefusedWithoutACodeIsAnOrdinaryError()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.issuedTokensAreGood = false;
        rig.tidal.refusal = R"({"errors":[{"code":"UNAUTHORIZED"}]})";
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        int answers = 0, httpStatus = 0;
        QString err;
        rig.api.getOpenApiWithStatus(QStringLiteral("x"), {},
            [&](QJsonObject, QString e, int s) { ++answers; err = e; httpStatus = s; });
        QTRY_COMPARE_WITH_TIMEOUT(answers, 1, 5000);
        QTest::qWait(50);

        QVERIFY(!err.isEmpty());
        QCOMPARE(httpStatus, 401);
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.tidal.api.size(), 2);
        QCOMPARE(expired.count(), 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QCOMPARE(savedCreds()[QStringLiteral("refresh_token")].toString(), QStringLiteral("refresh-1"));
    }

    void aRefreshTheLoginHostRefusesEndsTheSession()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.tokenAnswer = FakeTidal::Refuse;
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        QStringList errors;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 1, 5000);
        QTest::qWait(50);

        QVERIFY(!errors.first().isEmpty());
        QCOMPARE(expired.count(), 1);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedOut);
        QVERIFY(!QFile::exists(credsPath()));
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(rig.tidal.api.size(), 1);
    }

    void signingOutWhileARefreshIsOnItsWayStaysSignedOut()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.tokenAnswer = FakeTidal::Hold;
        rig.auth.aheadSecs = 7200;
        wakeUp(rig.auth);
        QTRY_COMPARE_WITH_TIMEOUT(rig.tidal.tokenRequests, 1, 5000);

        rig.auth.logout();
        rig.tidal.release();
        QTest::qWait(200);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedOut);
        QVERIFY(rig.auth.accessToken().isEmpty());
        QVERIFY(!QFile::exists(credsPath()));
    }

    void aProfileThatComesAfterTheSessionIsNotSaved_data()
    {
        QTest::addColumn<bool>("signOut");
        QTest::newRow("signed out")                 << true;
        QTest::newRow("refused at a refresh") << false;
    }

    // The profile asked for at the start lands after the session ended, and
    // no session file comes back.
    void aProfileThatComesAfterTheSessionIsNotSaved()
    {
        QFETCH(bool, signOut);
        Rig rig;
        rig.tidal.holdProfile = true;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        QVERIFY(QFile::exists(credsPath()));

        if (signOut) {
            rig.auth.logout();
        } else {
            rig.tidal.goodTokens.clear();
            rig.tidal.tokenAnswer = FakeTidal::Refuse;
            QSignalSpy expired(&rig.auth, &Auth::sessionExpired);
            rig.send(QStringLiteral("get"), [](QString) {});
            QTRY_COMPARE_WITH_TIMEOUT(expired.count(), 1, 5000);
        }
        QCOMPARE(rig.auth.state(), Auth::State::LoggedOut);
        QVERIFY(!QFile::exists(credsPath()));

        rig.tidal.releaseProfiles();
        QTest::qWait(200);
        QVERIFY2(!QFile::exists(credsPath()), qPrintable(QString::fromUtf8(
            QJsonDocument(savedCreds()).toJson(QJsonDocument::Compact))));
        QVERIFY(rig.auth.username().isEmpty());
    }

    // Busy or down is no refusal of the refresh token, whatever the body
    // says: the session stays.
    void aRefreshTheLoginHostCannotServeKeepsTheSession_data()
    {
        QTest::addColumn<int>("answer");
        QTest::newRow("429 with an error in JSON") << int(FakeTidal::RateLimited);
        QTest::newRow("503 with an error in JSON") << int(FakeTidal::Unavailable);
    }

    void aRefreshTheLoginHostCannotServeKeepsTheSession()
    {
        QFETCH(int, answer);
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.tokenAnswer = FakeTidal::TokenAnswer(answer);
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        QStringList errors;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 1, 5000);
        QTest::qWait(50);
        QVERIFY(!errors.first().isEmpty());
        QCOMPARE(expired.count(), 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QCOMPARE(savedCreds()[QStringLiteral("refresh_token")].toString(),
                 QStringLiteral("refresh-old"));
    }

    // An answer that is not the login host's is the network's fault: the
    // session stays, and the next refusal tries again.
    void aRefreshThatFailsOnTheWayKeepsTheSession()
    {
        Rig rig;
        signIn(rig);
        if (QTest::currentTestFailed()) return;
        rig.tidal.goodTokens.clear();
        rig.tidal.tokenAnswer = FakeTidal::BadGateway;
        QSignalSpy expired(&rig.auth, &Auth::sessionExpired);

        QStringList errors;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 1, 5000);
        QVERIFY(!errors.first().isEmpty());
        QCOMPARE(rig.tidal.tokenRequests, 1);
        QCOMPARE(expired.count(), 0);
        QCOMPARE(rig.auth.state(), Auth::State::LoggedIn);
        QCOMPARE(savedCreds()[QStringLiteral("refresh_token")].toString(),
                 QStringLiteral("refresh-old"));

        rig.tidal.tokenAnswer = FakeTidal::Issue;
        rig.send(QStringLiteral("get"), [&errors](QString e) { errors << e; });
        QTRY_COMPARE_WITH_TIMEOUT(errors.size(), 2, 5000);
        QCOMPARE(errors.at(1), QString());
        QCOMPARE(rig.tidal.tokenRequests, 2);
        QCOMPARE(rig.auth.accessToken(), QStringLiteral("token-1"));
    }
};

QTEST_GUILESS_MAIN(TestSession)
#include "tst_session.moc"
