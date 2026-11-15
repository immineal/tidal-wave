// The request line of every write the client makes: method, path, query,
// ETag header and form body, as they reach a server on loopback. Mocked
// clients cannot see these, and a wrong path (a 405) went unnoticed that way.

#include <QTest>
#include <QCoreApplication>
#include <QDir>
#include <QHash>
#include <QHostAddress>
#include <QJSEngine>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QSettings>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

namespace {

// All invented.
const QString kUuid = QStringLiteral("pl-tape-1");

// Tidal on loopback. Every request is recorded as one line; a GET is answered
// from `reads`, any other verb with `write`. Each answer carries `etag`.
class Loopback : public QTcpServer {
public:
    struct Answer { int status = 200; QByteArray body; };

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
                    QByteArray ifNoneMatch;
                    for (const QByteArray &raw : lines.mid(1)) {
                        const QByteArray line = raw.trimmed();
                        const QByteArray name = line.left(line.indexOf(':')).toLower();
                        const QByteArray value = line.mid(line.indexOf(':') + 1).trimmed();
                        if (name == "content-length") length = value.toLongLong();
                        if (name == "if-none-match") ifNoneMatch = value;
                    }
                    if (buf->size() < end + 4 + length) return;
                    const QList<QByteArray> request = lines.first().trimmed().split(' ');
                    const QByteArray verb = request.value(0);
                    const QString target = QString::fromUtf8(request.value(1));
                    const QString path = target.left(target.indexOf(QLatin1Char('?')));
                    QString line = QString::fromLatin1(verb) + QLatin1Char(' ') + target;
                    if (!ifNoneMatch.isEmpty())
                        line += QStringLiteral(" [If-None-Match: %1]").arg(QString::fromLatin1(ifNoneMatch));
                    const QByteArray body = buf->mid(end + 4, length);
                    if (!body.isEmpty()) line += QStringLiteral(" {%1}").arg(QString::fromUtf8(body));
                    buf->clear();
                    seen << line;
                    if (verb == "GET")
                        answer(sock, {200, reads.value(path, QByteArrayLiteral("{}"))});
                    else
                        answer(sock, write);
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }

    // The requests other than GET, in the order they came.
    QStringList writes() const
    {
        QStringList out;
        for (const QString &s : seen)
            if (!s.startsWith(QLatin1String("GET "))) out << s;
        return out;
    }

    Answer write;
    QByteArray etag = "\"v1\"";
    QHash<QString, QByteArray> reads;
    QStringList seen;

private:
    void answer(QTcpSocket *sock, const Answer &a) const
    {
        sock->write("HTTP/1.0 " + QByteArray::number(a.status) + " Answer\r\n"
                    "Content-Type: application/json\r\nETag: " + etag + "\r\n"
                    "Content-Length: " + QByteArray::number(a.body.size()) + "\r\n\r\n" + a.body);
        sock->flush();
        sock->disconnectFromHost();
    }
};

// The real TidalApi with every host on the local server.
class LocalApi : public TidalApi {
public:
    QString local;
    bool idle() const { return findChildren<QNetworkReply *>().isEmpty(); }

protected:
    QString baseUrl(const QString &base) const override
    {
        return local + (base == QLatin1String(kApiBaseV2) ? QLatin1String("api/v2/")
                                                          : QLatin1String("api/"));
    }
    bool takesTokens(const QUrl &url) const override
    {
        return url.path().startsWith(QLatin1String("/api/"));
    }
};

// A real bridge on a real client, signed in as an invented user 7.
struct Rig {
    QJSEngine   engine;
    Loopback    tidal;
    LocalApi    api;
    TidalClient client{&api};
    TidalBridge bridge{&client};
    QJSValue    keepAlive;

    bool settled() const { return api.idle() && client.listsParsingForTest() == 0; }

    Rig()
    {
        if (!tidal.listen(QHostAddress::LocalHost)) qFatal("no loopback server");
        api.local = tidal.base();
        api.setCountryCode(QStringLiteral("DE"));
        QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
        keepAlive = engine.newQObject(&bridge);
        client.setUserId(7);
        tidal.reads[QStringLiteral("/api/playlists/") + kUuid] =
            R"({"uuid":"pl-tape-1","title":"Tape","numberOfTracks":9,"creator":{"id":7}})";
    }

    // Every call of a script callback, its arguments joined by commas.
    struct Told {
        QJSValue fn;
        QJSValue calls;
        QStringList answers() const
        {
            QStringList out;
            const int n = calls.property(QStringLiteral("length")).toInt();
            for (int i = 0; i < n; ++i) out << calls.property(i).toString();
            return out;
        }
    };

    Told slot()
    {
        QJSValue calls = engine.newArray();
        const QJSValue fn = engine.evaluate(QStringLiteral(
            "(function (c) { return function () {"
            "  c.push(Array.prototype.slice.call(arguments).join(','));"
            "}; })")).call({calls});
        return {fn, calls};
    }

    // What the playlist page does on opening: it reads the header.
    void openPage()
    {
        bridge.fetchPlaylist(kUuid, slot().fn);
        QTRY_VERIFY_WITH_TIMEOUT(settled(), 5000);
        tidal.seen.clear();
    }
};

} // namespace

class TestWriteRequests : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

private slots:
    void initTestCase()
    {
        // Never the real configuration: the bridge reads and writes settings.
        QVERIFY(m_dir.isValid());
        qputenv("HOME", m_dir.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (m_dir.path() + QStringLiteral("/.config")).toUtf8());
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_write_requests"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // ── taking a song out of a playlist ─────────────────────────────────
    // The row's own path, and the ETag of the version the page showed: one
    // read again right before the DELETE could never catch a stale view.
    void aRemovalSendsTheRowAndTheVersionThePageShowed()
    {
        Rig rig;
        rig.openPage();
        // The playlist changes on another device after the page read it.
        rig.tidal.etag = "\"v9\"";
        const Rig::Told told = rig.slot();
        rig.bridge.removeTrackFromPlaylist(kUuid, 3, told.fn);
        QTRY_VERIFY_WITH_TIMEOUT(told.answers().size() == 1 && rig.settled(), 5000);

        QCOMPARE(rig.tidal.writes(), QStringList{
            QStringLiteral("DELETE /api/playlists/pl-tape-1/items/3?order=INDEX&orderDirection=ASC"
                           " [If-None-Match: \"v1\"]")});
        // Nothing was read between the page's read and the removal.
        QVERIFY2(rig.tidal.seen.first().startsWith(QLatin1String("DELETE ")),
                 qPrintable(rig.tidal.seen.join(QLatin1String("\n"))));
        QCOMPARE(told.answers(), QStringList{QStringLiteral("true,false,3")});
    }

    // A 412: the view is stale. It and everything queued behind it are
    // refused as stale, and nothing more is sent.
    void aStaleViewIsRefusedWithEverythingQueuedBehindIt()
    {
        Rig rig;
        rig.openPage();
        rig.tidal.write = {412, R"({"status":412,"subStatus":4000,"userMessage":"stale"})"};
        const Rig::Told first = rig.slot();
        const Rig::Told second = rig.slot();
        rig.bridge.removeTrackFromPlaylist(kUuid, 1, first.fn);
        rig.bridge.removeTrackFromPlaylist(kUuid, 4, second.fn);
        QTRY_VERIFY_WITH_TIMEOUT(second.answers().size() == 1 && rig.settled(), 5000);

        QCOMPARE(rig.tidal.writes().size(), 1);
        QCOMPARE(first.answers(), QStringList{QStringLiteral("false,true,-1")});
        QCOMPARE(second.answers(), QStringList{QStringLiteral("false,true,-1")});
    }

    // Two removals asked for before the first answer: the second goes out
    // after the first, at the index the first left it at, with the ETag the
    // first one's write produced.
    void twoQuickRemovalsGoOutOneAfterTheOther()
    {
        Rig rig;
        rig.openPage();
        const Rig::Told first = rig.slot();
        const Rig::Told second = rig.slot();
        const Rig::Told again = rig.slot();
        const Rig::Told before = rig.slot();
        rig.tidal.etag = "\"v2\"";
        rig.bridge.removeTrackFromPlaylist(kUuid, 2, first.fn);
        rig.bridge.removeTrackFromPlaylist(kUuid, 5, second.fn);
        // The same row twice, and a row above the first.
        rig.bridge.removeTrackFromPlaylist(kUuid, 2, again.fn);
        rig.bridge.removeTrackFromPlaylist(kUuid, 0, before.fn);
        QTRY_VERIFY_WITH_TIMEOUT(before.answers().size() == 1 && rig.settled(), 5000);

        QCOMPARE(rig.tidal.writes(), (QStringList{
            QStringLiteral("DELETE /api/playlists/pl-tape-1/items/2?order=INDEX&orderDirection=ASC"
                           " [If-None-Match: \"v1\"]"),
            QStringLiteral("DELETE /api/playlists/pl-tape-1/items/4?order=INDEX&orderDirection=ASC"
                           " [If-None-Match: \"v2\"]"),
            QStringLiteral("DELETE /api/playlists/pl-tape-1/items/0?order=INDEX&orderDirection=ASC"
                           " [If-None-Match: \"v2\"]")}));
        QCOMPARE(first.answers(),  QStringList{QStringLiteral("true,false,2")});
        QCOMPARE(second.answers(), QStringList{QStringLiteral("true,false,4")});
        QCOMPARE(again.answers(),  QStringList{QStringLiteral("true,false,-1")});
        QCOMPARE(before.answers(), QStringList{QStringLiteral("true,false,0")});
    }

};

QTEST_GUILESS_MAIN(TestWriteRequests)
#include "tst_write_requests.moc"
