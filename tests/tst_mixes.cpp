// Mixes: what the page walk yields, and in what order.
//
// The fixture below is a real `pages/my_collection_my_mixes` response, trimmed
// to the fields the app reads (the image URLs are shortened; everything else,
// including the ids, the titles and the order the items arrived in, is as Tidal
// sent it). It is the whole reason this file exists: the shape of this response
// is what decides whether "My Daily Discovery" and "My New Arrivals" can be
// reached at all, and it cannot be checked against a live account from a test.
//
// Two facts in it are easy to get wrong:
//
//   * `mixType` is a *string*. It used to be read as an object here, which is
//     why the field was never usable as an identifier.
//   * the two personalised mixes come *last* of ten, behind "My Mix 1".."My Mix
//     8" - which is where they were when nobody could find them.
//
// Nothing here touches the network: parseMixPage is a static over parsed JSON.

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>

#include <algorithm>

#include "api/TidalClient.h"

namespace {

// A real response, as described above.
constexpr auto kMyMixesPage = R"json({
  "id": "my_collection_my_mixes",
  "title": "Custom mixes",
  "rows": [
    { "modules": [
      { "type": "MIX_LIST", "title": "", "supportsPaging": true, "scroll": "VERTICAL",
        "pagedList": { "limit": 50, "offset": 0, "totalNumberOfItems": 10, "items": [
        {"id":"002a7caac9856a9168001948bb865d","title":"My Mix 1","subTitle":"Ben Howard, James Blunt, Coldplay and mo","images":{"LARGE":{"url":"@https@images.tidal.com/0/002a7c/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"002d7b2e4bdb46e7ef92e76e2da4fb","title":"My Mix 2","subTitle":"Téléphone, Benjamin Biolay, Joe Dassin a","images":{"LARGE":{"url":"@https@images.tidal.com/0/002d7b/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"0029cee8e9c2ccc4e99372a92b06a0","title":"My Mix 3","subTitle":"Eels, The Clash, Oasis and more","images":{"LARGE":{"url":"@https@images.tidal.com/0/0029ce/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"002197b81a9bba716d37696382c06c","title":"My Mix 4","subTitle":"Bee Gees, U2, Bonnie Tyler and more","images":{"LARGE":{"url":"@https@images.tidal.com/0/002197/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"002090b3231de3509fc3f15e6d7d06","title":"My Mix 5","subTitle":"Abbey Cone, Cody Johnson, Ella Langley a","images":{"LARGE":{"url":"@https@images.tidal.com/0/002090/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"00265842f29e2d9c8e3698176fa588","title":"My Mix 6","subTitle":"Slowdive, Beach House, Cass McCombs and ","images":{"LARGE":{"url":"@https@images.tidal.com/0/002658/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"002d4a772418e31f7a9a9afbde6701","title":"My Mix 7","subTitle":"Anette Askvik, HAEVN, Jeff Buckley and m","images":{"LARGE":{"url":"@https@images.tidal.com/0/002d4a/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"00278d6bb97e21daa45ad22ae25b11","title":"My Mix 8","subTitle":"Pink Floyd, Heron, Blood, Sweat & Tears ","images":{"LARGE":{"url":"@https@images.tidal.com/0/00278d/1500x1500?token=t"}},"mixType":"DAILY_MIX"},
        {"id":"01674a6a4c4c8866f15780f612d092","title":"My Daily Discovery","subTitle":"Songs by new and familiar artists inspir","images":{"LARGE":{"url":"@https@images.tidal.com/0/01674a/1500x1500?token=t"}},"mixType":"DISCOVERY_MIX"},
        {"id":"0116788120318a26696f76cf158b03","title":"My New Arrivals","subTitle":"Yuksek, Christine and the Queens, Ringo ","images":{"LARGE":{"url":"@https@images.tidal.com/0/011678/1500x1500?token=t"}},"mixType":"NEW_RELEASE_MIX"}
      ] } } ] }
  ]
})json";

// The fixtures write "@https@host/path" where the response has
// "https://host/path", and this puts the scheme back. moc strips // comments
// line by line and does it inside a multi-line raw string too, so a URL written
// out in full truncates the literal it sits in - and then swallows the Q_OBJECT
// below it, leaving the test binary to fail at link time with a missing vtable.
QJsonObject pageOf(const char *json) {
    QByteArray raw(json);
    raw.replace("@https@", "https://");
    raw.replace("@http@",  "http://");

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw, &err);
    if (err.error != QJsonParseError::NoError)
        qWarning("fixture is not valid JSON: %s", qPrintable(err.errorString()));
    return doc.object();
}

QStringList titlesOf(const QList<Mix> &mixes) {
    QStringList out;
    for (const Mix &m : mixes) out << m.title;
    return out;
}

QStringList typesOf(const QList<Mix> &mixes) {
    QStringList out;
    for (const Mix &m : mixes) out << m.mixType;
    return out;
}

} // namespace

class TestMixes : public QObject {
    Q_OBJECT

private slots:

    // ── the real response ────────────────────────────────────────────────

    void realPageYieldsEveryMix() {
        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(kMyMixesPage));
        QCOMPARE(mixes.size(), 10);
        // Ids and titles survive the walk intact.
        QVERIFY(titlesOf(mixes).contains(QStringLiteral("My Daily Discovery")));
        QVERIFY(titlesOf(mixes).contains(QStringLiteral("My New Arrivals")));
        for (const Mix &m : mixes) {
            QVERIFY2(!m.id.isEmpty(), qPrintable(m.title));
            QVERIFY2(!m.title.isEmpty(), qPrintable(m.id));
            QVERIFY2(!m.coverUrl(320).isEmpty(), qPrintable(m.title));
        }
    }

    // mixType is a string on this endpoint. Read as an object - which is what
    // Mix::fromJson used to do, to look for artwork in it - every mix comes out
    // with an empty one and there is no locale-safe way to tell them apart.
    void mixTypeIsParsedAsAnIdentifier() {
        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(kMyMixesPage));
        QCOMPARE(typesOf(mixes).count(QStringLiteral("DISCOVERY_MIX")), 1);
        QCOMPARE(typesOf(mixes).count(QStringLiteral("NEW_RELEASE_MIX")), 1);
        QCOMPARE(typesOf(mixes).count(QStringLiteral("DAILY_MIX")), 8);

        const Mix discovery = *std::find_if(mixes.begin(), mixes.end(),
            [](const Mix &m) { return m.isDailyDiscovery(); });
        QCOMPARE(discovery.title, QStringLiteral("My Daily Discovery"));
        QCOMPARE(discovery.id, QStringLiteral("01674a6a4c4c8866f15780f612d092"));

        const Mix arrivals = *std::find_if(mixes.begin(), mixes.end(),
            [](const Mix &m) { return m.isNewArrivals(); });
        QCOMPARE(arrivals.title, QStringLiteral("My New Arrivals"));
        QCOMPARE(arrivals.id, QStringLiteral("0116788120318a26696f76cf158b03"));

        // A "My Mix N" is neither.
        for (const Mix &m : mixes) {
            if (m.mixType != QStringLiteral("DAILY_MIX")) continue;
            QVERIFY(!m.isDailyDiscovery());
            QVERIFY(!m.isNewArrivals());
        }
    }

    // Tidal sends them ninth and tenth of ten. On the home row that is past the
    // right edge of a list that does not scroll by wheel, and in the Collection
    // grid it is the bottom. They lead instead, and they lead together.
    void theTwoPersonalisedMixesComeFirst() {
        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(kMyMixesPage));
        QCOMPARE(mixes.at(0).mixType, QStringLiteral("DISCOVERY_MIX"));
        QCOMPARE(mixes.at(1).mixType, QStringLiteral("NEW_RELEASE_MIX"));
    }

    // Everything behind them keeps the order the server sent: the Collection
    // grid's default setting is "the order it arrived in", and the numbered
    // mixes arrive numbered.
    void theRestKeepServerOrder() {
        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(kMyMixesPage));
        QCOMPARE(titlesOf(mixes).mid(2),
                 QStringList({QStringLiteral("My Mix 1"), QStringLiteral("My Mix 2"),
                              QStringLiteral("My Mix 3"), QStringLiteral("My Mix 4"),
                              QStringLiteral("My Mix 5"), QStringLiteral("My Mix 6"),
                              QStringLiteral("My Mix 7"), QStringLiteral("My Mix 8")}));
    }

    // The ordering is on mixType, never on the title. A German account gets the
    // same two mixes in the same two places; matching the English title would
    // leave them at the end for every user outside one locale.
    void orderingDoesNotReadTheTitle() {
        QByteArray german(kMyMixesPage);
        german.replace("My Daily Discovery", "Meine taegliche Entdeckung");
        german.replace("My New Arrivals",    "Meine Neuheiten");
        german.replace("My Mix ",            "Mein Mix ");

        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(german.constData()));
        QCOMPARE(mixes.size(), 10);
        QCOMPARE(mixes.at(0).title, QStringLiteral("Meine taegliche Entdeckung"));
        QCOMPARE(mixes.at(1).title, QStringLiteral("Meine Neuheiten"));
        QCOMPARE(mixes.at(2).title, QStringLiteral("Mein Mix 1"));
    }

    // ── shapes that are not that response ────────────────────────────────

    void unlabelledMixesAreKeptInPlace() {
        // An endpoint that does not label its mixes (an older page, or a radio
        // list) still has to come back whole and in order. Nothing is promoted.
        const QJsonObject page = pageOf(R"json({"rows":[{"modules":[
            {"type":"MIX_LIST","pagedList":{"items":[
              {"id":"a","title":"First"},
              {"id":"b","title":"Second"}
            ]}}]}]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(titlesOf(mixes), QStringList({QStringLiteral("First"), QStringLiteral("Second")}));
        QVERIFY(mixes.at(0).mixType.isEmpty());
        QVERIFY(!mixes.at(0).isDailyDiscovery());
    }

    void modulesThatAreNotMixListsAreSkipped() {
        const QJsonObject page = pageOf(R"json({"rows":[
            {"modules":[{"type":"TRACK_LIST","pagedList":{"items":[{"id":1,"title":"a track"}]}}]},
            {"modules":[{"type":"MIX_LIST","pagedList":{"items":[
              {"id":"m","title":"a mix","mixType":"DAILY_MIX"}]}}]}
          ]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(titlesOf(mixes), QStringList({QStringLiteral("a mix")}));
    }

    void severalRowsAndModulesAreAllWalked() {
        // The walk reads every module of every row, not the first of each.
        const QJsonObject page = pageOf(R"json({"rows":[
            {"modules":[
              {"type":"MIX_LIST","pagedList":{"items":[{"id":"a","title":"A","mixType":"DAILY_MIX"}]}},
              {"type":"MIX_LIST","pagedList":{"items":[{"id":"b","title":"B","mixType":"NEW_RELEASE_MIX"}]}}
            ]},
            {"modules":[
              {"type":"MIX_LIST","pagedList":{"items":[{"id":"c","title":"C","mixType":"DISCOVERY_MIX"}]}}
            ]}
          ]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(titlesOf(mixes), QStringList({QStringLiteral("C"), QStringLiteral("B"),
                                               QStringLiteral("A")}));
    }

    void emptyAndMalformedPagesAnswerNothing() {
        QVERIFY(TidalClient::parseMixPage({}).isEmpty());
        QVERIFY(TidalClient::parseMixPage(pageOf(R"json({"rows":[]})json")).isEmpty());
        QVERIFY(TidalClient::parseMixPage(pageOf(R"json({"rows":[{"modules":[]}]})json")).isEmpty());
        QVERIFY(TidalClient::parseMixPage(
            pageOf(R"json({"rows":[{"modules":[{"type":"MIX_LIST"}]}]})json")).isEmpty());
    }

    // ── artwork ──────────────────────────────────────────────────────────

    void artworkComesFromTheImagesBlock() {
        const QList<Mix> mixes = TidalClient::parseMixPage(pageOf(kMyMixesPage));
        // These are absolute, pre-signed URLs, so the requested size is not
        // ours to choose: coverUrl() hands them back as they are.
        QCOMPARE(mixes.at(0).coverUrl(320),
                 QStringLiteral("https://images.tidal.com/0/01674a/1500x1500?token=t"));
        QCOMPARE(mixes.at(0).coverUrl(320), mixes.at(0).coverUrl(640));
    }

    void artworkFallsBackThroughTheKnownShapes() {
        const QJsonObject page = pageOf(R"json({"rows":[{"modules":[
            {"type":"MIX_LIST","pagedList":{"items":[
              {"id":"a","title":"medium only","images":{"MEDIUM":{"url":"@http@art/m.jpg"}}},
              {"id":"b","title":"detail","detail":{"images":{"SMALL":{"url":"@http@art/s.jpg"}}}},
              {"id":"c","title":"detailImages","detailImages":{"LARGE":{"url":"@http@art/l.jpg"}}},
              {"id":"d","title":"a uuid","images":{}}
            ]}}]}]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(mixes.at(0).coverUrl(), QStringLiteral("http://art/m.jpg"));
        QCOMPARE(mixes.at(1).coverUrl(), QStringLiteral("http://art/s.jpg"));
        QCOMPARE(mixes.at(2).coverUrl(), QStringLiteral("http://art/l.jpg"));
        QVERIFY(mixes.at(3).coverUrl().isEmpty());
    }
};

QTEST_GUILESS_MAIN(TestMixes)
#include "tst_mixes.moc"
