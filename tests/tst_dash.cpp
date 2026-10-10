// Lossless playback on a build made against the Qt installer.
//
// Tidal serves LOSSLESS and HI_RES_LOSSLESS as MPEG-DASH. The app used to write
// the manifest to a .mpd and hand the file to QMediaPlayer, which only works
// where libavformat was built with libxml2 - that is what gates its DASH
// demuxer. The ffmpeg the Qt installer bundles has no libxml2:
//
//     ldd ~/Qt/6.12.0/gcc_64/lib/libavformat.so.61 | grep -c xml2   ->  0
//     ldd /usr/lib/libavformat.so.61               | grep -c xml2   ->  1
//
// and libffmpegmediaplugin.so has RUNPATH $ORIGIN/../../lib, so on such a build
// the bundled copy always wins and every lossless track was rejected as
// InvalidMedia inside a millisecond, silently, with nothing audible to show for
// it. Whether lossless played came down to which Qt the packager happened to
// have.
//
// DashFetcher joins the segments itself, which turns the manifest into an
// ordinary fragmented MP4 that needs no demuxer anyone might be missing. These
// tests are the proof, and they are deliberately not "the parser returns the
// right strings": the fixture is a real DASH stream from ffmpeg's own packager,
// it is served over real localhost HTTP through the real TidalClient::fetchRaw,
// and the joined result is decoded and measured. A fixture that were silence, or
// truncated, or stitched in the wrong order, fails the length and frequency
// assertions rather than passing a shape check.
//
// NOTHING HERE MAKES A SOUND. No QAudioOutput is ever constructed - the decoded
// samples arrive through QAudioBufferOutput, which cannot reach the sound card.
// Qt 6.4 is the one exception: decodeSilently() attaches a muted output there.
// The app's own Player *does* own a QAudioOutput, which is why these tests drive
// DashFetcher plus a QMediaPlayer of their own rather than a Player.
//
// The fixture was made with (ffmpeg 7.1, system build):
//     ffmpeg -f lavfi -i "sine=f=440:r=44100:d=1" -ac 1 -c:a flac -strict -2 \
//            -f dash -seg_duration 0.4 -use_timeline 1 -use_template 1 out.mpd
// which is one second of a 440 Hz tone as 16-bit mono FLAC in fragmented MP4:
// an initialization segment and three media segments, FLAC-in-MP4 being exactly
// what Tidal delivers. Its peak sample is 4095/32768, which is where the 0.125
// below comes from.

#include <QTest>
#include <QAudioBuffer>
#include <QAudioOutput>
#include <QByteArray>
#include <QEventLoop>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QMediaPlayer>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QTimer>
#include <cmath>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/DashFetcher.h"
// For TIDALWAVE_HAS_BUFFER_OUTPUT.
#include "player/SpectrumAnalyzer.h"

#if TIDALWAVE_HAS_BUFFER_OUTPUT
#include <QAudioBufferOutput>
#endif

// ── the manifests ─────────────────────────────────────────────────────────
//
// The host goes in through @BASE@ rather than being written out, and that is not
// cosmetic: there is no "//" anywhere inside these raw strings because moc
// honours a // comment even inside a raw string literal. A line holding a
// "http://host/" and a quote after it makes moc lose track of where strings end,
// stop recognising Q_OBJECT classes altogether, and fail the build with a
// "missing ')' in macro usage" pointing at some unrelated line further down.
// (#ifndef Q_MOC_RUN does not help: moc still lexes what it skips.) The house
// rule from the same bruise is in tst_shortcuts.cpp, which avoids raw strings
// altogether; this file keeps them and avoids the one sequence that sets moc off.

// ffmpeg's dash muxer wrote this, with only the two template attributes
// rewritten from relative names to an absolute base - the one way Tidal's
// manifests differ in shape. $RepresentationID$ and the printf width in
// $Number%05d$ are the packager's, not ours.
constexpr auto kPackagerManifest = R"MPD(<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011"
     type="static" mediaPresentationDuration="PT1.0S" maxSegmentDuration="PT0.4S" minBufferTime="PT2.0S">
  <Period id="0" start="PT0.0S">
    <AdaptationSet id="0" contentType="audio" startWithSAP="1" segmentAlignment="true">
      <Representation id="0" mimeType="audio/mp4" codecs="flac" bandwidth="128000" audioSamplingRate="44100">
        <SegmentTemplate timescale="44100"
                         initialization="@BASE@init-stream$RepresentationID$.m4s"
                         media="@BASE@chunk-stream$RepresentationID$-$Number%05d$.m4s"
                         startNumber="1">
          <SegmentTimeline>
            <S t="0" d="18432" r="1" />
            <S d="9864" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

// Tidal's own shape: plain $Number$, absolute presigned CDN URLs, and therefore
// a query string whose ampersands are XML entities in the manifest. Getting
// those back as '&' is the parser's job, and a presigned URL without its query
// intact names a different object.
constexpr auto kTidalManifest = R"MPD(<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"
     type="static" minBufferTime="PT1.500S" mediaPresentationDuration="PT0H0M1.000S">
  <Period id="0">
    <AdaptationSet id="0" contentType="audio" mimeType="audio/mp4" segmentAlignment="true">
      <Representation id="1" codecs="flac" bandwidth="1070000" audioSamplingRate="44100">
        <SegmentTemplate timescale="44100" startNumber="1"
                         initialization="@BASE@init.mp4?token=abc&amp;exp=99"
                         media="@BASE@seg-$Number$.mp4?token=abc&amp;exp=99">
          <SegmentTimeline>
            <S d="18432" r="1" />
            <S d="9864" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
)MPD";

constexpr auto kStartNumberManifest = R"MPD(<MPD mediaPresentationDuration="PT1.5S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000" startNumber="7"
                     initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4">
      <SegmentTimeline><S d="500" r="2"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// No timeline: a fixed duration per segment, with the count implied by how long
// the whole thing is. 2.5s of 0.4s segments is seven, the last one short.
constexpr auto kFixedDurationManifest = R"MPD(<MPD mediaPresentationDuration="PT2.5S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000" duration="400"
                     initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4"/>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// $Time$ needs the timeline's running start times, which the parser does not
// keep. Leaving it in the URL would 404 one segment at a time and read as a
// network fault; refusing the manifest says the true thing.
constexpr auto kTimeIdentifierManifest = R"MPD(<MPD mediaPresentationDuration="PT1.0S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000"
                     initialization="@BASE@i.mp4" media="@BASE@$Time$.mp4">
      <SegmentTimeline><S d="500" r="1"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// A timeline claiming a million segments. Nothing real does this; a garbled or
// hostile manifest can, and reserving and filling a list that long before
// failing is not a way to find out.
constexpr auto kAbsurdCountManifest = R"MPD(<MPD mediaPresentationDuration="PT1.0S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000"
                     initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4">
      <SegmentTimeline><S d="500" r="999999"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// The same absurdity through the duration fallback: a one-hour presentation in
// segments of a thousandth of a second.
constexpr auto kAbsurdDurationManifest = R"MPD(<MPD mediaPresentationDuration="PT1H">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate timescale="1000000" duration="1000"
                     initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4"/>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

constexpr auto kNoTemplateManifest = R"MPD(<MPD mediaPresentationDuration="PT1.0S">
  <Period><AdaptationSet><Representation id="0">
    <BaseURL>@BASE@whole.mp4</BaseURL>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

constexpr auto kNoInitManifest = R"MPD(<MPD mediaPresentationDuration="PT1.0S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate media="@BASE@$Number$.mp4">
      <SegmentTimeline><S d="500"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

constexpr auto kEmptyTimelineManifest = R"MPD(<MPD mediaPresentationDuration="PT1.0S">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4">
      <SegmentTimeline/>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// r="-1" repeats to the end of a stream that has no end.
constexpr auto kLiveManifest = R"MPD(<MPD type="dynamic">
  <Period><AdaptationSet><Representation id="0">
    <SegmentTemplate initialization="@BASE@i.mp4" media="@BASE@$Number$.mp4">
      <SegmentTimeline><S d="500" r="-1"/></SegmentTimeline>
    </SegmentTemplate>
  </Representation></AdaptationSet></Period>
</MPD>
)MPD";

// The BTS manifest is JSON. A manifestMimeType the app does not recognise comes
// down the DASH branch, so this is reachable.
constexpr auto kBtsManifestJson =
    R"BTS({"mimeType":"audio/mp4","urls":["@BASE@x.mp4"]})BTS";

namespace {

#include "dash_fixture.inc"

QByteArray initSegment()   { return QByteArray::fromBase64(QByteArray(kInitB64)); }
QByteArray mediaSegment1() { return QByteArray::fromBase64(QByteArray(kSeg1B64)); }
QByteArray mediaSegment2() { return QByteArray::fromBase64(QByteArray(kSeg2B64)); }
QByteArray mediaSegment3() { return QByteArray::fromBase64(QByteArray(kSeg3B64)); }

QByteArray joinedByHand()
{
    return initSegment() + mediaSegment1() + mediaSegment2() + mediaSegment3();
}

// The host the parser-only manifests above are expanded against. Any absolute
// URL would do; it is never fetched.
constexpr auto kTestHost = "http://h/";

// @BASE@ rather than QString::arg(): the packager's $Number%05d$ is a printf
// width that belongs to DASH, and handing a string containing "%05" to arg() is
// asking for trouble nobody would come looking for here.
QString withBase(const char *xml, const QString &base)
{
    QString mpd = QString::fromUtf8(xml);
    mpd.replace(QStringLiteral("@BASE@"), base);
    return mpd;
}

// ── a localhost segment server ──────────────────────────────────────────────
//
// Real sockets and real QNetworkAccessManager requests, so the fetcher runs
// through the same TidalClient::fetchRaw it uses against Tidal. A hand-written
// fetch callback would have proved only that the test's own fake works.
class SegmentServer : public QTcpServer {
public:
    explicit SegmentServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &SegmentServer::accept);
    }

    QHash<QString, QByteArray> files;     // request path, query stripped -> bytes
    QHash<QString, int>        delaysMs;  // path -> ms to wait before answering
    QStringList                requested; // request targets, query and all, in order

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
                if (buf->indexOf("\r\n\r\n") < 0) return;   // headers still arriving
                const QByteArray line = buf->left(buf->indexOf("\r\n"));
                buf->clear();
                const int sp1 = line.indexOf(' ');
                const int sp2 = line.indexOf(' ', sp1 + 1);
                if (sp1 < 0 || sp2 < 0) { sock->disconnectFromHost(); return; }
                const QString target =
                    QString::fromUtf8(line.mid(sp1 + 1, sp2 - sp1 - 1));
                requested << target;
                const int q = target.indexOf(QLatin1Char('?'));
                const QString path = q < 0 ? target : target.left(q);
                QTimer::singleShot(delaysMs.value(path, 0), sock,
                                   [this, sock, path] { answer(sock, path); });
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }

    void answer(QTcpSocket *sock, const QString &path)
    {
        if (!files.contains(path)) {
            sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        } else {
            const QByteArray body = files.value(path);
            sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: "
                        + QByteArray::number(body.size()) + "\r\n\r\n");
            sock->write(body);
        }
        sock->flush();
        sock->disconnectFromHost();
    }
};

// ── silent decoding ─────────────────────────────────────────────────────────

struct Decoded {
    QMediaPlayer::MediaStatus status = QMediaPlayer::NoMedia;
    QMediaPlayer::Error       error  = QMediaPlayer::NoError;
    QString errorString;
    qint64  duration = 0;
    bool    hasAudio = false;
    qint64  frames   = 0;    // decoded sample frames, 0 unless the samples were read
    double  peak     = 0.0;  // largest absolute sample, full scale = 1.0
    double  toneHz   = 0.0;  // from zero crossings, so only meaningful for a tone
};

QString statusName(QMediaPlayer::MediaStatus s)
{
    switch (s) {
    case QMediaPlayer::NoMedia:        return QStringLiteral("NoMedia");
    case QMediaPlayer::LoadingMedia:   return QStringLiteral("LoadingMedia");
    case QMediaPlayer::LoadedMedia:    return QStringLiteral("LoadedMedia");
    case QMediaPlayer::StalledMedia:   return QStringLiteral("StalledMedia");
    case QMediaPlayer::BufferingMedia: return QStringLiteral("BufferingMedia");
    case QMediaPlayer::BufferedMedia:  return QStringLiteral("BufferedMedia");
    case QMediaPlayer::EndOfMedia:     return QStringLiteral("EndOfMedia");
    case QMediaPlayer::InvalidMedia:   return QStringLiteral("InvalidMedia");
    }
    return QStringLiteral("?");
}

// Plays a local file through a QMediaPlayer with no audio output at all, so it
// is silent by construction rather than by a volume someone can change.
Decoded decodeSilently(const QString &path, int timeoutMs = 20000)
{
    Decoded out;
    QMediaPlayer player;
    QEventLoop loop;

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // Qt 6.4's GStreamer backend only links the decoded audio when an output is
    // attached, and reports InvalidMedia without one. Muted at zero volume.
    QAudioOutput muted;
    muted.setMuted(true);
    muted.setVolume(0.0f);
    player.setAudioOutput(&muted);
#endif

#if TIDALWAVE_HAS_BUFFER_OUTPUT
    QAudioBufferOutput tap;
    player.setAudioBufferOutput(&tap);
    int    rate      = 0;
    qint64 crossings = 0;
    double prev      = 0.0;
    QObject::connect(&tap, &QAudioBufferOutput::audioBufferReceived,
                     [&](const QAudioBuffer &b) {
        const QAudioFormat fmt = b.format();
        if (!fmt.isValid() || b.frameCount() <= 0) return;   // the end-of-stream one
        if (rate == 0) rate = fmt.sampleRate();
        const int ch = fmt.channelCount();
        for (int i = 0; i < b.frameCount(); ++i) {
            double v = 0.0;
            switch (fmt.sampleFormat()) {
            case QAudioFormat::Float: v = b.constData<float>()[i * ch]; break;
            case QAudioFormat::Int32: v = b.constData<qint32>()[i * ch] / 2147483648.0; break;
            case QAudioFormat::Int16: v = b.constData<qint16>()[i * ch] / 32768.0; break;
            default: break;
            }
            if (std::fabs(v) > out.peak) out.peak = std::fabs(v);
            if ((prev < 0.0 && v >= 0.0) || (prev >= 0.0 && v < 0.0)) ++crossings;
            prev = v;
        }
        out.frames += b.frameCount();
    });
#endif

    QObject::connect(&player, &QMediaPlayer::mediaStatusChanged,
                     [&loop](QMediaPlayer::MediaStatus s) {
        if (s == QMediaPlayer::InvalidMedia || s == QMediaPlayer::EndOfMedia)
            QTimer::singleShot(50, &loop, &QEventLoop::quit);
    });

    QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
    player.setSource(QUrl::fromLocalFile(path));
    player.play();
    loop.exec();

    out.status      = player.mediaStatus();
    out.error       = player.error();
    out.errorString = player.errorString();
    out.duration    = player.duration();
    out.hasAudio    = player.hasAudio();
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    if (out.frames > 0 && rate > 0)
        out.toneHz = (double(crossings) * rate) / (2.0 * double(out.frames));
#endif
    return out;
}

// Runs a fetcher to completion. Returns the path of the joined file, which the
// caller owns and must remove; error is set instead when there is none.
QString joinThroughFetcher(TidalClient *client, const QString &mpd, QString *error,
                           int *partCount = nullptr)
{
    DashFetcher fetcher(client, mpd);
    if (partCount) *partCount = fetcher.partCount();
    if (!fetcher.isValid())        { *error = QStringLiteral("manifest did not expand"); return {}; }
    if (!fetcher.openedTempFile()) { *error = QStringLiteral("no temp file"); return {}; }

    bool done = false;
    QString path;
    fetcher.start([&](QTemporaryFile *file, const QString &err) {
        done   = true;
        *error = err;
        if (file) {
            path = file->fileName();
            delete file;        // autoRemove is off, so the bytes stay behind
        }
    });

    if (!QTest::qWaitFor([&done] { return done; }, 20000))
        *error = QStringLiteral("timed out waiting for the segments");
    return path;
}

} // namespace

class TestDash : public QObject {
    Q_OBJECT

private slots:
    // ── the fixture, before anything that leans on it ───────────────────────

    // Everything below trusts these bytes. If the fixture were silence, the wrong
    // length, or not actually joinable, this is what says so - and it says it
    // without going through DashFetcher at all, so a bug there cannot hide here.
    void theFixtureIsOneSecondOf440HzFlacInFragmentsThatJoinUp()
    {
        QVERIFY(!initSegment().isEmpty());
        QVERIFY(!mediaSegment1().isEmpty());
        QVERIFY(!mediaSegment2().isEmpty());
        QVERIFY(!mediaSegment3().isEmpty());
        // Fragmented MP4: the init segment opens with an ftyp box, a media
        // segment with styp or moof.
        QCOMPARE(initSegment().mid(4, 4), QByteArray("ftyp"));
        QVERIFY(mediaSegment1().mid(4, 4) == QByteArray("styp")
                || mediaSegment1().mid(4, 4) == QByteArray("moof"));

        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("by-hand.mp4"));
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        QCOMPARE(f.write(joinedByHand()), qint64(joinedByHand().size()));
        f.close();

        const Decoded d = decodeSilently(path);
        QCOMPARE(d.status, QMediaPlayer::EndOfMedia);
        QCOMPARE(d.error, QMediaPlayer::NoError);
        QCOMPARE(d.duration, 1000);
        QVERIFY(d.hasAudio);
#if TIDALWAVE_HAS_BUFFER_OUTPUT
        QCOMPARE(d.frames, 44100);
        QVERIFY2(std::fabs(d.toneHz - 440.0) < 5.0,
                 qPrintable(QStringLiteral("tone came out at %1 Hz").arg(d.toneHz)));
        QVERIFY2(std::fabs(d.peak - 0.125) < 0.01,
                 qPrintable(QStringLiteral("peak sample %1").arg(d.peak)));
#endif
    }

    // ── manifest expansion ─────────────────────────────────────────────────

    void tidalsOwnShapeExpandsToOneInitAndOneUrlPerSegment()
    {
        const QStringList urls = DashFetcher::parseSegmentUrls(
            withBase(kTidalManifest, QStringLiteral("https://sp-ad.audio.tidal.com/")));
        QCOMPARE(urls.size(), 4);
        // &amp; has to come back as '&': Tidal's segment URLs are all presigned,
        // and one without its query intact names a different object.
        QCOMPARE(urls.at(0),
                 QStringLiteral("https://sp-ad.audio.tidal.com/init.mp4?token=abc&exp=99"));
        QCOMPARE(urls.at(1),
                 QStringLiteral("https://sp-ad.audio.tidal.com/seg-1.mp4?token=abc&exp=99"));
        QCOMPARE(urls.at(3),
                 QStringLiteral("https://sp-ad.audio.tidal.com/seg-3.mp4?token=abc&exp=99"));
    }

    void aPackagersPaddedNumberAndRepresentationIdAreSubstituted()
    {
        const QStringList urls = DashFetcher::parseSegmentUrls(
            withBase(kPackagerManifest, QStringLiteral("http://h/")));
        QCOMPARE(urls.size(), 4);
        QCOMPARE(urls.at(0), QStringLiteral("http://h/init-stream0.m4s"));
        QCOMPARE(urls.at(1), QStringLiteral("http://h/chunk-stream0-00001.m4s"));
        QCOMPARE(urls.at(3), QStringLiteral("http://h/chunk-stream0-00003.m4s"));
    }

    void startNumberMovesTheWholeRunNotJustTheFirstSegment()
    {
        const QStringList urls = DashFetcher::parseSegmentUrls(
            withBase(kStartNumberManifest, kTestHost));
        QCOMPARE(urls.size(), 4);
        QCOMPARE(urls.at(1), QStringLiteral("http://h/7.mp4"));
        QCOMPARE(urls.at(3), QStringLiteral("http://h/9.mp4"));
    }

    void aFixedSegmentDurationIsCountedOffTheTotalInstead()
    {
        const QStringList urls = DashFetcher::parseSegmentUrls(
            withBase(kFixedDurationManifest, kTestHost));
        QCOMPARE(urls.size(), 8);
        QCOMPARE(urls.at(7), QStringLiteral("http://h/7.mp4"));
    }

    void anIdentifierThisCannotExpandRefusesTheWholeManifest()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kTimeIdentifierManifest, kTestHost)).isEmpty());
    }

    // One assertion per function, not six QVERIFYs in a row: QVERIFY stops at the
    // first that fails, so grouped refusals cannot be shown to bite one by one.
    void aManifestWithNoSegmentTemplateIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kNoTemplateManifest, kTestHost)).isEmpty());
    }

    void aTemplateWithNoInitializationSegmentIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kNoInitManifest, kTestHost)).isEmpty());
    }

    void aTimelineThatNamesNoSegmentsIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kEmptyTimelineManifest, kTestHost)).isEmpty());
    }

    void aManifestClaimingAnAbsurdSegmentCountIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kAbsurdCountManifest, kTestHost)).isEmpty());
    }

    void anAbsurdCountReachedThroughTheDurationFallbackIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kAbsurdDurationManifest, kTestHost)).isEmpty());
    }

    void aLiveManifestIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kLiveManifest, kTestHost)).isEmpty());
    }

    // The BTS manifest is JSON. A manifestMimeType the app does not recognise
    // comes down the DASH branch, so this is reachable.
    void theBtsJsonManifestIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(
            withBase(kBtsManifestJson, kTestHost)).isEmpty());
    }

    void nothingAtAllIsRefused()
    {
        QVERIFY(DashFetcher::parseSegmentUrls(QString()).isEmpty());
    }

    // ── end to end ─────────────────────────────────────────────────────────

    // The whole point, on this Qt: a DASH stream plays.
    void aDashStreamPlaysOnceItsSegmentsAreJoined()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.files[QStringLiteral("/init-stream0.m4s")]        = initSegment();
        srv.files[QStringLiteral("/chunk-stream0-00001.m4s")] = mediaSegment1();
        srv.files[QStringLiteral("/chunk-stream0-00002.m4s")] = mediaSegment2();
        srv.files[QStringLiteral("/chunk-stream0-00003.m4s")] = mediaSegment3();

        TidalApi api;
        TidalClient client{&api};
        QString err;
        int parts = 0;
        const QString joined = joinThroughFetcher(
            &client, withBase(kPackagerManifest, srv.base()), &err, &parts);
        QVERIFY2(err.isEmpty(), qPrintable(err));
        QCOMPARE(parts, 4);
        QVERIFY(!joined.isEmpty());

        // Byte for byte the segments in play order, which is the one thing the
        // fetcher is for.
        QFile f(joined);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll(), joinedByHand());
        f.close();

        // For the record, and deliberately not an assertion: on a Qt whose
        // libavformat does have libxml2 the backend opens the manifest quite
        // happily. The fix is that it no longer has to, so what is asserted is
        // the part below - the joined file plays, on every build.
        {
            QTemporaryDir dir;
            QVERIFY(dir.isValid());
            for (auto it = srv.files.cbegin(); it != srv.files.cend(); ++it) {
                QFile s(dir.filePath(it.key().mid(1)));
                QVERIFY(s.open(QIODevice::WriteOnly));
                s.write(it.value());
            }
            const QString mpdPath = dir.filePath(QStringLiteral("stream.mpd"));
            QFile m(mpdPath);
            QVERIFY(m.open(QIODevice::WriteOnly));
            m.write(withBase(kPackagerManifest, QString()).toUtf8());
            m.close();
            const Decoded manifestRun = decodeSilently(mpdPath, 5000);
            qInfo().noquote() << "the old path, handing QMediaPlayer the manifest:"
                              << statusName(manifestRun.status)
                              << manifestRun.errorString
                              << "- decoded frames" << manifestRun.frames;
        }

        const Decoded d = decodeSilently(joined);
        QFile::remove(joined);
        QCOMPARE(d.status, QMediaPlayer::EndOfMedia);
        QCOMPARE(d.error, QMediaPlayer::NoError);
        QCOMPARE(d.duration, 1000);
        QVERIFY(d.hasAudio);
#if TIDALWAVE_HAS_BUFFER_OUTPUT
        QCOMPARE(d.frames, 44100);
        QVERIFY2(std::fabs(d.toneHz - 440.0) < 5.0,
                 qPrintable(QStringLiteral("tone came out at %1 Hz").arg(d.toneHz)));
        QVERIFY2(std::fabs(d.peak - 0.125) < 0.01,
                 qPrintable(QStringLiteral("peak sample %1").arg(d.peak)));
#endif
    }

    // Tidal's shape, over the wire, presigned query string and all.
    void tidalsOwnManifestShapePlaysEndToEnd()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.files[QStringLiteral("/init.mp4")]  = initSegment();
        srv.files[QStringLiteral("/seg-1.mp4")] = mediaSegment1();
        srv.files[QStringLiteral("/seg-2.mp4")] = mediaSegment2();
        srv.files[QStringLiteral("/seg-3.mp4")] = mediaSegment3();

        TidalApi api;
        TidalClient client{&api};
        QString err;
        const QString joined =
            joinThroughFetcher(&client, withBase(kTidalManifest, srv.base()), &err);
        QVERIFY2(err.isEmpty(), qPrintable(err));
        QVERIFY(!joined.isEmpty());

        // The query really was sent, unescaped, on every segment.
        QCOMPARE(srv.requested.size(), 4);
        for (const QString &target : srv.requested)
            QVERIFY2(target.endsWith(QStringLiteral("?token=abc&exp=99")),
                     qPrintable(target));

        const Decoded d = decodeSilently(joined);
        QFile::remove(joined);
        QCOMPARE(d.status, QMediaPlayer::EndOfMedia);
        QCOMPARE(d.duration, 1000);
#if TIDALWAVE_HAS_BUFFER_OUTPUT
        QCOMPARE(d.frames, 44100);
        QVERIFY2(std::fabs(d.toneHz - 440.0) < 5.0,
                 qPrintable(QStringLiteral("tone came out at %1 Hz").arg(d.toneHz)));
#endif
    }

    // Six segments are in flight at once, so they finish in whatever order the
    // network hands them back. Writing them as they arrive would make a file of
    // exactly the right size that will not play.
    void segmentsThatArriveBackwardsAreStillWrittenInPlayOrder()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.files[QStringLiteral("/init-stream0.m4s")]        = initSegment();
        srv.files[QStringLiteral("/chunk-stream0-00001.m4s")] = mediaSegment1();
        srv.files[QStringLiteral("/chunk-stream0-00002.m4s")] = mediaSegment2();
        srv.files[QStringLiteral("/chunk-stream0-00003.m4s")] = mediaSegment3();
        // Exactly backwards: the last segment answers first, the initialization
        // segment last.
        srv.delaysMs[QStringLiteral("/init-stream0.m4s")]        = 400;
        srv.delaysMs[QStringLiteral("/chunk-stream0-00001.m4s")] = 300;
        srv.delaysMs[QStringLiteral("/chunk-stream0-00002.m4s")] = 200;
        srv.delaysMs[QStringLiteral("/chunk-stream0-00003.m4s")] = 100;

        TidalApi api;
        TidalClient client{&api};
        QString err;
        const QString joined = joinThroughFetcher(
            &client, withBase(kPackagerManifest, srv.base()), &err);
        QVERIFY2(err.isEmpty(), qPrintable(err));

        QFile f(joined);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll(), joinedByHand());
        f.close();

        const Decoded d = decodeSilently(joined);
        QFile::remove(joined);
        QCOMPARE(d.status, QMediaPlayer::EndOfMedia);
        QCOMPARE(d.duration, 1000);
#if TIDALWAVE_HAS_BUFFER_OUTPUT
        QCOMPARE(d.frames, 44100);
#endif
    }

    // A segment that will not come back has to end as something the caller can
    // put in front of the user, not as a short file that plays half a track.
    void aSegmentThatIsNotThereFailsWithAReasonAndLeavesNoFile()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.files[QStringLiteral("/init-stream0.m4s")]        = initSegment();
        srv.files[QStringLiteral("/chunk-stream0-00001.m4s")] = mediaSegment1();
        srv.files[QStringLiteral("/chunk-stream0-00003.m4s")] = mediaSegment3();
        // chunk 2 is simply not served, so it answers 404.

        TidalApi api;
        TidalClient client{&api};

        DashFetcher fetcher(&client, withBase(kPackagerManifest, srv.base()));
        QVERIFY(fetcher.isValid());
        QVERIFY(fetcher.openedTempFile());
        const QString halfWritten = fetcher.tempFilePath();
        QVERIFY(QFile::exists(halfWritten));

        bool done = false;
        bool gotFile = true;
        QString err;
        fetcher.start([&](QTemporaryFile *file, const QString &e) {
            done    = true;
            gotFile = (file != nullptr);
            err     = e;
            delete file;
        });
        QTRY_VERIFY_WITH_TIMEOUT(done, 20000);
        QVERIFY2(!gotFile, "a 404 on a segment produced a file anyway");
        QVERIFY2(!err.isEmpty(), "the failure came back with nothing to tell the user");
        // Whatever segments did arrive before the gap are not a half track to
        // leave lying in /tmp.
        QVERIFY2(!QFile::exists(halfWritten),
                 qPrintable(QStringLiteral("%1 was left behind").arg(halfWritten)));
    }

    // Dropping a fetcher mid-flight is what every track change does. It must not
    // land on a callback into a dead object, and must not leave its temp file.
    void droppingAFetcherWhileSegmentsAreInFlightIsSafe()
    {
        SegmentServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.files[QStringLiteral("/init-stream0.m4s")]        = initSegment();
        srv.files[QStringLiteral("/chunk-stream0-00001.m4s")] = mediaSegment1();
        srv.files[QStringLiteral("/chunk-stream0-00002.m4s")] = mediaSegment2();
        srv.files[QStringLiteral("/chunk-stream0-00003.m4s")] = mediaSegment3();
        const QStringList paths = srv.files.keys();
        for (const QString &p : paths)
            srv.delaysMs[p] = 400;

        TidalApi api;
        TidalClient client{&api};

        QString tempPath;
        bool reported = false;
        {
            auto fetcher = std::make_unique<DashFetcher>(
                &client, withBase(kPackagerManifest, srv.base()));
            QVERIFY(fetcher->isValid());
            QVERIFY(fetcher->openedTempFile());
            tempPath = fetcher->tempFilePath();
            QVERIFY(QFile::exists(tempPath));
            fetcher->start([&reported](QTemporaryFile *f, const QString &) {
                reported = true;
                delete f;
            });
            QTest::qWait(50);     // let the requests get out, then drop it
        }
        QTest::qWait(900);        // long enough for every answer to have arrived
        QVERIFY2(!reported, "a dropped fetcher called back anyway");
        QVERIFY2(!QFile::exists(tempPath),
                 qPrintable(QStringLiteral("%1 was left behind").arg(tempPath)));
    }
};

QTEST_MAIN(TestDash)
#include "tst_dash.moc"
