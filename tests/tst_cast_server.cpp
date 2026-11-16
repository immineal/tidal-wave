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
            m_holding = true;
            for (int i = 0; i < 1000 && !m_release; ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            m_holding = false;
            s.abort();
        });
    }
    ~Stalled() { m_release = true; m_thread.join(); }
    // Connected with its request sent, and not yet hung up.
    bool holding() const { return m_holding; }

private:
    std::thread       m_thread;
    std::atomic<bool> m_release{false};
    std::atomic<bool> m_holding{false};
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
        QVERIFY(!server.start(QHostAddress::LocalHost).isEmpty());
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
        QVERIFY(!server.start(QHostAddress::LocalHost).isEmpty());
        const QUrl url(server.setCurrentFile(m_path, QStringLiteral("audio/flac")));

        // A server that serves one connection at a time answers the second
        // only once the first hangs up. Asked of the first client, not of a
        // clock, so a stall of the whole machine cannot fake either outcome.
        Stalled stalled(url, get(url));
        QTRY_VERIFY_WITH_TIMEOUT(stalled.holding(), 5000);
        QTest::qWait(200);   // the first request is in and being served

        Fetch second(url, get(url, "Range: bytes=1000-1999\r\n"));
        QTRY_VERIFY_WITH_TIMEOUT(second.done(), 12000);
        const bool firstStillHeld = stalled.holding();

        const Reply r = second.reply();
        QCOMPARE(r.status, 206);
        QCOMPARE(r.body.size(), 1000);
        QCOMPARE(r.body.at(0), byteAt(1000));
        QVERIFY2(firstStillHeld, "the second request was answered only after the first hung up");
    }

    // Anyone on the network can reach the server. Only the URL handed to the
    // receiver gets the track.
    void onlyTheUrlOfTheCurrentFileIsServed()
    {
        CastMediaServer server;
        QVERIFY(!server.start(QHostAddress::LocalHost).isEmpty());
        const QUrl url(server.setCurrentFile(m_small, QStringLiteral("audio/flac")));

        const QList<QByteArray> strangers{
            "/anything", "/", "/track", "/track/", "/track?v=1",
            "/track/00000000000000000000000000000000",
            url.path().toUtf8() + "0", url.path().toUtf8().chopped(1),
        };
        for (const QByteArray &path : strangers) {
            Fetch f(url, request("GET", path, "Range: bytes=0-9\r\n"));
            QTRY_VERIFY_WITH_TIMEOUT(f.done(), 5000);
            const Reply r = f.reply();
            QVERIFY2(r.status == 404, qPrintable(QStringLiteral("GET %1 was answered %2")
                                                 .arg(QString::fromUtf8(path)).arg(r.status)));
            QVERIFY(r.body.isEmpty());
        }

        // 128 random bits.
        QVERIFY2(QRegularExpression(QStringLiteral("^/track/[0-9a-f]{32}$"))
                     .match(url.path()).hasMatch(),
                 qPrintable(url.toString()));
        QVERIFY(!url.hasQuery());

        Fetch mine(url, get(url, "Range: bytes=0-9\r\n"));
        QTRY_VERIFY_WITH_TIMEOUT(mine.done(), 5000);
        QCOMPARE(mine.reply().status, 206);
    }

    // Each file gets a token of its own; the last one's URL is dead.
    void theNextFileGetsANewTokenAndTheOldUrlIsDead()
    {
        CastMediaServer server;
        QVERIFY(!server.start(QHostAddress::LocalHost).isEmpty());
        const QUrl first(server.setCurrentFile(m_small, QStringLiteral("audio/flac")));
        const QUrl second(server.setCurrentFile(m_small, QStringLiteral("audio/flac")));
        QVERIFY(first.path() != second.path());

        Fetch old(first, request("HEAD", target(first)));
        QTRY_VERIFY_WITH_TIMEOUT(old.done(), 5000);
        QCOMPARE(old.reply().status, 404);

        Fetch now(second, request("HEAD", target(second)));
        QTRY_VERIFY_WITH_TIMEOUT(now.done(), 5000);
        const Reply r = now.reply();
        QCOMPARE(r.status, 200);
        QCOMPARE(r.header("Content-Length").toLongLong(), kSmall);
        QVERIFY(r.body.isEmpty());
    }

    // RFC 9110 section 14: ranges, suffix ranges, open ranges, and 416 for
    // what the file cannot satisfy.
    void ranges_data()
    {
        QTest::addColumn<QByteArray>("range");
        QTest::addColumn<int>("status");
        QTest::addColumn<qint64>("first");   // of the bytes sent; -1 for none
        QTest::addColumn<qint64>("last");

        const qint64 n = kSmall;
        const QByteArray N = QByteArray::number(n);
        QTest::newRow("no range")       << QByteArray()             << 200 << 0LL << n - 1;
        QTest::newRow("closed")         << QByteArray("bytes=0-9")  << 206 << 0LL << 9LL;
        QTest::newRow("in the middle")  << QByteArray("bytes=100-199") << 206 << 100LL << 199LL;
        QTest::newRow("open")           << "bytes=" + QByteArray::number(n - 100) + "-"
                                        << 206 << n - 100 << n - 1;
        QTest::newRow("suffix")         << QByteArray("bytes=-500") << 206 << n - 500 << n - 1;
        QTest::newRow("suffix longer than the file")
                                        << QByteArray("bytes=-999999") << 206 << 0LL << n - 1;
        QTest::newRow("end past the file")
                                        << "bytes=10-" + QByteArray::number(n + 1000)
                                        << 206 << 10LL << n - 1;
        QTest::newRow("start at the size") << "bytes=" + N + "-" << 416 << -1LL << -1LL;
        QTest::newRow("start past the file")
                                        << "bytes=" + QByteArray::number(n + 10) + "-"
                                           + QByteArray::number(n + 20)
                                        << 416 << -1LL << -1LL;
        QTest::newRow("empty suffix")   << QByteArray("bytes=-0")   << 416 << -1LL << -1LL;
        // Invalid or not understood: the Range header is ignored.
        QTest::newRow("last before first") << QByteArray("bytes=5-2") << 200 << 0LL << n - 1;
        QTest::newRow("another unit")   << QByteArray("items=0-5")  << 200 << 0LL << n - 1;
        QTest::newRow("garbage")        << QByteArray("bytes=x-y")  << 200 << 0LL << n - 1;
        QTest::newRow("several ranges") << QByteArray("bytes=0-1,5-6") << 200 << 0LL << n - 1;
    }

    void ranges()
    {
        QFETCH(QByteArray, range);
        QFETCH(int, status);
        QFETCH(qint64, first);
        QFETCH(qint64, last);

        CastMediaServer server;
        QVERIFY(!server.start(QHostAddress::LocalHost).isEmpty());
        const QUrl url(server.setCurrentFile(m_small, QStringLiteral("audio/flac")));

        Fetch f(url, get(url, range.isEmpty() ? QByteArray() : "Range: " + range + "\r\n"));
        QTRY_VERIFY_WITH_TIMEOUT(f.done(), 5000);
        const Reply r = f.reply();
        QCOMPARE(r.status, status);
        if (status == 416) {
            QCOMPARE(r.header("Content-Range"), "bytes */" + QByteArray::number(kSmall));
            QVERIFY(r.body.isEmpty());
            return;
        }
        const qint64 length = last - first + 1;
        QCOMPARE(r.header("Content-Length").toLongLong(), length);
        QCOMPARE(qint64(r.body.size()), length);
        QCOMPARE(r.body.at(0), byteAt(first));
        QCOMPARE(r.body.at(r.body.size() - 1), byteAt(last));
        if (status == 206)
            QCOMPARE(r.header("Content-Range"),
                     "bytes " + QByteArray::number(first) + "-" + QByteArray::number(last)
                     + "/" + QByteArray::number(kSmall));
        else
            QVERIFY(r.header("Content-Range").isEmpty());
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
