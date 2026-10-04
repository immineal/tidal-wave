// What the app asks Tidal for when the user asks for FLAC, and what it makes of
// the answer.
//
// ── why this test exists ─────────────────────────────────────────────────────
//
// Until 2026-10-04 every tier went to `tracks/<id>/playbackinfopostpaywall` with
// `audioquality=` the user's preference. Measured that day against the live API
// from a probe linking this repo's own TidalApi/TidalClient, on the shipping
// client id and a current session, that request answers a `LOSSLESS` ask with
// `audioQuality: HIGH`, `manifestMimeType: application/vnd.tidal.bts`,
// `codecs: mp4a.40.2` - 320 kbps AAC - on **27 of 27** catalogue tracks. It does
// so including on tracks whose `mediaMetadata.tags` say `LOSSLESS`, and the
// `HI_RES_LOSSLESS` ask falls back to the same AAC on every track with no hi-res
// master. The `LOSSLESS` and `HIGH` responses even carry the *same*
// `manifestHash`, so the two settings were delivering one identical file.
//
// It is not the account (the same token is served FLAC_HIRES at 24/192), not the
// region, not the tracks, and not a missing request parameter: `prefetch`,
// `immersiveaudio`, the `X-Tidal-Token` header, the User-Agent, a
// `playbackinfo`/`playbackinfopostpaywall` swap and a minimal three-parameter
// request all answer identically, while a misspelt `audioquality` 404s - so the
// server parses the value and downgrades it on purpose. That endpoint simply no
// longer serves the FLAC tiers.
//
// `openapi.tidal.com/v2/trackManifests/<id>` does, on the same token: 27 of 27
// of the same tracks come back as `FLAC,44100,16`, and the three that are
// Dolby-Atmos-only - which the old endpoint refused FLAC for outright - among
// them. So the FLAC tiers move there and the lossy tiers stay where they are,
// because the old endpoint still serves those correctly *and* serves them as a
// single BTS file rather than DASH segments that have to be joined before the
// first note.
//
// ── where the fixtures come from ─────────────────────────────────────────────
//
// Constructed from responses captured on 2026-10-04, not verbatim:
//
//   * kept exactly as captured: the JSON:API envelope (`data.attributes`), every
//     attribute name, `trackPresentation`, the one-entry `formats` array, both
//     `*AudioNormalizationData` objects, the `data:` URI's prefix, and the whole
//     MPD down to the attribute order - the parts the code under test reads.
//   * replaced: the track ids (invented, of the right shape - nothing reads
//     them), the `hash` (a content hash of a real catalogue asset, and nothing
//     reads that either), and every signed CDN URL under
//     `initialization=`/`media=`, whose tokens are not committed and would
//     expire anyway. Nothing here fetches a segment, so a placeholder URL is all
//     the parse needs.
//   * invented outright: the PREVIEW presentation and the HLS media type that
//     refusesAPreview() and refusesANonDashManifest() feed in. No live response
//     was provoked into either shape - they stand for the two answers that must
//     not reach the player as if they were the whole track.
//
// The bare `AACLC` Representation id is the one that pins the fallbacks: it
// carries no sample rate or bit depth after it, where the FLAC ids carry both.

#include <QTest>
#include <QJsonArray>
#include <QJsonObject>
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

} // namespace

class TestStreamManifest : public QObject
{
    Q_OBJECT

private slots:
    // ── the request ──────────────────────────────────────────────────────────

    // The whole defect in one assertion: a Lossless ask must not go to the
    // endpoint that answers it with AAC.
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

    // "Lossless (16-bit)" has to ask for FLAC *only*. Asking for FLAC_HIRES too
    // would hand a 24-bit stream to a setting whose label promises 16, and the
    // live API does pick FLAC_HIRES whenever it is offered one.
    //
    // "Hi-Res (24-bit)" has to ask for both. FLAC_HIRES alone falls back to AAC
    // on a track with no hi-res master - which is most of them - and that is the
    // tier Downloader and CastMediaPrep ask for unconditionally.
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
        // The manifest itself, not a URL to it: this is what DashFetcher parses.
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

    // The bare `AACLC` id carries neither rate nor depth, so both have to stay
    // at the CD defaults rather than becoming 0 - Downloader picks pcm_s16le vs
    // pcm_s24le off bitDepth, and 0 would read as 16 only by accident.
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

    // The old endpoint took assetpresentation=FULL and errored rather than hand
    // back a clip. This one has no such parameter and says what it gave in the
    // body, so the check moves here: a 30-second preview must not play as if it
    // were the track.
    void refusesAPreview()
    {
        QString err;
        const StreamManifest m = TidalClient::parseTrackManifests(
            envelope(mpdWith("FLAC,44100,16", "flac"), QStringLiteral("FLAC"),
                     QStringLiteral("PREVIEW")), &err);

        QVERIFY(!err.isEmpty());
        QCOMPARE(m.url, QString());
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
};

QTEST_MAIN(TestStreamManifest)
#include "tst_stream_manifest.moc"
