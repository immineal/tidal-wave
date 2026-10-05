// Starting a lossless track before the whole of it has been fetched.
//
// LOSSLESS and HI_RES_LOSSLESS arrive as DASH. DashFetcher joins the segments
// into one fragmented MP4 *in play order*, so the front of that file is already a
// shorter fragmented MP4 of the same track. Playback nevertheless waited for the
// last segment, which measured 15-70 s on a real track before the first note.
//
// Two things stood between the front of the file and the decoder, and this file
// is the measurement of both:
//
//  1. The bytes were not on disk. QFile keeps a write buffer, so a second reader
//     of tempFilePath() saw a short file, or none, however many segments had
//     arrived. DashFetcher now flushes each contiguous write and reports how far
//     the front has got.
//  2. QMediaPlayer will not follow a local file that grows - it opens it, sees
//     the size it has, and plays that much. GrowingFileServer holds an HTTP
//     response open on the loopback interface instead and keeps appending.
//
// NOTHING HERE MAKES A SOUND. No QAudioOutput is ever constructed; the decoded
// samples arrive through QAudioBufferOutput, which cannot reach the sound card.
//
// The headline test runs both paths against the same fixture over the same real
// sockets and compares the two times to first sample, so the number in the commit
// message is this test's output rather than a claim. The fixture is deliberately
// not dash_fixture.inc; progressive_fixture.inc says why.
//
// WHAT THIS DOES NOT COVER, because it is not built yet: Player still waits for
// the whole join. Nothing in the app calls GrowingFileServer. Wiring it up has to
// answer what duration and seeking mean on a track that is not all there, and
// those answers are state in Player. The two assertions at the bottom of this
// file pin down what Player will have to cope with when it gets there.

#include <QTest>
#include <QAudioBuffer>
#include <QByteArray>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QMediaPlayer>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryFile>
#include <QTimer>
#include <QUrl>
#include <cmath>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/DashFetcher.h"
#include "player/GrowingFileServer.h"
// For TIDALWAVE_HAS_BUFFER_OUTPUT.
#include "player/SpectrumAnalyzer.h"

#if TIDALWAVE_HAS_BUFFER_OUTPUT
#include <QAudioBufferOutput>
#endif

// The packager manifest for the fixture, with the host going in through @BASE@.
// No "//" appears inside this raw string: moc honours a // comment even inside
// one, and a host with a slash-slash in it makes it lose track of where strings
// end and fail the build somewhere unrelated. (tst_dash.cpp carries the same
// note and the same bruise.)
constexpr auto kProgManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
<MPD profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static"
     mediaPresentationDuration="PT4.0S" minBufferTime="PT2.0S">
  <Period id="0" start="PT0.0S">
    <AdaptationSet id="0" contentType="audio" segmentAlignment="true">
      <Representation id="0" mimeType="audio/mp4" codecs="flac"
                      bandwidth="128000" audioSamplingRate="16000">
        <SegmentTemplate timescale="16000" startNumber="1"
                         initialization="@BASE@init-stream$RepresentationID$.m4s"
                         media="@BASE@chunk-stream$RepresentationID$-$Number%05d$.m4s">
          <SegmentTimeline>
            <S t="0" d="8064" r="6"/>
            <S d="8192"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

namespace {

#include "progressive_fixture.inc"

QByteArray segment(int i)
{
    return QByteArray::fromBase64(QByteArray(kProgSegmentsB64[i]));
}

QByteArray joinedByHand()
{
    QByteArray all;
    for (int i = 0; i < kProgSegmentCount; ++i) all += segment(i);
    return all;
}

QString withBase(const char *xml, const QString &base)
{
    QString mpd = QString::fromUtf8(xml);
    mpd.replace(QStringLiteral("@BASE@"), base);
    return mpd;
}

// ── a localhost segment server ──────────────────────────────────────────────
//
// Real sockets and real QNetworkAccessManager requests, so the fetcher runs
// through the same TidalClient::fetchRaw it uses against Tidal.
//
// Segment n is answered at (n+1) * perSegmentMs: a link that delivers the track
// at a steady rate, in order. That is what the wait being removed is made of, and
// it is the one part of this harness that had to be got right. A fixed delay on
// every request instead would be a model of latency, and DashFetcher runs six
// requests at once, so nine segments would arrive in two rounds and a progressive
// start would measure barely better than waiting - which is the shape of a
// fixture that cannot express the defect it is there for. A real lossless track
// is fifty-odd segments of one to three megabytes, where the join is bounded by
// the rate, not the round trips.
class SegmentServer : public QTcpServer {
public:
    explicit SegmentServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &SegmentServer::take);
    }

    QHash<QString, QByteArray> files;
    int perSegmentMs = 0;

    // The initialization segment is 0, chunk-stream0-NNNNN.m4s is N.
    static int segmentIndex(const QString &path)
    {
        const int dash = path.lastIndexOf(QLatin1Char('-'));
        const int dot  = path.lastIndexOf(QLatin1Char('.'));
        if (dash < 0 || dot < dash) return 0;
        bool ok = false;
        const int n = path.mid(dash + 1, dot - dash - 1).toInt(&ok);
        return ok ? n : 0;
    }

    QString base() const
    {
        return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort());
    }

    // init-stream0.m4s plus chunk-stream0-00001.m4s upwards, from the fixture.
    void serveFixture()
    {
        files[QStringLiteral("/init-stream0.m4s")] = segment(0);
        for (int i = 1; i < kProgSegmentCount; ++i)
            files[QStringLiteral("/chunk-stream0-%1.m4s")
                      .arg(i, 5, 10, QLatin1Char('0'))] = segment(i);
    }

private:
    void take()
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
                QString target = QString::fromUtf8(line.mid(sp1 + 1, sp2 - sp1 - 1));
                const int q = target.indexOf(QLatin1Char('?'));
                if (q >= 0) target.truncate(q);
                const int when = (segmentIndex(target) + 1) * perSegmentMs;
                QTimer::singleShot(when, sock, [this, sock, target] {
                    if (!files.contains(target)) {
                        sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    } else {
                        const QByteArray body = files.value(target);
                        sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\n"
                                    "Content-Length: " + QByteArray::number(body.size())
                                    + "\r\n\r\n");
                        sock->write(body);
                    }
                    sock->flush();
                    sock->disconnectFromHost();
                });
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
};

// ── what one playback attempt produced ──────────────────────────────────────

struct Played {
    qint64 firstSampleMs = -1;   // from the clock the caller started
    qint64 endOfMediaMs  = -1;
    qint64 joinDoneMs    = -1;
    qint64 frames        = 0;
    double peak          = 0.0;
    double toneHz        = 0.0;
    qint64 reportedDurationMs = 0;
    bool   reportedSeekable   = false;
    QMediaPlayer::MediaStatus status = QMediaPlayer::NoMedia;
    QMediaPlayer::Error       error  = QMediaPlayer::NoError;
    QString errorString;
};

// Attaches a silent tap to a player and accumulates what comes out of it. The
// tone and the peak are there so that silence, or the segments joined in the
// wrong order, fail rather than pass a shape check.
class Tap {
public:
    Tap(QMediaPlayer *player, Played *out, QElapsedTimer *clock)
        : m_out(out), m_clock(clock)
    {
#if TIDALWAVE_HAS_BUFFER_OUTPUT
        player->setAudioBufferOutput(&m_tap);
        QObject::connect(&m_tap, &QAudioBufferOutput::audioBufferReceived,
                         [this](const QAudioBuffer &b) { took(b); });
#else
        Q_UNUSED(player)
        // Without a buffer tap the only thing left that says "a sample came out"
        // is the position moving, which the caller wires up instead.
#endif
    }

    // Only meaningful with a buffer tap; otherwise the caller uses position.
    static constexpr bool measuresSamples = TIDALWAVE_HAS_BUFFER_OUTPUT;

    void finish()
    {
        if (m_out->frames > 0 && m_rate > 0)
            m_out->toneHz = (double(m_crossings) * m_rate) / (2.0 * double(m_out->frames));
    }

private:
    void took(const QAudioBuffer &b)
    {
        const QAudioFormat fmt = b.format();
        if (!fmt.isValid() || b.frameCount() <= 0) return;   // the end-of-stream one
        if (m_rate == 0) m_rate = fmt.sampleRate();
        if (m_out->firstSampleMs < 0) m_out->firstSampleMs = m_clock->elapsed();
        const int ch = fmt.channelCount();
        for (int i = 0; i < b.frameCount(); ++i) {
            double v = 0.0;
            switch (fmt.sampleFormat()) {
            case QAudioFormat::Float: v = b.constData<float>()[i * ch]; break;
            case QAudioFormat::Int32: v = b.constData<qint32>()[i * ch] / 2147483648.0; break;
            case QAudioFormat::Int16: v = b.constData<qint16>()[i * ch] / 32768.0; break;
            default: break;
            }
            if (std::fabs(v) > m_out->peak) m_out->peak = std::fabs(v);
            if ((m_prev < 0.0 && v >= 0.0) || (m_prev >= 0.0 && v < 0.0)) ++m_crossings;
            m_prev = v;
        }
        m_out->frames += b.frameCount();
    }

#if TIDALWAVE_HAS_BUFFER_OUTPUT
    QAudioBufferOutput m_tap;
#endif
    Played        *m_out;
    QElapsedTimer *m_clock;
    int    m_rate      = 0;
    qint64 m_crossings = 0;
    double m_prev      = 0.0;
};

} // namespace

class TestProgressive : public QObject {
    Q_OBJECT

private slots:
    // ── 1. the bytes have to be on disk ─────────────────────────────────────

    // Everything else here rests on this: a *second* reader of tempFilePath()
    // sees the segments that have arrived. Before DashFetcher flushed, it did
    // not - QFile's write buffer held them - and a server pointed at the file
    // had nothing to send however many segments were in.
    void theFrontOfTheJoinIsReadableWhileItIsStillRunning()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.serveFixture();
        srv.perSegmentMs = 150;     // so there is a middle to catch it in

        TidalApi api;
        TidalClient client{&api};
        DashFetcher fetcher(&client, withBase(kProgManifest, srv.base()));
        QVERIFY(fetcher.isValid());
        QCOMPARE(fetcher.partCount(), kProgSegmentCount);
        QVERIFY(fetcher.openedTempFile());
        const QString path = fetcher.tempFilePath();

        QList<QPair<qint64, int>> reports;
        fetcher.setProgress([&reports](qint64 bytes, int segs) {
            reports.append({bytes, segs});
        });

        bool done = false;
        QTemporaryFile *result = nullptr;
        fetcher.start([&](QTemporaryFile *f, const QString &) { done = true; result = f; });

        // Two segments in - the initialization segment and one media segment -
        // is the least that can play, and it is the moment this is about.
        QTRY_VERIFY_WITH_TIMEOUT(fetcher.segmentsReady() >= 2, 20000);
        QVERIFY2(!done, "the join finished before there was a middle to look at");

        // Whichever segment it got to, bytesReady() is those segments and nothing
        // else, and what is on disk is exactly them. Not a fixed count: the
        // fetcher runs six requests at once, so how far it is by the time this
        // line runs is the machine's business.
        const int  segs  = fetcher.segmentsReady();
        const qint64 ready = fetcher.bytesReady();
        QVERIFY(segs >= 2 && segs < kProgSegmentCount);
        QByteArray expected;
        for (int i = 0; i < segs; ++i) expected += segment(i);
        QCOMPARE(ready, qint64(expected.size()));

        QFile reader(path);
        QVERIFY(reader.open(QIODevice::ReadOnly));
        QVERIFY2(reader.size() >= ready,
                 qPrintable(QStringLiteral("said %1 bytes were ready, a second reader "
                                           "of the same path sees %2")
                                .arg(ready).arg(reader.size())));
        const QByteArray front = reader.read(ready);
        reader.close();
        QCOMPARE(front, expected);

        // And the reports themselves only ever move forward.
        QVERIFY(!reports.isEmpty());
        for (int i = 1; i < reports.size(); ++i) {
            QVERIFY2(reports.at(i).first > reports.at(i - 1).first, "bytesReady went backwards");
            QVERIFY2(reports.at(i).second > reports.at(i - 1).second, "segmentsReady went backwards");
        }

        QTRY_VERIFY_WITH_TIMEOUT(done, 20000);
        QVERIFY(result);
        QCOMPARE(fetcher.segmentsReady(), kProgSegmentCount);
        QCOMPARE(fetcher.bytesReady(), qint64(joinedByHand().size()));
        result->remove();
        delete result;
    }

    // ── 2. the headline: how long until the first sample ────────────────────

    void aGrowingJoinPlaysBeforeItHasFinished()
    {
        if (!Tap::measuresSamples)
            QSKIP("no QAudioBufferOutput on this Qt, so there is no sample to time");

        const Played whole       = playWaitingForTheWholeJoin();
        const Played progressive = playWhileTheJoinRuns();

        qInfo().noquote()
            << QStringLiteral("time to first sample: waiting for the whole join %1 ms "
                              "(join finished at %2 ms), serving it as it grows %3 ms "
                              "(join finished at %4 ms)")
                   .arg(whole.firstSampleMs).arg(whole.joinDoneMs)
                   .arg(progressive.firstSampleMs).arg(progressive.joinDoneMs);

        // Both paths have to actually decode the track, or the comparison is
        // between a measurement and a failure.
        for (const Played *p : { &whole, &progressive }) {
            QCOMPARE(p->status, QMediaPlayer::EndOfMedia);
            QCOMPARE(p->error, QMediaPlayer::NoError);
            QCOMPARE(p->frames, kProgFrames);
            QVERIFY2(std::fabs(p->peak - kProgPeak) < 0.01,
                     qPrintable(QStringLiteral("peak %1, expected %2")
                                    .arg(p->peak).arg(kProgPeak)));
            QVERIFY2(std::fabs(p->toneHz - kProgToneHz) < 10.0,
                     qPrintable(QStringLiteral("tone %1 Hz, expected %2 Hz")
                                    .arg(p->toneHz).arg(kProgToneHz)));
        }

        // The defect, stated as the thing that was impossible: a sample before
        // the last segment landed.
        QVERIFY2(progressive.firstSampleMs < progressive.joinDoneMs,
                 qPrintable(QStringLiteral("first sample at %1 ms, join finished at %2 ms: "
                                           "it still waited for the whole file")
                                .arg(progressive.firstSampleMs).arg(progressive.joinDoneMs)));

        // And by a margin, so that a regression fails here rather than a slow
        // machine does: two of nine segments in, against all nine. The slack is
        // in the numerator, which is where a loaded box adds its milliseconds.
        QVERIFY2(progressive.firstSampleMs * 2 < progressive.joinDoneMs,
                 qPrintable(QStringLiteral("first sample at %1 ms of a join that took "
                                           "%2 ms: not the saving this is for")
                                .arg(progressive.firstSampleMs).arg(progressive.joinDoneMs)));
        QVERIFY(progressive.firstSampleMs < whole.firstSampleMs);
    }

    // ── 3. what the caller will have to cope with ──────────────────────────

    // Both of these are the reason Player is not wired up in this change. They
    // are asserted rather than written down so that a later Qt quietly changing
    // its mind shows up here.
    void aGrowingStreamMisreportsItsDurationAndItsSeekability()
    {
        if (!Tap::measuresSamples)
            QSKIP("no QAudioBufferOutput on this Qt, so there is no sample to wait for");

        const Played p = playWhileTheJoinRuns();
        QCOMPARE(p.status, QMediaPlayer::EndOfMedia);

        // Measured at the moment the first sample came out, not at the end.
        QVERIFY2(p.reportedDurationMs > 0 && p.reportedDurationMs < kProgDurationMs / 2,
                 qPrintable(QStringLiteral("QMediaPlayer reported %1 ms of a %2 ms track; "
                                           "if that is now the real duration, a caller no "
                                           "longer needs the track metadata")
                                .arg(p.reportedDurationMs).arg(kProgDurationMs)));
        QVERIFY2(p.reportedSeekable,
                 "QMediaPlayer no longer claims a growing stream is seekable; a caller "
                 "may be able to stop pretending otherwise");
    }

    // ── 4. the server on its own ────────────────────────────────────────────

    // A request that reaches the write cursor is parked: no bytes, and no end of
    // body either. Answering it short is what made ffmpeg give up with nothing
    // decoded at all.
    void aRequestThatReachesTheWriteCursorWaitsForMore()
    {
        QTemporaryFile file;
        QVERIFY(file.open());
        const QByteArray all = joinedByHand();
        const qint64 firstHalf = segment(0).size() + segment(1).size();
        QCOMPARE(file.write(all.left(firstHalf)), firstHalf);
        QVERIFY(file.flush());

        GrowingFileServer server;
        const QString url = server.serve(file.fileName(), QStringLiteral("audio/mp4"),
                                         firstHalf);
        QVERIFY(!url.isEmpty());
        QVERIFY(server.isListening());

        const QUrl parsed(url);
        QCOMPARE(parsed.host(), QStringLiteral("127.0.0.1"));

        QTcpSocket client;
        client.connectToHost(QHostAddress::LocalHost, quint16(parsed.port()));
        QVERIFY(client.waitForConnected(5000));
        client.write("GET " + parsed.path().toUtf8() + " HTTP/1.1\r\n"
                     "Host: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n");
        QVERIFY(client.waitForBytesWritten(5000));

        QByteArray got;
        QTRY_VERIFY_WITH_TIMEOUT((got += client.readAll(), got.contains("\r\n\r\n")), 5000);
        const QByteArray head = got.left(got.indexOf("\r\n\r\n"));
        QVERIFY2(head.contains("Transfer-Encoding: chunked"),
                 qPrintable(QString::fromUtf8(head)));
        // The two headers that cost the whole wait: with either of them the
        // client believes the file is complete and seekable.
        QVERIFY2(!head.toLower().contains("content-length"), qPrintable(QString::fromUtf8(head)));
        QVERIFY2(!head.toLower().contains("accept-ranges"), qPrintable(QString::fromUtf8(head)));
        // The Range the client asked for was ignored, not answered.
        QVERIFY2(!head.toLower().contains("content-range"), qPrintable(QString::fromUtf8(head)));
        QVERIFY2(head.startsWith("HTTP/1.1 200"), qPrintable(QString::fromUtf8(head)));

        // The front of the file arrives...
        QTRY_VERIFY_WITH_TIMEOUT((got += client.readAll(),
                                  dechunk(got.mid(head.size() + 4)).size() >= firstHalf), 5000);
        QCOMPARE(dechunk(got.mid(head.size() + 4)), all.left(firstHalf));

        // ...and then nothing. Not an end of body, not a close: the socket goes
        // quiet until the writer flushes again.
        const qint64 settled = got.size();
        QTest::qWait(600);
        got += client.readAll();
        QCOMPARE(got.size(), settled);
        QCOMPARE(client.state(), QAbstractSocket::ConnectedState);
        QVERIFY2(!dechunkSawTerminator(got.mid(head.size() + 4)),
                 "the body was ended at the write cursor, which is an early end of track");

        // The rest of the join, then the terminating chunk.
        QCOMPARE(file.write(all.mid(firstHalf)), qint64(all.size() - firstHalf));
        QVERIFY(file.flush());
        server.setBytesReady(all.size());
        server.setComplete();

        QTRY_VERIFY_WITH_TIMEOUT((got += client.readAll(),
                                  dechunkSawTerminator(got.mid(head.size() + 4))), 5000);
        QCOMPARE(dechunk(got.mid(head.size() + 4)), all);
        QTRY_COMPARE_WITH_TIMEOUT(client.state(), QAbstractSocket::UnconnectedState, 5000);
    }

    // The URL is the only thing between another process on this machine and the
    // track, so a near miss is a 404.
    void aRequestWithoutTheTokenGetsNothing()
    {
        QTemporaryFile file;
        QVERIFY(file.open());
        QVERIFY(file.write(joinedByHand()) > 0);
        QVERIFY(file.flush());

        GrowingFileServer server;
        const QString url = server.serve(file.fileName(), QStringLiteral("audio/mp4"),
                                         joinedByHand().size());
        QVERIFY(!url.isEmpty());
        const QUrl parsed(url);
        QVERIFY2(parsed.path().size() > 8, qPrintable(parsed.path()));

        for (const QByteArray &target : { QByteArray("/"), QByteArray("/track"),
                                          parsed.path().toUtf8() + "x" }) {
            QTcpSocket client;
            client.connectToHost(QHostAddress::LocalHost, quint16(parsed.port()));
            QVERIFY(client.waitForConnected(5000));
            client.write("GET " + target + " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
            QVERIFY(client.waitForBytesWritten(5000));
            QByteArray got;
            QTRY_VERIFY_WITH_TIMEOUT((got += client.readAll(), got.contains("\r\n\r\n")), 5000);
            QVERIFY2(got.startsWith("HTTP/1.1 404"),
                     qPrintable(QStringLiteral("%1 answered %2")
                                    .arg(QString::fromUtf8(target),
                                         QString::fromUtf8(got.left(got.indexOf("\r\n"))))));
        }

        // A second serve() mints a new token, so a player still holding the old
        // URL gets a 404 rather than the next track's bytes.
        const QString again = server.serve(file.fileName(), QStringLiteral("audio/mp4"),
                                           joinedByHand().size());
        QVERIFY(!again.isEmpty());
        QVERIFY2(again != url, "serve() reused the previous token");
    }

private:
    // ── helpers ─────────────────────────────────────────────────────────────

    // Chunked bodies, as far as they have arrived. A trailing partial chunk is
    // simply not counted, which is what makes the "and then nothing" assertion
    // above able to tell a stalled body from a finished one.
    static QByteArray dechunk(const QByteArray &body, bool *sawTerminator = nullptr)
    {
        QByteArray out;
        if (sawTerminator) *sawTerminator = false;
        int i = 0;
        while (true) {
            const int eol = body.indexOf("\r\n", i);
            if (eol < 0) break;
            bool ok = false;
            const qint64 size = body.mid(i, eol - i).toLongLong(&ok, 16);
            if (!ok) break;
            if (size == 0) { if (sawTerminator) *sawTerminator = true; break; }
            if (eol + 2 + size + 2 > body.size()) break;   // still arriving
            out += body.mid(eol + 2, size);
            i = int(eol + 2 + size + 2);
        }
        return out;
    }

    static bool dechunkSawTerminator(const QByteArray &body)
    {
        bool saw = false;
        dechunk(body, &saw);
        return saw;
    }

    // Today's path: join the whole thing, then open the finished file.
    Played playWaitingForTheWholeJoin()
    {
        SegmentServer srv;
        srv.listen(QHostAddress::LocalHost);
        srv.serveFixture();
        srv.perSegmentMs = kSegmentDelayMs;

        TidalApi api;
        TidalClient client{&api};
        DashFetcher fetcher(&client, withBase(kProgManifest, srv.base()));

        Played out;
        QElapsedTimer clock;
        QMediaPlayer player;
        Tap tap(&player, &out, &clock);
        QEventLoop loop;
        watch(&player, &out, &clock, &loop);

        QTemporaryFile *joined = nullptr;
        clock.start();
        fetcher.start([&](QTemporaryFile *f, const QString &) {
            out.joinDoneMs = clock.elapsed();
            joined = f;
            if (!f) { loop.quit(); return; }
            player.setSource(QUrl::fromLocalFile(f->fileName()));
            player.play();
        });

        QTimer::singleShot(kPlaybackTimeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
        collect(&player, &out, &tap);
        if (joined) { joined->remove(); delete joined; }
        return out;
    }

    // The new path: serve the file while the join is still filling it.
    Played playWhileTheJoinRuns()
    {
        SegmentServer srv;
        srv.listen(QHostAddress::LocalHost);
        srv.serveFixture();
        srv.perSegmentMs = kSegmentDelayMs;

        TidalApi api;
        TidalClient client{&api};
        DashFetcher fetcher(&client, withBase(kProgManifest, srv.base()));

        Played out;
        QElapsedTimer clock;
        QMediaPlayer player;
        Tap tap(&player, &out, &clock);
        QEventLoop loop;
        watch(&player, &out, &clock, &loop);

        GrowingFileServer server;
        bool started = false;
        fetcher.setProgress([&](qint64 bytes, int segs) {
            if (!started && segs >= 2) {
                // The initialization segment plus one media segment: the least
                // that is a playable fragmented MP4 on its own.
                started = true;
                const QString url = server.serve(fetcher.tempFilePath(),
                                                 QStringLiteral("audio/mp4"), bytes);
                QVERIFY(!url.isEmpty());
                player.setSource(QUrl(url));
                player.play();
            } else if (started) {
                server.setBytesReady(bytes);
            }
        });

        QTemporaryFile *joined = nullptr;
        clock.start();
        fetcher.start([&](QTemporaryFile *f, const QString &) {
            out.joinDoneMs = clock.elapsed();
            joined = f;
            if (!f) { loop.quit(); return; }
            // The file the server is reading is the one the fetcher just handed
            // over, so the last flush is already in it.
            server.setBytesReady(f->size());
            server.setComplete();
        });

        QTimer::singleShot(kPlaybackTimeoutMs, &loop, &QEventLoop::quit);
        loop.exec();
        collect(&player, &out, &tap);
        server.stop();
        if (joined) { joined->remove(); delete joined; }
        return out;
    }

    // Records the duration and seekability the player claims *while it is
    // playing an incomplete file*, which is the thing a caller would otherwise
    // believe, and ends the run at the end of the media.
    static void watch(QMediaPlayer *player, Played *out, QElapsedTimer *clock,
                      QEventLoop *loop)
    {
        QObject::connect(player, &QMediaPlayer::mediaStatusChanged,
                         [player, out, clock, loop](QMediaPlayer::MediaStatus s) {
            if (s == QMediaPlayer::LoadedMedia && out->reportedDurationMs == 0) {
                out->reportedDurationMs = player->duration();
                out->reportedSeekable   = player->isSeekable();
            }
            if (s == QMediaPlayer::InvalidMedia || s == QMediaPlayer::EndOfMedia) {
                if (out->endOfMediaMs < 0) out->endOfMediaMs = clock->elapsed();
                QTimer::singleShot(100, loop, &QEventLoop::quit);
            }
        });
    }

    static void collect(QMediaPlayer *player, Played *out, Tap *tap)
    {
        tap->finish();
        out->status      = player->mediaStatus();
        out->error       = player->error();
        out->errorString = player->errorString();
        player->setSource(QUrl());
    }

    // One segment's worth of round trip. Nine segments of it is the wait a
    // progressive start removes; on a real track it is fifty or more.
    static constexpr int kSegmentDelayMs   = 250;
    static constexpr int kPlaybackTimeoutMs = 30000;
};

QTEST_MAIN(TestProgressive)
#include "tst_progressive.moc"
