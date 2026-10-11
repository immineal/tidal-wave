// Which hosts are sent the user's access token and the client token: the two
// API origins, and no other host. The first tests read the request object
// TidalApi builds, the last one reads what a server receives.

#include <QTest>
#include <QByteArray>
#include <QHostAddress>
#include <QList>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUrl>
#include <QUrlQuery>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalClient.h"

namespace {

constexpr auto kToken = "the-users-token";

// Answers every request with an empty JSON object and keeps the header blocks.
class HeadServer : public QTcpServer {
public:
    explicit HeadServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    const int end = buf->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    heads << buf->left(end).toLower();
                    buf->clear();
                    sock->write("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n"
                                "Content-Length: 2\r\n\r\n{}");
                    sock->flush();
                    sock->disconnectFromHost();
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    QList<QByteArray> heads;   // lower case, one per request

    QString base() const
    {
        return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort());
    }
};

// The real TidalApi with every GET sent to a local server.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

} // namespace

class TestRequestHeaders : public QObject {
    Q_OBJECT

private slots:
    void onlyTheApiOriginsAreSentTheTokens_data()
    {
        QTest::addColumn<QString>("url");
        QTest::addColumn<bool>("tokens");

        const auto row = [](const char *name, const char *url, bool tokens) {
            QTest::newRow(name) << QString::fromLatin1(url) << tokens;
        };
        row("api v1",  "https://api.tidal.com/v1/tracks/1", true);
        row("api v2",  "https://api.tidal.com/v2/home/feed", true);
        row("openapi", "https://openapi.tidal.com/v2/trackManifests/1", true);
        row("API host in capitals", "https://API.TIDAL.COM/v1/tracks/1", true);

        row("audio CDN",  "https://sp-ad-fa.audio.tidal.com/mediatracks/x/0.mp4", false);
        row("image host", "https://resources.tidal.com/images/a/b/320x320.jpg", false);
        row("login host", "https://auth.tidal.com/v1/oauth2/token", false);
        row("another tidal.com host", "https://listen.tidal.com/", false);
        row("localhost", "http://127.0.0.1:8080/1.mp4", false);
        row("an unknown host", "https://cdn.example.net/a.mp4", false);

        row("API host as a prefix", "https://api.tidal.com.example.net/v1/", false);
        row("API host as a suffix", "https://notapi.tidal.com/v1/", false);
        row("API host in the path", "https://example.net/api.tidal.com/v1/", false);
        row("API host as the user", "https://api.tidal.com@example.net/v1/", false);
        row("API host over http",   "http://api.tidal.com/v1/tracks/1", false);
        row("API host, other port", "https://api.tidal.com:8443/v1/tracks/1", false);
    }

    void onlyTheApiOriginsAreSentTheTokens()
    {
        QFETCH(QString, url);
        QFETCH(bool, tokens);

        TidalApi api;
        api.setAccessToken(QString::fromLatin1(kToken));
        const QNetworkRequest req = api.makeRequest(QUrl(url));

        QCOMPARE(req.hasRawHeader("Authorization"), tokens);
        QCOMPARE(req.hasRawHeader("X-Tidal-Token"), tokens);
        if (tokens)
            QCOMPARE(req.rawHeader("Authorization"), QByteArray("Bearer ") + kToken);
        QVERIFY(!req.header(QNetworkRequest::UserAgentHeader).toString().isEmpty());
    }

    // A base URL added on a host that is missing from the list would be asked
    // without the token and answer 401.
    void everyApiBaseUrlIsOnTheList()
    {
        TidalApi api;
        api.setAccessToken(QString::fromLatin1(kToken));
        for (const char *base : {TidalApi::kApiBase, TidalApi::kApiBaseV2,
                                 TidalApi::kOpenApiBase}) {
            const QNetworkRequest req = api.makeRequest(QUrl(QString::fromLatin1(base)));
            QVERIFY2(req.hasRawHeader("Authorization") && req.hasRawHeader("X-Tidal-Token"),
                     base);
        }
        // The login host is sent the client id in the form body instead.
        const QNetworkRequest login =
            api.makeRequest(QUrl(QString::fromLatin1(TidalApi::kAuthBase)));
        QVERIFY(!login.hasRawHeader("Authorization") && !login.hasRawHeader("X-Tidal-Token"));
    }

    // What leaves the machine: a media fetch and a GET, both to a host that is
    // on no list.
    void aHostOffTheListReceivesNoToken()
    {
        HeadServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));

        LocalApi api;
        api.local = srv.base();
        api.setAccessToken(QString::fromLatin1(kToken));
        TidalClient client{&api};

        int answered = 0;
        QNetworkReply *reply = client.fetchRaw(QUrl(srv.base() + QStringLiteral("1.mp4")),
                                               [&answered](QByteArray, QString) { ++answered; });
        QVERIFY(reply);
        api.get(QStringLiteral("tracks/1"), QUrlQuery(),
                [&answered](QJsonObject, QString) { ++answered; });
        QTRY_COMPARE_WITH_TIMEOUT(answered, 2, 10000);

        QCOMPARE(srv.heads.size(), 2);
        for (const QByteArray &head : std::as_const(srv.heads)) {
            QVERIFY2(head.contains("user-agent:"), head.constData());
            QVERIFY2(!head.contains("authorization"), head.constData());
            QVERIFY2(!head.contains("x-tidal-token"), head.constData());
            QVERIFY2(!head.contains(kToken), head.constData());
        }
    }
};

QTEST_MAIN(TestRequestHeaders)
#include "tst_request_headers.moc"
