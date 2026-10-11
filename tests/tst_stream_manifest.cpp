// What the app asks Tidal for when the user asks for FLAC, and what it makes of
// the answer. `tracks/<id>/playbackinfopostpaywall` answers the FLAC tiers
// with AAC, so they go to `openapi.tidal.com/v2/trackManifests/<id>`, and the
// lossy tiers stay on the first endpoint, which serves them as one BTS file.
// The fixtures are built from captured responses: structure as captured, ids,
// hash and CDN URLs replaced. The PREVIEW and HLS shapes are invented.

#include <QTest>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <memory>
#include "api/TidalApi.h"
#include "api/TidalClient.h"

namespace {

// A real MPD with the signed segment URLs replaced. One audio Representation,
// SegmentTemplate + SegmentTimeline, exactly as Tidal sends it.
QByteArray mpdWith(const QByteArray &representationId, const QByteArray &codecs)
{
    return "<?xml version='1.0' encoding='UTF-8'?>"
           "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" "
                "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                "profiles=\"urn:mpeg:dash:profile:isoff-main:2011\" type=\"static\" "
                "minBufferTime=\"PT3.993S\" mediaPresentationDuration=\"PT1M54.106S\">"
           "<Period id=\"0\">"
           "<AdaptationSet id=\"0\" contentType=\"audio\" mimeType=\"audio/mp4\" "
                          "lang=\"und\" group=\"main\" segmentAlignment=\"true\">"
           "<Role schemeIdUri=\"urn:mpeg:dash:role:2011\" value=\"main\"/>"
           "<Representation id=\"" + representationId + "\" codecs=\"" + codecs + "\" "
                           "bandwidth=\"570611\" audioSamplingRate=\"44100\">"
           "<AudioChannelConfiguration "
               "schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"2\"/>"
           "<SegmentTemplate timescale=\"44100\" "
               "initialization=\"https://sp-ad-fa.audio.tidal.com/mediatracks/PLACEHOLDER/0.mp4\" "
               "media=\"https://sp-ad-fa.audio.tidal.com/mediatracks/PLACEHOLDER/$Number$.mp4\" "
               "startNumber=\"1\">"
           "<SegmentTimeline><S d=\"176128\" r=\"27\"/><S d=\"100520\"/></SegmentTimeline>"
           "</SegmentTemplate></Representation></AdaptationSet></Period></MPD>";
}

QJsonObject envelope(const QByteArray &mpd,
                     const QString &format,
                     const QString &presentation = QStringLiteral("FULL"),
                     const QString &dataMime = QStringLiteral("application/dash+xml"))
{
    const QString uri = QStringLiteral("data:%1;base64,%2")
                            .arg(dataMime, QString::fromLatin1(mpd.toBase64()));

    QJsonObject album{{"replayGain", -5.3}, {"peakAmplitude", 0.997223}};
    QJsonObject track{{"replayGain", 10.29}, {"peakAmplitude", 0.335114}};

    QJsonObject attributes{
        {"trackPresentation", presentation},
        {"hash", QStringLiteral("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")},
        {"formats", QJsonArray{format}},
        {"albumAudioNormalizationData", album},
        {"trackAudioNormalizationData", track},
        {"uri", uri},
    };

    return QJsonObject{
        {"data", QJsonObject{{"id", QStringLiteral("100000001")},
                             {"type", QStringLiteral("trackManifests")},
                             {"attributes", attributes}}},
        {"links", QJsonObject{{"self", QStringLiteral("/trackManifests/100000001")}}},
    };
}

// A playbackinfopostpaywall answer for a lossy tier: one BTS file. Invented.
QJsonObject btsAnswer()
{
    const QJsonObject bts{{"mimeType", QStringLiteral("audio/mp4")},
                          {"urls", QJsonArray{QStringLiteral("https://cdn.invalid/a.mp4")}}};
    return QJsonObject{
        {"audioQuality", QStringLiteral("HIGH")},
        {"manifestMimeType", QStringLiteral("application/vnd.tidal.bts")},
        {"manifest", QString::fromLatin1(QJsonDocument(bts).toJson().toBase64())},
    };
}

// The body of a refusal by playbackinfopostpaywall.
QJsonObject subStatus(int status, int sub)
{
    return QJsonObject{{"status", status}, {"subStatus", sub},
                       {"userMessage", QStringLiteral("Asset is not ready for playback")}};
}

// The body of a refusal by trackManifests, in the JSON:API shape.
QJsonObject coded(const char *code)
{
    return QJsonObject{{"errors", QJsonArray{QJsonObject{
        {"code", QString::fromLatin1(code)}, {"detail", QStringLiteral("refused")}}}}};
}

// Answers every request with one status and one body, and notes the paths.
class OneAnswerServer : public QTcpServer {
public:
    explicit OneAnswerServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    if (buf->indexOf("\r\n\r\n") < 0) return;
                    const QByteArray line = buf->left(buf->indexOf("\r\n"));
                    buf->clear();
                    QString target = QString::fromUtf8(line.split(' ').value(1));
                    paths << target.left(target.indexOf(QLatin1Char('?')));
                    sock->write("HTTP/1.0 " + QByteArray::number(status) + " Answer\r\n"
                                "Content-Type: application/json\r\n"
                                "Content-Length: " + QByteArray::number(body.size())
                                + "\r\n\r\n" + body);
                    sock->flush();
                    sock->disconnectFromHost();
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    int         status = 200;
    QByteArray  body   = "{}";
    QStringList paths;
};

// The real TidalApi with every GET sent to a local server.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

} // namespace

class TestStreamManifest : public QObject
{
    Q_OBJECT

private slots:
    // ── the request ──────────────────────────────────────────────────────────

    // A Lossless ask must not go to the endpoint that answers it with AAC.
    void flacTiersLeaveTheOldEndpoint_data()
    {
        QTest::addColumn<int>("quality");
        QTest::addColumn<bool>("viaTrackManifests");
        QTest::newRow("LOW")             << int(AudioQuality::Low96k)        << false;
        QTest::newRow("HIGH")            << int(AudioQuality::Low320k)       << false;
        QTest::newRow("LOSSLESS")        << int(AudioQuality::Lossless)      << true;
        QTest::newRow("HI_RES_LOSSLESS") << int(AudioQuality::HiResLossless) << true;
    }

    void flacTiersLeaveTheOldEndpoint()
    {
        QFETCH(int, quality);
        QFETCH(bool, viaTrackManifests);
        QCOMPARE(TidalClient::usesTrackManifests(AudioQuality(quality)), viaTrackManifests);
    }

    // "Lossless (16-bit)" asks for FLAC only: the API picks FLAC_HIRES whenever
    // it is offered. "Hi-Res (24-bit)" asks for both, because FLAC_HIRES alone
    // falls back to AAC on a track with no hi-res master.
    void formatsAskedFor_data()
    {
        QTest::addColumn<int>("quality");
        QTest::addColumn<QStringList>("formats");
        QTest::newRow("LOW")             << int(AudioQuality::Low96k)
                                         << QStringList{"HEAACV1"};
        QTest::newRow("HIGH")            << int(AudioQuality::Low320k)
                                         << QStringList{"AACLC"};
        QTest::newRow("LOSSLESS")        << int(AudioQuality::Lossless)
                                         << QStringList{"FLAC"};
        QTest::newRow("HI_RES_LOSSLESS") << int(AudioQuality::HiResLossless)
                                         << QStringList{"FLAC", "FLAC_HIRES"};
    }

    void formatsAskedFor()
    {
        QFETCH(int, quality);
        QFETCH(QStringList, formats);
        QCOMPARE(TidalClient::manifestFormats(AudioQuality(quality)), formats);
    }

    // ── the answer ───────────────────────────────────────────────────────────

    void parsesSixteenBitFlac()
    {
        QString err = QStringLiteral("untouched");
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope(mpdWith("FLAC,44100,16", "flac"), QStringLiteral("FLAC")), &err);

        QCOMPARE(err, QString());
        QCOMPARE(m.type, StreamManifest::MPD);
        QCOMPARE(m.mimeType, QStringLiteral("application/dash+xml"));
        // The tier vocabulary the rest of the app speaks: Player::audioQuality()
        // and Downloader::srcTier both compare against these exact strings.
        QCOMPARE(m.codec, QStringLiteral("LOSSLESS"));
        QCOMPARE(m.sampleRate, 44100);
        QCOMPARE(m.bitDepth, 16);
        QCOMPARE(m.replayGainTrack, 10.29);
        QCOMPARE(m.replayGainAlbum, -5.3);
        // The manifest text itself, which is what DashFetcher parses.
        QVERIFY(m.url.startsWith(QStringLiteral("<?xml")));
        QVERIFY(m.url.contains(QStringLiteral("<Representation id=\"FLAC,44100,16\"")));
    }

    void parsesHiResFlac()
    {
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope(mpdWith("FLAC_HIRES,96000,24", "flac"), QStringLiteral("FLAC_HIRES")), &err);

        QCOMPARE(err, QString());
        QCOMPARE(m.codec, QStringLiteral("HI_RES_LOSSLESS"));
        QCOMPARE(m.sampleRate, 96000);
        QCOMPARE(m.bitDepth, 24);
    }

    // The bare `AACLC` id carries neither rate nor depth, so both stay at the CD
    // defaults. Downloader picks pcm_s16le or pcm_s24le off bitDepth.
    void parsesAacWithoutRateOrDepth()
    {
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope(mpdWith("AACLC", "mp4a.40.2"), QStringLiteral("AACLC")), &err);

        QCOMPARE(err, QString());
        QCOMPARE(m.codec, QStringLiteral("HIGH"));
        QCOMPARE(m.sampleRate, 44100);
        QCOMPARE(m.bitDepth, 16);
    }

    // This endpoint has no assetpresentation parameter and says what it gave in
    // the body, so a 30-second preview is refused here.
    void refusesAPreview()
    {
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope(mpdWith("FLAC,44100,16", "flac"), QStringLiteral("FLAC"),
                     QStringLiteral("PREVIEW")), &err);

        QVERIFY(!err.isEmpty());
        QCOMPARE(m.url, QString());
        QCOMPARE(m.reason, StreamManifest::NotForAccount);
    }

    void refusesANonDashManifest()
    {
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope("#EXTM3U\n#EXT-X-VERSION:3\n", QStringLiteral("FLAC"),
                     QStringLiteral("FULL"),
                     QStringLiteral("application/vnd.apple.mpegurl")), &err);

        QVERIFY(!err.isEmpty());
        QCOMPARE(m.url, QString());
    }

    void refusesAMissingManifest_data()
    {
        QTest::addColumn<QJsonObject>("body");
        QTest::newRow("empty body") << QJsonObject{};
        QTest::newRow("no attributes")
            << QJsonObject{{"data", QJsonObject{{"id", QStringLiteral("100000001")}}}};
        QTest::newRow("uri is not a data: URI")
            << QJsonObject{{"data", QJsonObject{{"attributes", QJsonObject{
                   {"trackPresentation", QStringLiteral("FULL")},
                   {"uri", QStringLiteral("https://api.tidal.com/not/inline.mpd")}}}}}};
    }

    void refusesAMissingManifest()
    {
        QFETCH(QJsonObject, body);
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(body, &err);
        QVERIFY(!err.isEmpty());
        QCOMPARE(m.url, QString());
    }

    // ── the request that is refused ──────────────────────────────────────────

    // 404 and 410 say the track does not exist. A 401 and a 403 have other
    // meanings as well, so there Tidal's own code in the body decides. Any
    // other refusal says nothing about the track.
    void whatARefusalSaysAboutTheTrack_data()
    {
        QTest::addColumn<bool>("openApi");
        QTest::addColumn<int>("status");
        QTest::addColumn<QJsonObject>("body");
        QTest::addColumn<int>("reason");

        const int unknown = StreamManifest::Unknown, gone = StreamManifest::Gone,
                  notForAccount = StreamManifest::NotForAccount;
        const QJsonObject none;

        QTest::newRow("v1 404") << false << 404 << none << gone;
        QTest::newRow("v1 410") << false << 410 << none << gone;
        QTest::newRow("v1 401, asset not ready")
            << false << 401 << subStatus(401, 4005) << gone;
        QTest::newRow("v1 401, the session ran out")
            << false << 401 << subStatus(401, 11003) << unknown;
        QTest::newRow("v1 401, no body") << false << 401 << none << unknown;
        QTest::newRow("v1 403, asset not ready")
            << false << 403 << subStatus(403, 4005) << unknown;
        QTest::newRow("v1 500, sub-status 999")
            << false << 500 << subStatus(500, 999) << unknown;
        QTest::newRow("v1 403, the other endpoint's code")
            << false << 403 << coded("GEO_RESTRICTED") << unknown;

        QTest::newRow("openapi 404") << true << 404 << coded("CONTENT_NOT_FOUND") << gone;
        QTest::newRow("openapi 410") << true << 410 << none << gone;
        QTest::newRow("openapi 403, blocked by region")
            << true << 403 << coded("GEO_RESTRICTED") << notForAccount;
        QTest::newRow("openapi 403, another code")
            << true << 403 << coded("FORBIDDEN") << unknown;
        QTest::newRow("openapi 403, no body") << true << 403 << none << unknown;
        QTest::newRow("openapi 500, blocked by region")
            << true << 500 << coded("GEO_RESTRICTED") << unknown;
        QTest::newRow("openapi 401, the other endpoint's code")
            << true << 401 << subStatus(401, 4005) << unknown;

        for (const bool openApi : {false, true})
            for (const int status : {0, 400, 429, 500, 503})
                QTest::addRow("%s %d", openApi ? "openapi" : "v1", status)
                    << openApi << status << none << unknown;
    }

    void whatARefusalSaysAboutTheTrack()
    {
        QFETCH(bool, openApi);
        QFETCH(int, status);
        QFETCH(QJsonObject, body);
        QFETCH(int, reason);
        QCOMPARE(int(TidalClient::refusalReason(openApi, status, body)), reason);
    }

    // A 200 that holds no whole track. A preview is what an account without
    // the right to the track gets; an answer the app cannot read says nothing.
    void anAnswerThatIsNoWholeTrackCarriesItsReason_data()
    {
        QTest::addColumn<QJsonObject>("body");
        QTest::addColumn<int>("reason");
        QTest::newRow("a preview")
            << envelope(mpdWith("FLAC,44100,16", "flac"), QStringLiteral("FLAC"),
                        QStringLiteral("PREVIEW"))
            << int(StreamManifest::NotForAccount);
        QTest::newRow("an HLS playlist")
            << envelope("#EXTM3U\n#EXT-X-VERSION:3\n", QStringLiteral("FLAC"),
                        QStringLiteral("FULL"), QStringLiteral("application/vnd.apple.mpegurl"))
            << int(StreamManifest::Unknown);
        QTest::newRow("an empty body") << QJsonObject{} << int(StreamManifest::Unknown);
    }

    void anAnswerThatIsNoWholeTrackCarriesItsReason()
    {
        QFETCH(QJsonObject, body);
        QFETCH(int, reason);

        OneAnswerServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.body = QJsonDocument(body).toJson();
        LocalApi api;
        api.local = QStringLiteral("http://127.0.0.1:%1/").arg(srv.serverPort());

        TidalClient client{&api};
        bool answered = false;
        StreamManifest got;
        QString err;
        client.fetchStreamManifest(100000001, AudioQuality::Lossless,
            [&](StreamManifest m, QString e) { answered = true; got = m; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);

        QVERIFY2(!err.isEmpty(), "an answer with no whole track came back without an error");
        QCOMPARE(got.url, QString());
        QCOMPARE(int(got.reason), reason);
    }

    // The same over HTTP on both endpoints: the status and the body of a
    // refusal both reach the place that decides.
    void aRefusedRequestCarriesItsReason_data()
    {
        QTest::addColumn<int>("quality");
        QTest::addColumn<int>("status");        // 0: nothing listens on the port
        QTest::addColumn<QJsonObject>("body");
        QTest::addColumn<int>("reason");

        const int v1 = int(AudioQuality::Low320k), openApi = int(AudioQuality::Lossless);
        QTest::newRow("playbackinfopostpaywall 401, asset not ready")
            << v1 << 401 << subStatus(401, 4005) << int(StreamManifest::Gone);
        QTest::newRow("playbackinfopostpaywall 401, the session ran out")
            << v1 << 401 << subStatus(401, 11003) << int(StreamManifest::Unknown);
        QTest::newRow("trackManifests 403, blocked by region")
            << openApi << 403 << coded("GEO_RESTRICTED") << int(StreamManifest::NotForAccount);
        QTest::newRow("trackManifests 403, another code")
            << openApi << 403 << coded("FORBIDDEN") << int(StreamManifest::Unknown);
        QTest::newRow("trackManifests 404, with its code")
            << openApi << 404 << coded("CONTENT_NOT_FOUND") << int(StreamManifest::Gone);

        const struct { const char *name; AudioQuality quality; } endpoints[] = {
            {"playbackinfopostpaywall", AudioQuality::Low320k},
            {"trackManifests",          AudioQuality::Lossless},
        };
        const struct { int status; StreamManifest::Reason reason; } answers[] = {
            {404, StreamManifest::Gone},    {410, StreamManifest::Gone},
            {400, StreamManifest::Unknown}, {401, StreamManifest::Unknown},
            {403, StreamManifest::Unknown}, {429, StreamManifest::Unknown},
            {500, StreamManifest::Unknown}, {503, StreamManifest::Unknown},
            {0,   StreamManifest::Unknown},
        };
        for (const auto &e : endpoints)
            for (const auto &a : answers)
                QTest::addRow("%s %d", e.name, a.status)
                    << int(e.quality) << a.status << QJsonObject{} << int(a.reason);
    }

    void aRefusedRequestCarriesItsReason()
    {
        QFETCH(int, quality);
        QFETCH(int, status);
        QFETCH(QJsonObject, body);
        QFETCH(int, reason);

        OneAnswerServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.status = status;
        srv.body   = QJsonDocument(body).toJson();
        LocalApi api;
        api.local = QStringLiteral("http://127.0.0.1:%1/").arg(srv.serverPort());
        if (status == 0) srv.close();

        TidalClient client{&api};
        bool answered = false;
        StreamManifest got;
        QString err;
        client.fetchStreamManifest(100000001, AudioQuality(quality),
            [&](StreamManifest m, QString e) { answered = true; got = m; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);

        QVERIFY2(!err.isEmpty(), "a refused stream request came back without an error");
        QCOMPARE(int(got.reason), reason);
        if (status != 0) {
            const QString asked = TidalClient::usesTrackManifests(AudioQuality(quality))
                ? QStringLiteral("/trackManifests/100000001")
                : QStringLiteral("/tracks/100000001/playbackinfopostpaywall");
            QCOMPARE(srv.paths, QStringList{asked});
        }
    }

    // A caller that does not ask for the status gets the error and no body.
    void aPlainGetGetsNoBodyBesideAnError()
    {
        OneAnswerServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.status = 404;
        srv.body   = QJsonDocument(subStatus(404, 2001)).toJson();
        LocalApi api;
        api.local = QStringLiteral("http://127.0.0.1:%1/").arg(srv.serverPort());

        bool answered = false;
        QJsonObject got{{"untouched", true}};
        QString err;
        api.get(QStringLiteral("tracks/1"), {},
                [&](QJsonObject o, QString e) { answered = true; got = o; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);
        QVERIFY(!err.isEmpty());
        QVERIFY(got.isEmpty());
    }

    // The same route with a 200, so the rows above are about the status.
    void aStreamRequestThatIsAnsweredCarriesNoVerdict_data()
    {
        QTest::addColumn<int>("quality");
        QTest::addColumn<QJsonObject>("body");
        QTest::addColumn<int>("type");
        QTest::newRow("playbackinfopostpaywall")
            << int(AudioQuality::Low320k) << btsAnswer() << int(StreamManifest::BTS);
        QTest::newRow("trackManifests")
            << int(AudioQuality::Lossless)
            << envelope(mpdWith("FLAC,44100,16", "flac"), QStringLiteral("FLAC"))
            << int(StreamManifest::MPD);
    }

    void aStreamRequestThatIsAnsweredCarriesNoVerdict()
    {
        QFETCH(int, quality);
        QFETCH(QJsonObject, body);
        QFETCH(int, type);

        OneAnswerServer srv;
        QVERIFY(srv.listen(QHostAddress::LocalHost));
        srv.body = QJsonDocument(body).toJson();
        LocalApi api;
        api.local = QStringLiteral("http://127.0.0.1:%1/").arg(srv.serverPort());

        TidalClient client{&api};
        bool answered = false;
        StreamManifest got;
        QString err;
        client.fetchStreamManifest(100000001, AudioQuality(quality),
            [&](StreamManifest m, QString e) { answered = true; got = m; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answered, 10000);

        QCOMPARE(err, QString());
        QCOMPARE(int(got.type), type);
        QVERIFY(!got.url.isEmpty());
        QCOMPARE(got.reason, StreamManifest::Unknown);
    }
};

QTEST_MAIN(TestStreamManifest)
#include "tst_stream_manifest.moc"
