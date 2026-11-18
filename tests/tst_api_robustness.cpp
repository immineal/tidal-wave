// What TidalApi and TidalClient do when the server is not well: a 429 with
// and without Retry-After, a page of a long list that fails, and errors that
// would put a signed URL into the log. Served from loopback.

#include <QTest>
#include <QDateTime>
#include <QHash>
#include <QHostAddress>
#include <QLocale>
#include <QNetworkReply>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimeZone>
#include <QUrlQuery>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"

namespace {

// Answers by path. A path's answers are used in turn, the last one again.
class Loopback : public QTcpServer {
public:
    struct Answer { int status = 200; QByteArray body = "{}"; QByteArray headers; };

    Loopback()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    const qsizetype end = buf->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    const QList<QByteArray> lines = buf->left(end).split('\n');
                    qsizetype length = 0;
                    for (const QByteArray &raw : lines.mid(1)) {
                        const QByteArray line = raw.trimmed();
                        if (line.toLower().startsWith("content-length:"))
                            length = line.mid(15).trimmed().toLongLong();
                    }
                    if (buf->size() < end + 4 + length) return;
                    const QList<QByteArray> request = lines.first().trimmed().split(' ');
                    const QString target = QString::fromUtf8(request.value(1));
                    buf->clear();
                    seen << target;
                    const QString path = target.left(target.indexOf(QLatin1Char('?')));
                    QList<Answer> &queue = answers[path];
                    const Answer a = queue.isEmpty() ? Answer{}
                                   : queue.size() > 1 ? queue.takeFirst() : queue.first();
                    sock->write("HTTP/1.0 " + QByteArray::number(a.status) + " Answer\r\n"
                                + a.headers + "Content-Type: application/json\r\n"
                                "Content-Length: " + QByteArray::number(a.body.size())
                                + "\r\n\r\n" + a.body);
                    sock->flush();
                    sock->disconnectFromHost();
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }

    // How many requests went to `path`.
    int count(const QString &path) const
    {
        int n = 0;
        for (const QString &s : seen)
            if (s.left(s.indexOf(QLatin1Char('?'))) == path) ++n;
        return n;
    }

    QHash<QString, QList<Answer>> answers;
    QStringList seen;
};

class LocalApi : public TidalApi {
public:
    QString local;
    bool idle() const { return findChildren<QNetworkReply *>().isEmpty(); }

protected:
    QString baseUrl(const QString &base) const override
    {
        return local + (base == QLatin1String(kAuthBase) ? QLatin1String("auth/")
                                                         : QLatin1String("api/"));
    }
    bool takesTokens(const QUrl &url) const override
    {
        return url.path().startsWith(QLatin1String("/api/"));
    }
};

struct Rig {
    Loopback tidal;
    LocalApi api;
    Rig()
    {
        if (!tidal.listen(QHostAddress::LocalHost)) qFatal("no loopback server");
        api.local = tidal.base();
        api.setCountryCode(QStringLiteral("DE"));
    }

    // One GET; the answer's error and status.
    struct Got { bool done = false; QString err; int status = -1; };
    std::shared_ptr<Got> get(const QString &endpoint)
    {
        auto got = std::make_shared<Got>();
        api.getWithStatus(endpoint, {}, [got](QJsonObject, QString e, int s) {
            got->done = true; got->err = e; got->status = s;
        });
        return got;
    }
};

QByteArray tracksPage(int from, int n, int total)
{
    QByteArray items;
    for (int i = 0; i < n; ++i) {
        if (i) items += ',';
        items += "{\"id\":" + QByteArray::number(from + i + 1) + ",\"title\":\"T\"}";
    }
    return "{\"totalNumberOfItems\":" + QByteArray::number(total) + ",\"items\":[" + items + "]}";
}

} // namespace

class TestApiRobustness : public QObject {
    Q_OBJECT

private slots:
    // ── 429 ─────────────────────────────────────────────────────────────
    // The endpoint that said 429 is left alone for as long as it asked, for
    // every track, and nothing retries by itself. Other endpoints go on.
    void anEndpointThatSaid429IsLeftAloneForRetryAfter()
    {
        Rig rig;
        rig.tidal.answers[QStringLiteral("/api/tracks/1/playbackinfo")] = {
            {429, R"({"status":429,"userMessage":"slow down"})", "Retry-After: 1\r\n"}};
        auto first = rig.get(QStringLiteral("tracks/1/playbackinfo"));
        QTRY_VERIFY_WITH_TIMEOUT(first->done && rig.api.idle(), 5000);
        QCOMPARE(first->status, 429);

        auto held  = rig.get(QStringLiteral("tracks/2/playbackinfo"));
        auto other = rig.get(QStringLiteral("albums/5"));
        QTRY_VERIFY_WITH_TIMEOUT(held->done && other->done && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/tracks/2/playbackinfo")), 0);
        QVERIFY(!held->err.isEmpty());
        QCOMPARE(held->status, 429);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/albums/5")), 1);
        QVERIFY2(other->err.isEmpty(), qPrintable(other->err));

        // Nothing went out again by itself while it waited.
        QTest::qWait(1200);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/tracks/1/playbackinfo")), 1);
        auto later = rig.get(QStringLiteral("tracks/3/playbackinfo"));
        QTRY_VERIFY_WITH_TIMEOUT(later->done && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/tracks/3/playbackinfo")), 1);
    }

    // The other form of the header, a date.
    void retryAfterAsADateIsHonoured()
    {
        Rig rig;
        const QString when = QLocale::c().toString(
            QDateTime::currentDateTimeUtc().addSecs(120), QStringLiteral("ddd, dd MMM yyyy hh:mm:ss 'GMT'"));
        rig.tidal.answers[QStringLiteral("/api/mixes/abc")] = {
            {429, "{}", "Retry-After: " + when.toLatin1() + "\r\n"}};
        auto first = rig.get(QStringLiteral("mixes/abc"));
        QTRY_VERIFY_WITH_TIMEOUT(first->done && rig.api.idle(), 5000);
        auto held = rig.get(QStringLiteral("mixes/abc"));
        QTRY_VERIFY_WITH_TIMEOUT(held->done && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/mixes/abc")), 1);
    }

    // No Retry-After at all is still a pause, not a licence to go on.
    void a429WithoutRetryAfterStillPauses()
    {
        Rig rig;
        rig.tidal.answers[QStringLiteral("/api/sessions")] = {{429, "{}", {}}};
        auto first = rig.get(QStringLiteral("sessions"));
        QTRY_VERIFY_WITH_TIMEOUT(first->done && rig.api.idle(), 5000);
        auto held = rig.get(QStringLiteral("sessions"));
        QTRY_VERIFY_WITH_TIMEOUT(held->done && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/sessions")), 1);
    }

    // The login host the same way.
    void theLoginHostIsLeftAloneAfterA429()
    {
        Rig rig;
        rig.tidal.answers[QStringLiteral("/auth/oauth2/token")] = {
            {429, R"({"error":"too_many_requests"})", "Retry-After: 30\r\n"}};
        int answers = 0;
        QUrlQuery form;
        form.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("refresh_token"));
        const auto cb = [&answers](QJsonObject, QString) { ++answers; };
        rig.api.postForm(QStringLiteral("oauth2/token"), form, cb);
        QTRY_VERIFY_WITH_TIMEOUT(answers == 1 && rig.api.idle(), 5000);
        rig.api.postForm(QStringLiteral("oauth2/token"), form, cb);
        QTRY_VERIFY_WITH_TIMEOUT(answers == 2 && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/auth/oauth2/token")), 1);
    }

    // ── a long list whose later page fails ──────────────────────────────
    // Delivered with the error, so a page can say it is not all there.
    void aListWhoseLaterPageFailsSaysSo()
    {
        Rig rig;
        TidalClient client(&rig.api);
        rig.tidal.answers[QStringLiteral("/api/playlists/pl-1/tracks")] = {
            {200, tracksPage(0, 100, 150), {}},
            {500, R"({"status":500,"userMessage":"broken"})", {}}};
        bool done = false;
        QString err;
        int rows = -1;
        client.fetchPlaylistTracks(QStringLiteral("pl-1"), [&](QList<Tidal::Track> t, QString e) {
            done = true; err = e; rows = int(t.size());
        });
        QTRY_VERIFY_WITH_TIMEOUT(done && rig.api.idle(), 5000);
        QCOMPARE(rig.tidal.count(QStringLiteral("/api/playlists/pl-1/tracks")), 2);
        QVERIFY2(!err.isEmpty(), "a list missing a third of its rows was handed on as whole");
        QCOMPARE(rows, 100);
    }

    // ── what reaches the log ────────────────────────────────────────────
    // A signed media URL carries its signature in the query.
    void aFailedDownloadNamesNoSignature()
    {
        Rig rig;
        rig.tidal.answers[QStringLiteral("/media/seg.mp4")] = {{403, "no", {}}};
        bool done = false;
        QString err;
        rig.api.getRaw(QUrl(rig.tidal.base() + QStringLiteral("media/seg.mp4?token=SIGNATURE&e=1")),
                       [&](QByteArray, QString e) { done = true; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(done && rig.api.idle(), 5000);
        QVERIFY(!err.isEmpty());
        QVERIFY2(!err.contains(QLatin1String("SIGNATURE")), qPrintable(err));
        QVERIFY2(err.contains(QLatin1String("/media/seg.mp4")), qPrintable(err));
    }

    void aFailedApiRequestNamesNoQuery()
    {
        Rig rig;
        rig.tidal.answers[QStringLiteral("/api/albums/5")] = {{404, "{}", {}}};
        auto got = rig.get(QStringLiteral("albums/5"));
        QTRY_VERIFY_WITH_TIMEOUT(got->done && rig.api.idle(), 5000);
        QVERIFY2(!got->err.contains(QLatin1String("countryCode")), qPrintable(got->err));
    }
};

QTEST_GUILESS_MAIN(TestApiRobustness)
#include "tst_api_robustness.moc"
