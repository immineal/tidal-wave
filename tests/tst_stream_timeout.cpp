// Giving up on a stream request that never answers, without giving up on one
// that is merely slow. TidalApi sets an idle transfer timeout on its
// QNetworkAccessManager. It measures silence, so a DASH join that
// legitimately takes longer than the timeout must still deliver every byte.
// Driven through the real DashFetcher and TidalClient::fetchRaw against
// localhost sockets. Nothing here makes a sound.

#include <QTest>
#include <QByteArray>
#include <QElapsedTimer>
#include <QHash>
#include <QHostAddress>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSet>
#include <QString>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/DashFetcher.h"

// @BASE@ stands in for the host: moc can take the "//" of a URL inside a raw
// string literal for a comment and lose track of where strings end.
namespace {

// One manifest, `count` media segments, every URL under the given base.
QString manifestOf(const QString &base, int count)
{
    static constexpr auto kTemplate = R"MPD(<MPD mediaPresentationDuration="PT10.0S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000" startNumber="1"
                     initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4">
      <SegmentTimeline><S d="500" r="@REPEAT@"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";
    QString mpd = QString::fromUtf8(kTemplate);
    mpd.replace(QStringLiteral("@BASE@"), base);
    mpd.replace(QStringLiteral("@REPEAT@"), QString::number(count - 1));
    return mpd;
}

// A localhost segment server that can take its time, or take forever.
// `thinkMs` is how long it waits before answering a path. A path listed in
// `neverAnswer` is accepted, read and then held open in silence.
class SegmentServer : public QTcpServer {
public:
    explicit SegmentServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &SegmentServer::accept);
    }

    QByteArray        body;            // served for every path that answers
    QHash<QString,int> thinkMs;        // path -> ms before answering
    int               defaultThinkMs = 0;
    QSet<QString>     neverAnswer;     // paths that are accepted and never served
    int               answered = 0;

    QString base() const
    {
        return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort());
    }

private:
    void accept()
    {
        while (QTcpSocket *sock = nextPendingConnection()) {
            auto buf = std::make_shared<QByteArray>();
            connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                buf->append(sock->readAll());
                if (buf->indexOf("\r\n\r\n") < 0) return;
                const QByteArray line = buf->left(buf->indexOf("\r\n"));
                buf->clear();
                const int sp1 = line.indexOf(' ');
                const int sp2 = line.indexOf(' ', sp1 + 1);
                if (sp1 < 0 || sp2 < 0) { sock->disconnectFromHost(); return; }
                QString path = QString::fromUtf8(line.mid(sp1 + 1, sp2 - sp1 - 1));
                const int q = path.indexOf(QLatin1Char('?'));
                if (q >= 0) path = path.left(q);
                if (neverAnswer.contains(path)) return;   // held open, in silence
                QTimer::singleShot(thinkMs.value(path, defaultThinkMs), sock,
                                   [this, sock] { answer(sock); });
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }

    void answer(QTcpSocket *sock)
    {
        if (sock->state() != QAbstractSocket::ConnectedState) return;
        ++answered;
        sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\n\r\n");
        sock->write(body);
        sock->flush();
        sock->disconnectFromHost();
    }
};

struct Outcome {
    bool    settled  = false;
    bool    gotFile  = false;
    qint64  bytes    = 0;
    QString error;
    qint64  elapsedMs = 0;
};

} // namespace

class TestStreamTimeout : public QObject {
    Q_OBJECT

private slots:
    // The two halves share one wait: both are governed by the same number and
    // each takes most of twenty seconds. They are independent objects with
    // independent servers.
    void aSegmentThatNeverAnswersEndsTheJoinAndASlowOneDoesNot()
    {
        // A timeout this short would make the slow half below meaningless.
        QVERIFY2(TidalApi::kTransferTimeoutMs >= 5000,
                 "the shipped transfer timeout is too short for this test to say "
                 "anything about a slow-but-working load");

        const QByteArray segment(4096, 'x');

        // ── the slow but working one ────────────────────────────────────────
        // 90 segments, each answered after 1200 ms, six in flight at a time:
        // longer end to end than the timeout, with no single request near it.
        // One waits 12000 ms, four fifths of the budget, to place the edge.
        SegmentServer slowSrv;
        QVERIFY(slowSrv.listen(QHostAddress::LocalHost));
        slowSrv.body = segment;
        slowSrv.defaultThinkMs = 1200;
        slowSrv.thinkMs.insert(QStringLiteral("/1.mp4"), 12000);

        TidalApi    slowApi;
        TidalClient slowClient{&slowApi};
        DashFetcher slow{&slowClient, manifestOf(slowSrv.base(), 90)};
        QVERIFY2(slow.isValid() && slow.openedTempFile(),
                 "the slow fixture's own manifest did not expand");
        QCOMPARE(slow.partCount(), 91);

        // ── the one that never answers ──────────────────────────────────────
        SegmentServer deadSrv;
        QVERIFY(deadSrv.listen(QHostAddress::LocalHost));
        deadSrv.body = segment;
        deadSrv.neverAnswer.insert(QStringLiteral("/1.mp4"));

        TidalApi    deadApi;
        TidalClient deadClient{&deadApi};
        DashFetcher dead{&deadClient, manifestOf(deadSrv.base(), 2)};
        QVERIFY2(dead.isValid() && dead.openedTempFile(),
                 "the dead fixture's own manifest did not expand");

        QElapsedTimer clock;
        clock.start();
        Outcome slowOut, deadOut;

        auto record = [&clock](Outcome *out) {
            return [out, &clock](QTemporaryFile *file, const QString &err) {
                out->settled   = true;
                out->gotFile   = file != nullptr;
                out->error     = err;
                out->elapsedMs = clock.elapsed();
                if (file) { out->bytes = file->size(); file->remove(); delete file; }
            };
        };
        slow.start(record(&slowOut));
        dead.start(record(&deadOut));

        // Neither may be finished before the timeout could have fired: a dead
        // one settled this early was ended by something else.
        QTest::qWait(3000);
        QVERIFY2(!deadOut.settled,
                 "the dead segment was given up on within three seconds, so the "
                 "timeout is not what ended it");

        const int ceiling = TidalApi::kTransferTimeoutMs + 25000;
        QTRY_VERIFY_WITH_TIMEOUT(slowOut.settled && deadOut.settled, ceiling);

        // ── the stuck one ──────────────────────────────────────────────────
        QVERIFY2(!deadOut.gotFile, "a join missing a segment handed over a file");
        QVERIFY2(!deadOut.error.isEmpty(),
                 "the join gave up without saying why, so the user would be told "
                 "nothing");
        QVERIFY2(deadOut.elapsedMs >= TidalApi::kTransferTimeoutMs - 1000,
                 qPrintable(QStringLiteral("the dead segment ended after %1 ms, "
                                           "sooner than the %2 ms timeout")
                            .arg(deadOut.elapsedMs)
                            .arg(TidalApi::kTransferTimeoutMs)));
        QVERIFY2(deadOut.elapsedMs <= TidalApi::kTransferTimeoutMs + 10000,
                 qPrintable(QStringLiteral("the dead segment took %1 ms to be "
                                           "given up on")
                            .arg(deadOut.elapsedMs)));

        // ── the slow one ───────────────────────────────────────────────────
        QVERIFY2(slowOut.gotFile,
                 qPrintable(QStringLiteral("a slow but working join was killed "
                                           "after %1 ms: %2")
                            .arg(slowOut.elapsedMs).arg(slowOut.error)));
        QCOMPARE(slowOut.bytes, qint64(segment.size()) * 91);
        QVERIFY2(slowOut.elapsedMs > TidalApi::kTransferTimeoutMs,
                 qPrintable(QStringLiteral("the slow join finished in %1 ms, "
                                           "inside the %2 ms timeout, so it never "
                                           "tested surviving one")
                            .arg(slowOut.elapsedMs)
                            .arg(TidalApi::kTransferTimeoutMs)));
        QCOMPARE(slowSrv.answered, 91);
    }

    // Qt before 6.8 cannot keep an HTTP/2 connection to the audio CDN alive
    // past a few segment requests, so media fetches there stay on HTTP/1.1.
    void mediaFetchesStayOffHttp2OnOlderQt()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.body = QByteArray(16, 'x');

        TidalApi    api;
        TidalClient client{&api};
        bool done = false;
        QNetworkReply *reply = client.fetchRaw(QUrl(srv.base() + QStringLiteral("1.mp4")),
                                               [&done](QByteArray, QString) { done = true; });
        QVERIFY(reply);
        const QVariant allowed =
            reply->request().attribute(QNetworkRequest::Http2AllowedAttribute);
#if QT_VERSION < QT_VERSION_CHECK(6, 8, 0)
        QVERIFY2(allowed.isValid() && !allowed.toBool(),
                 "a media fetch on this Qt may negotiate HTTP/2, which the audio "
                 "CDN drops after a few requests");
#else
        QVERIFY2(!allowed.isValid() || allowed.toBool(),
                 "HTTP/2 is switched off for media fetches on a Qt that handles it");
#endif
        QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
    }
};

QTEST_MAIN(TestStreamTimeout)
#include "tst_stream_timeout.moc"
