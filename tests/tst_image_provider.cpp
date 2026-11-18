// Covers through TidalImageProvider: they share one network manager with a
// disk cache, so a cover seen once is not downloaded again, and a cover
// scrolled past stops downloading. Served from loopback.

#include <QTest>
#include <QBuffer>
#include <QHostAddress>
#include <QImage>
#include <QNetworkAccessManager>
#include <QQuickImageResponse>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <memory>

#include "ui/ImageProvider.h"

namespace {

QByteArray png()
{
    QImage img(4, 4, QImage::Format_RGB32);
    img.fill(Qt::darkCyan);
    QByteArray out;
    QBuffer buf(&out);
    buf.open(QIODevice::WriteOnly);
    img.save(&buf, "PNG");
    return out;
}

// Answers every GET with a small PNG and the cache headers Tidal's image CDN
// sends, or not at all while `hold` is set.
class Loopback : public QTcpServer {
public:
    Loopback()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                ++connections;
                connect(sock, &QTcpSocket::disconnected, this, [this] { ++hangUps; });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    if (!buf->contains("\r\n\r\n")) return;
                    buf->clear();
                    ++requests;
                    if (hold) return;
                    const QByteArray body = png();
                    sock->write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n"
                                "Cache-Control: max-age=3600\r\n"
                                "Last-Modified: Mon, 08 Jun 2026 13:44:29 GMT\r\n"
                                "Content-Length: " + QByteArray::number(body.size())
                                + "\r\n\r\n" + body);
                });
            }
        });
    }
    QString url(const QString &name) const
    {
        return QStringLiteral("http://127.0.0.1:%1/%2").arg(serverPort()).arg(name);
    }
    int connections = 0;
    int requests = 0;
    int hangUps = 0;
    bool hold = false;
};

} // namespace

class TestImageProvider : public QObject {
    Q_OBJECT

    QTemporaryDir m_cache;
    TidalImageProvider m_provider;

    // One cover, the way the engine asks for it; true once it finished with
    // an image.
    bool load(const QString &url)
    {
        std::unique_ptr<QQuickImageResponse> r(
            m_provider.requestImageResponse(url, QSize(4, 4)));
        QSignalSpy done(r.get(), &QQuickImageResponse::finished);
        if (!done.wait(5000)) return false;
        std::unique_ptr<QQuickTextureFactory> tex(r->textureFactory());
        return tex && !tex->image().isNull();
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_cache.isValid());
        // Before the first cover, so the manager's cache is the temp dir.
        TidalImageProvider::manager(m_cache.path());
    }

    // The bug: a manager per cover, so a new connection and a new download
    // every time, the same cover again on every launch.
    void aCoverSeenOnceComesFromTheCache()
    {
        Loopback cdn;
        QVERIFY(cdn.listen(QHostAddress::LocalHost));
        QVERIFY(load(cdn.url(QStringLiteral("images/a/640x640.jpg"))));
        QVERIFY(load(cdn.url(QStringLiteral("images/a/640x640.jpg"))));
        QCOMPARE(cdn.requests, 1);
    }

    void coversShareOneConnection()
    {
        Loopback cdn;
        QVERIFY(cdn.listen(QHostAddress::LocalHost));
        QVERIFY(load(cdn.url(QStringLiteral("images/b/1.jpg"))));
        QVERIFY(load(cdn.url(QStringLiteral("images/b/2.jpg"))));
        QVERIFY(load(cdn.url(QStringLiteral("images/b/3.jpg"))));
        QCOMPARE(cdn.requests, 3);
        QCOMPARE(cdn.connections, 1);
    }

    // A cancelled cover stops downloading and still says it finished, which
    // the engine waits for before it lets go of the response.
    void aCancelledCoverStopsDownloading()
    {
        Loopback cdn;
        QVERIFY(cdn.listen(QHostAddress::LocalHost));
        cdn.hold = true;
        std::unique_ptr<QQuickImageResponse> r(m_provider.requestImageResponse(
            cdn.url(QStringLiteral("images/c/640x640.jpg")), QSize(4, 4)));
        QTRY_COMPARE_WITH_TIMEOUT(cdn.requests, 1, 5000);
        QSignalSpy done(r.get(), &QQuickImageResponse::finished);
        r->cancel();
        QCOMPARE(done.count(), 0);
        QVERIFY(done.wait(5000));
        QTRY_COMPARE_WITH_TIMEOUT(cdn.hangUps, 1, 5000);
    }
};

QTEST_MAIN(TestImageProvider)
#include "tst_image_provider.moc"
