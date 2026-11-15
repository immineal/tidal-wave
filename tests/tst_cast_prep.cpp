// Preparing a lossless track for a Chromecast without ffmpeg's DASH demuxer.
// The segment server answers only requests carrying the User-Agent header
// that TidalApi::makeRequest sets, so the test proves the app fetched the
// bytes and ffmpeg read a local file. Checking only that the output decodes
// would pass wherever ffmpeg has the demuxer. The fixture is tst_dash's: one
// second of FLAC in fragmented MP4. Nothing is played. The AAC case gets its
// manifests from a localhost stand-in for Tidal, with tst_aac_only's fixture.

#include <QTest>
#include <QAudioOutput>
#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QMediaPlayer>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <memory>
#include <utility>

#include "api/Models.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "cast/CastMediaPrep.h"

// @BASE@ and no host written out: moc honours a // comment inside a raw string
// literal and loses track of where strings end. profiles= is required: without
// it ffmpeg's DASH demuxer refuses the manifest before it makes a request.
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

// Serves the segments only to requests with the browser User-Agent that
// TidalApi::makeRequest sets. The CLI ffmpeg names itself Lavf.
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

                const bool fromTheApp = head.toLower().contains("user-agent: mozilla/");
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

#include "aac_dash_fixture.inc"

constexpr qlonglong kAacTrack = 100000002;

// Tidal's manifest for a track it has only in AAC, as in tst_aac_only.
QByteArray aacManifest(const QString &base)
{
    return "<?xml version='1.0' encoding='UTF-8'?>"
           "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" "
                "profiles=\"urn:mpeg:dash:profile:isoff-main:2011\" type=\"static\" "
                "minBufferTime=\"PT0.697S\" mediaPresentationDuration=\"PT2.000S\">"
           "<Period id=\"0\">"
           "<AdaptationSet id=\"0\" contentType=\"audio\" mimeType=\"audio/mp4\">"
           "<Representation id=\"AACLC\" codecs=\"mp4a.40.2\" "
                           "bandwidth=\"321589\" audioSamplingRate=\"44100\">"
           "<SegmentTemplate timescale=\"44100\" "
               "initialization=\"" + base.toUtf8() + "0.mp4\" "
               "media=\"" + base.toUtf8() + "$Number$.mp4\" startNumber=\"1\">"
           "<SegmentTimeline><S d=\"30720\"/><S d=\"31744\"/><S d=\"25736\"/></SegmentTimeline>"
           "</SegmentTemplate></Representation></AdaptationSet></Period></MPD>";
}

QByteArray aacAnswer(const QString &base)
{
    const QJsonObject attributes{
        {"trackPresentation", QStringLiteral("FULL")},
        {"formats", QJsonArray{QStringLiteral("AACLC")}},
        {"uri", QStringLiteral("data:application/dash+xml;base64,")
                    + QString::fromLatin1(aacManifest(base).toBase64())},
    };
    return QJsonDocument(QJsonObject{
        {"data", QJsonObject{{"id", QString::number(kAacTrack)},
                             {"type", QStringLiteral("trackManifests")},
                             {"attributes", attributes}}},
    }).toJson();
}

// Tidal's refusal of a request for FLAC when the track has none.
QByteArray noFlacRefusal()
{
    return QJsonDocument(QJsonObject{{"errors", QJsonArray{QJsonObject{
        {"code", QStringLiteral("CLIENT_NOT_ENTITLED")},
        {"detail", QStringLiteral("refused")},
        {"status", QStringLiteral("403")}}}}}).toJson();
}

// Tidal on localhost: the manifest endpoint answers in turn, any other path
// is a file.
class AacOrigin : public QTcpServer {
public:
    AacOrigin()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    if (buf->indexOf("\r\n\r\n") < 0) return;
                    const QString target = QString::fromUtf8(
                        buf->left(buf->indexOf("\r\n")).split(' ').value(1));
                    buf->clear();
                    const qsizetype mark = target.indexOf(QLatin1Char('?'));
                    const QString path = mark < 0 ? target : target.left(mark);
                    Answer a{404, QByteArray()};
                    if (path.startsWith(QStringLiteral("/trackManifests/"))) {
                        manifestQueries << (mark < 0 ? QString() : target.mid(mark + 1));
                        a = manifestAnswers.isEmpty() ? Answer{500, "{}"}
                                                      : manifestAnswers.takeFirst();
                    } else if (files.contains(path)) {
                        a = {200, files.value(path)};
                    }
                    sock->write("HTTP/1.0 " + QByteArray::number(a.first) + " Answer\r\n"
                                "Content-Length: " + QByteArray::number(a.second.size())
                                + "\r\n\r\n" + a.second);
                    sock->flush();
                    sock->disconnectFromHost();
                });
            }
        });
    }

    using Answer = std::pair<int, QByteArray>;
    QList<Answer>              manifestAnswers;
    QStringList                manifestQueries;
    QHash<QString, QByteArray> files;

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }
};

// The real TidalApi with every request to Tidal sent to `local`.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

} // namespace

class TestCastPrep : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        // The cast path shells out to ffmpeg. CI has it, so a skip is worth
        // chasing.
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

        // Four requests, every one of them from the app.
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

        // An input ffmpeg cannot read leaves a near-empty file; a second of this
        // fixture is about 20 kB. No duration check: -c:a copy writes the FLAC
        // header before the sample count is known, so QMediaPlayer reports 0.
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

    // A track Tidal has only in AAC. The player takes the AAC where the FLAC
    // it asked for is refused, and a cast has to as well.
    void aTrackTidalHasOnlyInAacIsCastInAac()
    {
        AacOrigin origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost));
        const QString audio = origin.base() + QStringLiteral("audio/");
        origin.files.insert(QStringLiteral("/audio/0.mp4"), QByteArray::fromBase64(kAacDashInitB64));
        origin.files.insert(QStringLiteral("/audio/1.mp4"), QByteArray::fromBase64(kAacDashSeg1B64));
        origin.files.insert(QStringLiteral("/audio/2.mp4"), QByteArray::fromBase64(kAacDashSeg2B64));
        origin.files.insert(QStringLiteral("/audio/3.mp4"), QByteArray::fromBase64(kAacDashSeg3B64));
        origin.manifestAnswers = {{403, noFlacRefusal()}, {200, aacAnswer(audio)}};

        LocalApi api;
        api.local = origin.base();
        TidalClient client{&api};
        client.setAudioQuality(AudioQuality::Lossless);
        CastMediaPrep prep{&client};

        QSignalSpy ready(&prep, &CastMediaPrep::ready);
        QSignalSpy failed(&prep, &CastMediaPrep::failed);
        prep.prepare(kAacTrack);
        QTRY_VERIFY_WITH_TIMEOUT(ready.count() + failed.count() > 0, 30000);

        QVERIFY2(failed.isEmpty(),
                 qPrintable(QStringLiteral("casting an AAC-only track failed: %1 (manifest "
                                           "queries: %2)")
                            .arg(failed.isEmpty() ? QString() : failed.first().at(0).toString(),
                                 origin.manifestQueries.join(QStringLiteral(" | ")))));
        // The ladder the player climbs: its own setting first, then AAC.
        QCOMPARE(origin.manifestQueries.size(), 2);
        QVERIFY(origin.manifestQueries.at(0).contains(QStringLiteral("formats=FLAC")));
        QVERIFY(!origin.manifestQueries.at(0).contains(QStringLiteral("FLAC_HIRES")));
        QVERIFY(origin.manifestQueries.at(1).contains(QStringLiteral("formats=AACLC")));

        const QString path = ready.first().at(0).toString();
        QCOMPARE(ready.first().at(1).toString(), QStringLiteral("audio/mp4"));
        QFile out(path);
        QVERIFY(out.open(QIODevice::ReadOnly));
        const QByteArray head = out.read(8);
        out.close();
        QCOMPARE(head.mid(4, 4), QByteArrayLiteral("ftyp"));

        prep.cancel();
        QVERIFY2(!QFile::exists(path), "the cast file outlived the cast it was made for");
    }

    // The file of one track goes when the next one replaces it, not only when
    // the cast ends.
    void theNextTrackRemovesTheFileOfTheLastOne()
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
        manifest.codec      = QStringLiteral("LOSSLESS");
        manifest.sampleRate = 44100;

        // The second track's manifest request goes to a port nobody listens on.
        LocalApi      api;
        api.local = QStringLiteral("http://127.0.0.1:1/");
        TidalClient   client{&api};
        CastMediaPrep prep{&client};
        QSignalSpy ready(&prep, &CastMediaPrep::ready);

        prep.prepareFromManifest(manifest);
        QTRY_COMPARE_WITH_TIMEOUT(ready.count(), 1, 30000);
        const QString first = ready.first().at(0).toString();
        QVERIFY(QFile::exists(first));

        // A second track, as CastManager starts it on a track change.
        prep.prepare(1);
        QVERIFY2(!QFile::exists(first), "the last track's cast file was left behind");
        prep.cancel();
    }

private:
    QString m_ffmpeg;
};

QTEST_MAIN(TestCastPrep)
#include "tst_cast_prep.moc"
