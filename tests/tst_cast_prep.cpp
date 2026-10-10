// Preparing a lossless track for a Chromecast without asking ffmpeg to demux DASH.
//
// CastMediaPrep was the third site with the shape that was the release blocker on
// the playback path: write Tidal's DASH manifest out to a .mpd, hand the file to
// the CLI ffmpeg behind -protocol_whitelist, and leave ffmpeg to fetch the
// segments itself. That needs ffmpeg's DASH demuxer, which is only built when
// libxml2 is present. It now joins the segments through DashFetcher and hands
// ffmpeg an ordinary fragmented MP4.
//
// WHAT THIS CANNOT PROVE, AND SAYS SO INSTEAD OF PRETENDING: the libxml2
// dependency is latent on this machine, not live. The CLI ffmpeg here
// (/lib64/libavformat.so.58.76.100) *does* have the dash demuxer, which is why
// casting kept working while playback did not. So a test asserting "the output
// decodes" passes before the fix as well, and would be worthless.
//
// What it asserts instead is the property that actually changed and that holds
// everywhere: the bytes ffmpeg reads were fetched by the app, through the app's
// own authenticated requests, and are already on local disk by the time ffmpeg
// starts. The segment server answers only requests carrying the X-Tidal-Token
// header that TidalApi::makeRequest sets. The app's own fetches have it; the CLI
// ffmpeg's do not. So after the fix the join succeeds and ffmpeg never touches
// the network, and before it ffmpeg is the only fetcher, is refused, and the
// preparation fails. That is red for the right reason on any machine, libxml2 or
// not.
//
// The fixture is tst_dash's: one second of a 440 Hz tone as 16-bit mono FLAC in
// fragmented MP4, from ffmpeg's own dash muxer. FLAC-in-MP4 is what Tidal
// delivers, and -c:a copy to a native .flac is what the cast path does with it.
// NOTHING HERE MAKES A SOUND: no QAudioOutput is constructed (on Qt 6.4 a muted
// one is, see the probe) and nothing is ever played; the output is read back
// only for its container and its duration.

#include <QTest>
#include <QAudioOutput>
#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QMediaPlayer>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>

#include "api/Models.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "cast/CastMediaPrep.h"

// @BASE@ rather than the host written out: moc honours a // comment inside a raw
// string literal, so a "http://host/" plus a quote in here makes it lose track of
// where strings end and fail the build pointing at an unrelated line. The house
// rule is in tst_dash.cpp, from the same bruise.
//
// profiles= is load-bearing and not decoration. Without it ffmpeg's own DASH
// demuxer refuses the manifest with "Invalid data found when processing input"
// before it makes a single request, which would make the pre-fix comparison
// below red for the wrong reason - the point is to watch ffmpeg go to the network
// and be turned away, not to watch it fail to parse. Tidal's real manifests carry
// it (see tst_dash.cpp), so this is the honest shape.
constexpr auto kManifest = R"MPD(<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static"
     minBufferTime="PT1.500S" mediaPresentationDuration="PT0H0M1.000S">
  <Period id="0">
    <AdaptationSet id="0" contentType="audio" mimeType="audio/mp4">
      <Representation id="1" codecs="flac" bandwidth="1070000" audioSamplingRate="44100">
        <SegmentTemplate timescale="44100" startNumber="1"
                         initialization="@BASE@init.mp4"
                         media="@BASE@seg-$Number$.mp4">
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

namespace {

#include "dash_fixture.inc"

QByteArray initSegment()   { return QByteArray::fromBase64(QByteArray(kInitB64)); }
QByteArray mediaSegment1() { return QByteArray::fromBase64(QByteArray(kSeg1B64)); }
QByteArray mediaSegment2() { return QByteArray::fromBase64(QByteArray(kSeg2B64)); }
QByteArray mediaSegment3() { return QByteArray::fromBase64(QByteArray(kSeg3B64)); }

// Serves the segments to the app and to nobody else.
//
// The gate is the X-Tidal-Token header, which TidalApi::makeRequest puts on every
// request and the CLI ffmpeg has no way to send. It is the whole discriminator of
// this file: it is what makes "we fetched the bytes" and "ffmpeg fetched the
// bytes" two different, observable outcomes on a machine where both would
// otherwise work.
class GatedSegmentServer : public QTcpServer {
public:
    explicit GatedSegmentServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &GatedSegmentServer::accept);
    }

    QHash<QString, QByteArray> files;      // path -> bytes
    int served   = 0;                      // answered, with the app's header
    int refused  = 0;                      // asked for without it

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
                const int end = buf->indexOf("\r\n\r\n");
                if (end < 0) return;                    // headers still arriving
                const QByteArray head = buf->left(end);
                buf->clear();
                const QByteArray line = head.left(head.indexOf("\r\n"));
                const int sp1 = line.indexOf(' ');
                const int sp2 = line.indexOf(' ', sp1 + 1);
                if (sp1 < 0 || sp2 < 0) { sock->disconnectFromHost(); return; }
                QString path = QString::fromUtf8(line.mid(sp1 + 1, sp2 - sp1 - 1));
                const int q = path.indexOf(QLatin1Char('?'));
                if (q >= 0) path = path.left(q);

                const bool fromTheApp =
                    head.contains("X-Tidal-Token") || head.contains("x-tidal-token");
                if (!fromTheApp) {
                    ++refused;
                    sock->write("HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
                } else if (!files.contains(path)) {
                    sock->write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                } else {
                    ++served;
                    const QByteArray body = files.value(path);
                    sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\n"
                                "Content-Length: " + QByteArray::number(body.size())
                                + "\r\n\r\n");
                    sock->write(body);
                }
                sock->flush();
                sock->disconnectFromHost();
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
};

} // namespace

class TestCastPrep : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        // The cast path shells out, so without ffmpeg there is nothing to say.
        // This is not a soft skip in disguise: ffmpeg is present on this machine
        // and in CI, and a skip here would be worth chasing.
        m_ffmpeg = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    }

    void aLosslessTrackIsJoinedHereAndHandedToFfmpegAsALocalFile()
    {
        if (m_ffmpeg.isEmpty())
            QSKIP("no ffmpeg on PATH, and the cast path is a conversion");

        GatedSegmentServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        server.files.insert(QStringLiteral("/init.mp4"),  initSegment());
        server.files.insert(QStringLiteral("/seg-1.mp4"), mediaSegment1());
        server.files.insert(QStringLiteral("/seg-2.mp4"), mediaSegment2());
        server.files.insert(QStringLiteral("/seg-3.mp4"), mediaSegment3());

        QString mpd = QString::fromUtf8(kManifest);
        mpd.replace(QStringLiteral("@BASE@"), server.base());

        Tidal::StreamManifest manifest;
        manifest.type       = Tidal::StreamManifest::MPD;
        manifest.url        = mpd;
        manifest.mimeType   = QStringLiteral("application/dash+xml");
        manifest.codec      = QStringLiteral("LOSSLESS");
        manifest.sampleRate = 44100;

        TidalApi      api;
        TidalClient   client{&api};
        CastMediaPrep prep{&client};

        QSignalSpy ready(&prep, &CastMediaPrep::ready);
        QSignalSpy failed(&prep, &CastMediaPrep::failed);

        prep.prepareFromManifest(manifest);
        QTRY_VERIFY_WITH_TIMEOUT(ready.count() + failed.count() > 0, 30000);

        QVERIFY2(failed.isEmpty(),
                 qPrintable(QStringLiteral("preparing the track failed: %1 "
                                           "(we fetched %2 segments, and %3 requests "
                                           "arrived without the app's headers)")
                            .arg(failed.isEmpty() ? QString()
                                                  : failed.first().at(0).toString())
                            .arg(server.served).arg(server.refused)));
        QCOMPARE(ready.count(), 1);

        // Four requests, every one of them ours. The old shape made none: it
        // wrote the manifest to a .mpd and left ffmpeg to go and get them.
        QCOMPARE(server.served, 4);
        QVERIFY2(server.refused == 0,
                 qPrintable(QStringLiteral("%1 segment requests arrived without the "
                                           "app's headers, so something other than "
                                           "the app went to the network for them")
                            .arg(server.refused)));

        const QString path = ready.first().at(0).toString();
        const QString mime = ready.first().at(1).toString();
        QCOMPARE(mime, QStringLiteral("audio/flac"));

        QFile out(path);
        QVERIFY2(out.exists(), "the path handed to the receiver is not there");
        QVERIFY(out.open(QIODevice::ReadOnly));
        const QByteArray magic = out.read(4);
        const qint64     size  = out.size();
        out.close();
        QCOMPARE(magic, QByteArrayLiteral("fLaC"));

        // Not an empty container: an input ffmpeg could not read used to leave a
        // file that existed and held nothing. A second of 16-bit mono 44.1 kHz
        // FLAC is about 20 kB, so anything near zero is that failure.
        //
        // Not asserted on the duration, because there is none to assert on:
        // -c:a copy writes the FLAC header before it knows the sample count, so
        // the stream says "Duration: N/A" and QMediaPlayer reports 0. That is
        // true of this path before and after the change and is noted here so the
        // next person does not take it for a regression.
        QVERIFY2(size > 10000 && size < 100000,
                 qPrintable(QStringLiteral("the converted track is %1 bytes, not the "
                                           "~20 kB a second of this fixture makes")
                            .arg(size)));

        // And it is a stream a receiver could decode. Loaded, never played, with
        // no audio output attached, so no device is opened.
        QMediaPlayer probe;
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // Except on Qt 6.4, whose GStreamer backend reports InvalidMedia unless
        // the decoded audio has an output to link to. Muted, and never played.
        QAudioOutput muted;
        muted.setMuted(true);
        muted.setVolume(0.0f);
        probe.setAudioOutput(&muted);
#endif
        probe.setSource(QUrl::fromLocalFile(path));
        QTRY_VERIFY_WITH_TIMEOUT(probe.mediaStatus() == QMediaPlayer::LoadedMedia
                                 || probe.mediaStatus() == QMediaPlayer::BufferedMedia
                                 || probe.mediaStatus() == QMediaPlayer::InvalidMedia,
                                 10000);
        QVERIFY2(probe.mediaStatus() != QMediaPlayer::InvalidMedia,
                 qPrintable(QStringLiteral("the converted file will not open: %1")
                            .arg(probe.errorString())));
        QVERIFY2(probe.hasAudio(), "the converted file carries no audio stream");
        probe.setSource(QUrl());

        // cancel() is what CastManager calls when the user stops casting, and it
        // is the only thing that removes the converted file.
        prep.cancel();
        QVERIFY2(!QFile::exists(path),
                 "the converted file outlived the cast it was made for");
    }

    // A manifest this cannot expand must say that, rather than reporting a
    // network fault for a URL it left an identifier in.
    void aManifestTheJoinCannotExpandIsRefusedAsSuch()
    {
        Tidal::StreamManifest manifest;
        manifest.type       = Tidal::StreamManifest::MPD;
        manifest.url        = QStringLiteral("<MPD></MPD>");
        manifest.codec      = QStringLiteral("LOSSLESS");
        manifest.sampleRate = 44100;

        TidalApi      api;
        TidalClient   client{&api};
        CastMediaPrep prep{&client};

        QSignalSpy ready(&prep, &CastMediaPrep::ready);
        QSignalSpy failed(&prep, &CastMediaPrep::failed);

        prep.prepareFromManifest(manifest);
        QTRY_VERIFY_WITH_TIMEOUT(failed.count() == 1, 5000);
        QCOMPARE(ready.count(), 0);
        QCOMPARE(failed.first().at(0).toString(),
                 QStringLiteral("Could not read the lossless stream details for this track."));
    }

private:
    QString m_ffmpeg;
};

QTEST_MAIN(TestCastPrep)
#include "tst_cast_prep.moc"
