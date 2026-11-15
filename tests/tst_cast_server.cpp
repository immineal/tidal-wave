// The HTTP server a Chromecast fetches the current track from. Clients are
// plain sockets on threads of their own, so a server that blocks the GUI
// thread shows as a timer that stops firing. Nothing is cast, Tidal is not
// asked.

#include <QTest>
#include <QByteArray>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QRegularExpression>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QUrl>
#include <atomic>
#include <chrono>
#include <thread>

#include "cast/CastMediaServer.h"

namespace {

struct Reply {
    int        status = 0;
    QByteArray head;     // status line and headers
    QByteArray body;

    QByteArray header(const QByteArray &name) const
    {
        const QList<QByteArray> lines = head.split('\n');
        for (const QByteArray &l : lines) {
            const int colon = l.indexOf(':');
            if (colon > 0 && l.left(colon).trimmed().toLower() == name.toLower())
                return l.mid(colon + 1).trimmed();
        }
        return {};
    }
};

// Sends `request` from a thread of its own and reads until the server closes.
// The server lives on the test's thread, so the caller keeps its loop running.
class Fetch {
public:
    Fetch(const QUrl &base, const QByteArray &request)
    {
        const QString host = base.host();
        const quint16 port = quint16(base.port());
        m_thread = std::thread([this, host, port, request] {
            QTcpSocket s;
            s.connectToHost(host, port);
            if (s.waitForConnected(5000)) {
                s.write(request);
                s.waitForBytesWritten(5000);
                QByteArray all;
                while (s.state() == QAbstractSocket::ConnectedState
                       && s.waitForReadyRead(5000))
                    all += s.readAll();
                all += s.readAll();
                const int end = all.indexOf("\r\n\r\n");
                if (end >= 0) {
                    m_reply.head   = all.left(end);
                    m_reply.body   = all.mid(end + 4);
                    m_reply.status = m_reply.head.split(' ').value(1).toInt();
                }
            }
            m_done = true;
        });
    }
    ~Fetch() { if (m_thread.joinable()) m_thread.join(); }

    bool  done() const { return m_done; }
    Reply reply() { if (m_thread.joinable()) m_thread.join(); return m_reply; }

private:
    std::thread       m_thread;
    std::atomic<bool> m_done{false};
    Reply             m_reply;
};

// A client that sends its request and then reads nothing, like a receiver
// whose buffer is full, until released.
class Stalled {
public:
    Stalled(const QUrl &url, const QByteArray &request)
    {
        m_thread = std::thread([this, url, request] {
            QTcpSocket s;
            s.connectToHost(url.host(), quint16(url.port()));
            if (!s.waitForConnected(5000)) return;
            s.write(request);
            s.waitForBytesWritten(5000);
            for (int i = 0; i < 500 && !m_release; ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            s.abort();
        });
    }
    ~Stalled() { m_release = true; m_thread.join(); }

private:
    std::thread       m_thread;
    std::atomic<bool> m_release{false};
};

QByteArray request(const QByteArray &method, const QByteArray &target,
                   const QByteArray &extra = {})
{
    return method + " " + target + " HTTP/1.1\r\nHost: receiver\r\n" + extra + "\r\n";
}

QByteArray target(const QUrl &url)
{
    return url.path(QUrl::FullyEncoded).toUtf8()
         + (url.hasQuery() ? "?" + url.query(QUrl::FullyEncoded).toUtf8() : QByteArray());
}

QByteArray get(const QUrl &url, const QByteArray &extra = {})
{
    return request("GET", target(url), extra);
}

char byteAt(qint64 offset) { return char(offset % 251); }

} // namespace

class TestCastServer : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QVERIFY(m_dir.isValid());
        m_path = m_dir.filePath(QStringLiteral("track.flac"));
        QFile f(m_path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        // More than the loopback socket buffers hold, so a client that reads
        // nothing leaves the server with bytes it cannot send.
        QByteArray block(kBlock, '\0');
        for (int i = 0; i < kBlock; ++i) block[i] = byteAt(i);
        for (int i = 0; i < kBlocks; ++i) f.write(block);
        f.close();

        m_small = m_dir.filePath(QStringLiteral("small.flac"));
        QFile s(m_small);
        QVERIFY(s.open(QIODevice::WriteOnly));
        s.write(block.left(kSmall));
        s.close();
    }

    // A Chromecast stops reading once its buffer is full. The server must not
    // wait for it on the GUI thread.
    void aClientThatReadsNothingDoesNotStopTheEventLoop()
    {
        CastMediaServer server;
        QVERIFY(!server.start().isEmpty());
        const QUrl url(server.setCurrentFile(m_path, QStringLiteral("audio/flac")));
        QVERIFY(url.isValid());

        int ticks = 0;
        QTimer timer;
        timer.setInterval(50);
        connect(&timer, &QTimer::timeout, this, [&] { ++ticks; });
        {
            Stalled stalled(url, get(url));
            timer.start();
            QTest::qWait(1500);
            timer.stop();
        }
        QVERIFY2(ticks >= 15,
                 qPrintable(QStringLiteral("a 50 ms timer fired %1 times in 1.5 s while "
                                           "a client read nothing").arg(ticks)));
    }

    // A seek opens a second connection while the first still has bytes owed.
    void twoConnectionsAreServedAtOnce()
    {
        CastMediaServer server;
        QVERIFY(!server.start().isEmpty());
        const QUrl url(server.setCurrentFile(m_path, QStringLiteral("audio/flac")));

        // Timed from the first request: a server that serves one connection
        // at a time answers the second only when the first hangs up, at 5 s.
        QElapsedTimer clock;
        clock.start();
        Stalled stalled(url, get(url));
        QTest::qWait(200);   // the first request is in and being served

        Fetch second(url, get(url, "Range: bytes=1000-1999\r\n"));
        QTRY_VERIFY_WITH_TIMEOUT(second.done(), 4000);
        const qint64 took = clock.elapsed();

        const Reply r = second.reply();
        QCOMPARE(r.status, 206);
        QCOMPARE(r.body.size(), 1000);
        QCOMPARE(r.body.at(0), byteAt(1000));
        QVERIFY2(took < 2000, qPrintable(QStringLiteral("the second request took %1 ms")
                                         .arg(took)));
    }

private:
    static constexpr int kBlock  = 1024 * 1024;
    static constexpr int kBlocks = 48;
    static constexpr qint64 kSmall = 10000;
    QTemporaryDir m_dir;
    QString       m_path;    // too big for the socket buffers
    QString       m_small;
};

QTEST_MAIN(TestCastServer)
#include "tst_cast_server.moc"
