// Mixes: what the Collection's Mixes tab holds, and in what order.
//
// Two sources, merged on the mix id:
//
//   * `pages/my_collection_my_mixes` - the mixes Tidal *generates* for the
//     account. "My Daily Discovery" and "My Mix 1".."My Mix 8".
//   * `v2/favorites/mixes` - the mixes the user *saved*. A different API
//     altogether: flat items rather than a page of rows and modules, a
//     `dateAdded` per item, a cursor instead of an offset, and no total.
//
// ── where the fixtures come from ─────────────────────────────────────────────
//
// kGeneratedPage and kSavedMixes are *constructed* from responses captured from a
// live account on 2026-10-03. Constructed, not verbatim:
//
//   * kept exactly as captured: the nesting (or flatness), every mix id, every
//     `mixType`, every `dateAdded`, the item counts, and the order the items
//     arrived in - the parts the code under test reads.
//   * replaced: every `subTitle`, because the real ones are lists of the artists
//     this account listens to and this is a public repository. A TRACK_MIX's
//     *title* is the title of the track whose radio it is, so that is a
//     placeholder too ("Saved Radio"); its id and mixType are the captured ones.
//   * dropped or shortened: the fields nothing reads (`graphic`, `description`,
//     `titleTextInfo`, `subTitleTextInfo`, the SMALL/MEDIUM image sizes), and the
//     image URLs, whose signing tokens are not committed.
//
// An earlier version of this file claimed its fixture was a real response "as
// Tidal sent it". It was not: ten items where the live generated page has
// seventeen, invented ids, and "My Daily Discovery" ninth where the live response
// has it first - so the reordering that fixture was written to justify is a no-op
// on the real page. Hence the paragraph above: if a fixture is built rather than
// captured, it has to say so and say from what.
//
// ── what the captures establish ──────────────────────────────────────────────
//
//   * the generated page carries Daily Discovery (already first) and all eight
//     "My Mix N", and does *not* carry "My New Arrivals" at all.
//   * eight of its seventeen items are VIDEO_DAILY_MIX, two of them sharing the
//     title "My Video Mix 7".
//   * the saved list carries "My New Arrivals", a saved TRACK_MIX radio station,
//     and three mixes the generated page also has - so dedup on the id is what
//     keeps the tab at eleven tiles rather than fourteen.
//   * the saved list's items are flat: the mix *is* the item, with no
//     {"item": {…}} wrapper, unlike the v1 favourites endpoints.
//
// Nothing here touches the network: the parses and the merge are statics over
// already-parsed JSON, and nextCursor() is a static over one page of it.

#include <QTest>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QSet>

#include <algorithm>

#include "api/TidalClient.h"

namespace {

// pages/my_collection_my_mixes, 17 items, in the order captured.
constexpr auto kGeneratedPage = R"json({
  "id": "my_collection_my_mixes",
  "title": "My Mix",
  "rows": [
    { "modules": [
      { "type": "MIX_LIST", "title": "", "supportsPaging": false, "scroll": null,
        "pagedList": { "limit": 50, "offset": 0, "totalNumberOfItems": 17, "items": [
        {"id":"016e5b32dafd59b9749297f12f5483","title":"My Daily Discovery","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/016e5b/1500x1500?token=t"}},"mixType":"DISCOVERY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0023ebda7f49d7922a56d1eed33cc7","title":"My Mix 1","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0023eb/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0024635f41a16fe8266c9f49355602","title":"My Mix 2","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/002463/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0024dfcc0bd8537e5683aed3d7163e","title":"My Mix 3","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0024df/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0022790c534ae65144190d40fb3d9e","title":"My Mix 4","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/002279/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0029d7ffb714ea55e8c8cb040d6d85","title":"My Mix 5","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0029d7/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"002a201b9dab85f97e92ef25b22859","title":"My Mix 6","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/002a20/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0022828ffe6b173050b807b3c295fd","title":"My Mix 7","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/002282/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"00236288332c3b170a20f4ccbe32df","title":"My Mix 8","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/002362/1500x1500?token=t"}},"mixType":"DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0046e76c10f596d59eaa6fe0eae7dc","title":"My Video Mix 1","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0046e7/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"004af38c0f55acc562bf3410c78427","title":"My Video Mix 2","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/004af3/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"004f2d2996daebc26bbbeed8f5c892","title":"My Video Mix 3","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/004f2d/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0042f62404270cbf153d9c47b4ec8a","title":"My Video Mix 4","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0042f6/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"00464c28544881d6d8783aaba39c7e","title":"My Video Mix 5","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/00464c/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"004cca56377cd01ef0e7cb5de12a9c","title":"My Video Mix 6","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/004cca/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"00402747bd40719d37376f8bf3b21f","title":"My Video Mix 7","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/004027/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"},
        {"id":"0048d4aa32ff5382d4924bfb0bfb37","title":"My Video Mix 7","subTitle":"placeholder subtitle","images":{"LARGE":{"url":"@https@images.tidal.com/0/0048d4/1500x1500?token=t"}},"mixType":"VIDEO_DAILY_MIX","shortSubtitle":"Created by TIDAL"}
      ] } } ] }
  ]
})json";

// v2/favorites/mixes, as captured: four flat items, oldest save first, each with
// its own dateAdded. "cursor": null is the last page.
constexpr auto kSavedMixes = R"json({
  "cursor": null,
  "lastModifiedAt": "2026-10-03T11:09:34.062893Z",
  "items": [
        {"dateAdded":"2026-06-08T19:33:03.142667Z","id":"016e5b32dafd59b9749297f12f5483","mixType":"DISCOVERY_MIX","updated":"2026-10-02T09:28:24.259Z","images":{"LARGE":{"url":"@https@images.tidal.com/0/016e5b/1500x1500?token=t"}},"master":false,"title":"My Daily Discovery","subTitle":"placeholder subtitle"},
        {"dateAdded":"2026-06-20T14:33:02.868689Z","id":"011881f03495a3b81fe3c1dac0cde4","mixType":"NEW_RELEASE_MIX","updated":"2026-10-02T10:43:59.229Z","images":{"LARGE":{"url":"@https@images.tidal.com/0/011881/1500x1500?token=t"}},"master":false,"title":"My New Arrivals","subTitle":"placeholder subtitle"},
        {"dateAdded":"2026-09-27T19:44:46.754991Z","id":"0023ebda7f49d7922a56d1eed33cc7","mixType":"DAILY_MIX","updated":"2026-10-02T08:13:52.363Z","images":{"LARGE":{"url":"@https@images.tidal.com/0/0023eb/1500x1500?token=t"}},"master":false,"title":"My Mix 1","subTitle":"placeholder subtitle"},
        {"dateAdded":"2026-10-03T11:09:34.058841Z","id":"0017c8f6cd2a860351ed705e4aec15","mixType":"TRACK_MIX","updated":"2026-10-03T11:20:37.358Z","images":{"LARGE":{"url":"@https@images.tidal.com/0/0017c8/1500x1500?token=t"}},"master":false,"title":"Saved Radio","subTitle":"placeholder subtitle"}
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

QJsonObject generatedPage() { return pageOf(kGeneratedPage); }
QJsonObject savedPage()     { return pageOf(kSavedMixes); }

// The tab as the app assembles it: the generated feed first, so its run of
// "My Mix N" stays intact, then everything saved.
QList<Mix> merged() {
    return TidalClient::mergeMixLists({TidalClient::parseMixPage(generatedPage()),
                                       TidalClient::parseSavedMixes(savedPage())});
}

// Computed with QDateTime straight from the string, so the expectations do not
// lean on the helper they are checking.
qint64 instant(const char *iso) {
    return QDateTime::fromString(QString::fromUtf8(iso), Qt::ISODate).toMSecsSinceEpoch();
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

QStringList idsOf(const QList<Mix> &mixes) {
    QStringList out;
    for (const Mix &m : mixes) out << m.id;
    return out;
}

// The titles the walk produced, as one string, for a failure message that says
// what actually came back rather than only that a count was wrong.
QString listing(const QList<Mix> &mixes) {
    return titlesOf(mixes).join(QLatin1String(", "));
}

// The raw items of one MIX_LIST row of a fixture, so a test can state what the
// page itself holds rather than what the walk made of it.
QJsonArray rawItems(const QJsonObject &page, int row) {
    return page["rows"].toArray().at(row).toObject()["modules"].toArray().at(0)
               .toObject()["pagedList"].toObject()["items"].toArray();
}

const QStringList kEightMyMixes{
    QStringLiteral("My Mix 1"), QStringLiteral("My Mix 2"), QStringLiteral("My Mix 3"),
    QStringLiteral("My Mix 4"), QStringLiteral("My Mix 5"), QStringLiteral("My Mix 6"),
    QStringLiteral("My Mix 7"), QStringLiteral("My Mix 8")};

} // namespace

class TestMixes : public QObject {
    Q_OBJECT

private slots:

    // ── what each captured page does and does not hold ───────────────────

    // The claim the previous version of this file was built on - that Tidal
    // sends the two personalised mixes last, so they had to be moved to the
    // front - is false for Daily Discovery: the page already leads with it.
    void theCollectionPageAlreadyLeadsWithDiscovery() {
        const QJsonArray raw = rawItems(generatedPage(), 0);
        QCOMPARE(raw.size(), 17);
        QCOMPARE(raw.at(0).toObject()["mixType"].toString(), QStringLiteral("DISCOVERY_MIX"));
        QCOMPARE(raw.at(0).toObject()["title"].toString(), QStringLiteral("My Daily Discovery"));
    }

    // And it is false for New Arrivals in a worse way: that mix is not on this
    // page at all, so no amount of sorting this response could ever surface it.
    void theCollectionPageHasNoNewArrivalsToSort() {
        for (const QJsonValue &v : rawItems(generatedPage(), 0))
            QVERIFY2(v.toObject()["mixType"].toString() != QStringLiteral("NEW_RELEASE_MIX"),
                     "the capture is supposed to be the page that lacks New Arrivals");

        const QList<Mix> mixes = TidalClient::parseMixPage(generatedPage());
        QVERIFY2(!std::any_of(mixes.cbegin(), mixes.cend(),
                              [](const Mix &m) { return m.isNewArrivals(); }),
                 qPrintable(listing(mixes)));
    }

    // The saved list has New Arrivals, which no `pages/*` feed the app reads
    // carries, and is still not the whole tab on its own: the user has saved one
    // of the eight "My Mix N", not all eight.
    void theSavedListHasNewArrivalsAndIsAlsoIncomplete() {
        const QList<Mix> mixes = TidalClient::parseSavedMixes(savedPage());
        QCOMPARE(mixes.size(), 4);
        QVERIFY2(std::any_of(mixes.cbegin(), mixes.cend(),
                             [](const Mix &m) { return m.isNewArrivals(); }),
                 qPrintable(listing(mixes)));
        QCOMPARE(typesOf(mixes).count(QStringLiteral("DAILY_MIX")), 1);
    }

    // Flat items: v2/favorites/mixes puts the mix *at* the item, where the v1
    // favourites endpoints wrap it in {"item": {…}}. Unwrapping one that is not
    // wrapped would answer an empty list.
    void theSavedListItemsAreFlat() {
        const QJsonArray raw = savedPage()["items"].toArray();
        QCOMPARE(raw.size(), 4);
        for (const QJsonValue &v : raw) {
            QVERIFY(!v.toObject().contains(QStringLiteral("item")));
            QVERIFY(v.toObject().contains(QStringLiteral("id")));
        }
        QCOMPARE(TidalClient::parseSavedMixes(savedPage()).size(), 4);
    }

    // Every saved mix carries the date the user saved it, which is what the
    // sidebar's ordering is built on. `updated` sits beside it and is not read:
    // Tidal regenerates these daily, and reading it would reshuffle the sidebar
    // every morning.
    void everySavedMixCarriesTheDateItWasSaved() {
        const QList<Mix> mixes = TidalClient::parseSavedMixes(savedPage());
        for (const Mix &m : mixes)
            QVERIFY2(m.addedAt > 0, qPrintable(m.title));
        // Six fractional digits, which Qt::ISODate rounds to the millisecond.
        QCOMPARE(mixes.at(0).addedAt, instant("2026-06-08T19:33:03.142667Z"));
        QCOMPARE(mixes.at(3).addedAt, instant("2026-10-03T11:09:34.058841Z"));
        // Oldest save first, as captured, and not the `updated` stamps - which run
        // in a different order from the save dates.
        for (int i = 1; i < mixes.size(); ++i)
            QVERIFY2(mixes.at(i - 1).addedAt < mixes.at(i).addedAt, qPrintable(listing(mixes)));
    }

    // A mix from a page feed has no date at all. 0, not a guess.
    void aGeneratedMixHasNoDate() {
        for (const Mix &m : TidalClient::parseMixPage(generatedPage()))
            QCOMPARE(m.addedAt, 0LL);
    }

    // A saved radio station is a saved mix. TRACK_MIX and ARTIST_MIX are kept
    // here - the user saved them deliberately, and a missing saved radio is the
    // thing that was noticed.
    void aSavedRadioStationIsKept() {
        const QList<Mix> mixes = TidalClient::parseSavedMixes(savedPage());
        QVERIFY2(typesOf(mixes).contains(QStringLiteral("TRACK_MIX")),
                 qPrintable(typesOf(mixes).join(QLatin1String(", "))));
        QVERIFY2(titlesOf(merged()).contains(QStringLiteral("Saved Radio")),
                 qPrintable(listing(merged())));
    }

    // And so is a video mix, if one ever turns up in the saved list. The filter
    // is on the generated feed only: dropping something the user deliberately
    // saved is the worse failure, even when the app cannot play it.
    void aSavedVideoMixIsKeptAlthoughTheGeneratedOnesAreNot() {
        const QList<Mix> saved = TidalClient::parseSavedMixes(pageOf(R"json({
            "cursor": null,
            "items": [
              {"id":"v1","title":"a saved video mix","mixType":"VIDEO_DAILY_MIX",
               "dateAdded":"2026-10-01T00:00:00.000Z"}
            ]})json"));
        QCOMPARE(titlesOf(saved), QStringList({QStringLiteral("a saved video mix")}));
        QVERIFY(saved.at(0).isVideoMix());
        QVERIFY(saved.at(0).addedAt > 0);

        // The same mixType on the generated feed is still dropped.
        QVERIFY(TidalClient::parseMixPage(pageOf(R"json({"rows":[{"modules":[
            {"type":"MIX_LIST","pagedList":{"items":[
              {"id":"v1","title":"a generated video mix","mixType":"VIDEO_DAILY_MIX"}
            ]}}]}]})json")).isEmpty());
    }

    // ── paging the saved list ────────────────────────────────────────────
    //
    // The endpoint reports no totalNumberOfItems, so nothing can compute "done";
    // nextCursor() is the whole of the termination rule. These are the three
    // shapes that end a run and the one that continues it.

    // The last page answers "cursor": null. Asking again with the cursor the page
    // was fetched with - the natural-looking reading of "no new cursor" - would
    // fetch the same page for ever, so an absent cursor has to come back absent.
    void aNullCursorEndsTheRun() {
        QCOMPARE(TidalClient::nextCursor(savedPage(), QString()), QString());
        // And from a *later* page, where there is a previous cursor to fall back
        // on and nothing must.
        QCOMPARE(TidalClient::nextCursor(savedPage(), QStringLiteral("eyJtaXhJZCI6IngifQ==")),
                 QString());
        QCOMPARE(TidalClient::nextCursor(pageOf(R"json({"items":[{"id":"a"}]})json"),
                                         QString()), QString());
        QCOMPARE(TidalClient::nextCursor(pageOf(R"json({"cursor":"","items":[{"id":"a"}]})json"),
                                         QString()), QString());
    }

    void aCursorWithItemsBehindItContinuesTheRun() {
        QCOMPARE(TidalClient::nextCursor(
                     pageOf(R"json({"cursor":"eyJtaXhJZCI6IngifQ==","items":[{"id":"a"}]})json"),
                     QString()),
                 QStringLiteral("eyJtaXhJZCI6IngifQ=="));
    }

    void anEmptyPageEndsTheRunEvenWithACursor() {
        // Nothing more can come of asking again, whatever the cursor says.
        QCOMPARE(TidalClient::nextCursor(pageOf(R"json({"cursor":"more","items":[]})json"),
                                         QString()), QString());
        QCOMPARE(TidalClient::nextCursor(pageOf(R"json({"cursor":"more"})json"),
                                         QString()), QString());
    }

    // A server handing back the cursor it was just given would otherwise fetch
    // the same page for ever.
    void aRepeatedCursorEndsTheRun() {
        const QJsonObject page = pageOf(R"json({"cursor":"same","items":[{"id":"a"}]})json");
        QCOMPARE(TidalClient::nextCursor(page, QStringLiteral("other")), QStringLiteral("same"));
        QCOMPARE(TidalClient::nextCursor(page, QStringLiteral("same")), QString());
    }

    // ── the merge ────────────────────────────────────────────────────────

    void mergingBothSourcesYieldsEveryMix() {
        const QList<Mix> mixes = merged();
        const QStringList titles = titlesOf(mixes);

        QVERIFY2(titles.contains(QStringLiteral("My Daily Discovery")), qPrintable(listing(mixes)));
        QVERIFY2(titles.contains(QStringLiteral("My New Arrivals")), qPrintable(listing(mixes)));
        QVERIFY2(titles.contains(QStringLiteral("Saved Radio")), qPrintable(listing(mixes)));
        for (const QString &mix : kEightMyMixes)
            QVERIFY2(titles.contains(mix),
                     qPrintable(QStringLiteral("%1 is missing from the merged list: %2")
                                    .arg(mix, listing(mixes))));

        // Eleven tiles: Daily Discovery, New Arrivals, My Mix 1-8 and the saved
        // radio - from 17 generated items and 4 saved ones.
        QCOMPARE(typesOf(mixes).count(QStringLiteral("DISCOVERY_MIX")), 1);
        QCOMPARE(typesOf(mixes).count(QStringLiteral("NEW_RELEASE_MIX")), 1);
        QCOMPARE(typesOf(mixes).count(QStringLiteral("DAILY_MIX")), 8);
        QCOMPARE(typesOf(mixes).count(QStringLiteral("TRACK_MIX")), 1);
        QCOMPARE(mixes.size(), 11);

        for (const Mix &m : mixes) {
            QVERIFY2(!m.id.isEmpty(), qPrintable(m.title));
            QVERIFY2(!m.title.isEmpty(), qPrintable(m.id));
            QVERIFY2(!m.subTitle.isEmpty(), qPrintable(m.title));
            QVERIFY2(!m.coverUrl(320).isEmpty(), qPrintable(m.title));
        }
    }

    // Daily Discovery, then New Arrivals, then the order the lists were walked.
    // The generated feed goes first so its run of "My Mix N" survives: taking the
    // saved list first would put "My Mix 1" and the saved radio in front of
    // "My Mix 2".
    void theTwoPersonalisedMixesLeadTheMergedList() {
        const QList<Mix> mixes = merged();
        QCOMPARE(mixes.at(0).mixType, QStringLiteral("DISCOVERY_MIX"));
        QCOMPARE(mixes.at(1).mixType, QStringLiteral("NEW_RELEASE_MIX"));
        QCOMPARE(titlesOf(mixes).mid(2, 8), kEightMyMixes);
        QCOMPARE(mixes.at(10).title, QStringLiteral("Saved Radio"));
        QCOMPARE(mixes.size(), 11);
    }

    // Two of the four saved mixes are on the generated page too - Daily Discovery
    // and "My Mix 1". "My New Arrivals" is not, which is the whole reason the
    // saved list has to be fetched, and the saved radio is not either. Each mix is
    // one row, placed where the generated feed put it. 9 + 4 - 2 = 11.
    void mergingDeduplicatesOnTheMixId() {
        const QList<Mix> mixes = merged();
        const QStringList ids = idsOf(mixes);
        QCOMPARE(QSet<QString>(ids.cbegin(), ids.cend()).size(), ids.size());
        QCOMPARE(ids.size(), 11);

        const QStringList generatedIds = idsOf(TidalClient::parseMixPage(generatedPage()));
        const QStringList savedIds     = idsOf(TidalClient::parseSavedMixes(savedPage()));
        int shared = 0;
        for (const QString &id : savedIds) if (generatedIds.contains(id)) ++shared;
        QCOMPARE(shared, 2);                       // Daily Discovery and "My Mix 1"
        QCOMPARE(generatedIds.size(), 9);          // 17 captured, less 8 video mixes
        QCOMPARE(savedIds.size(), 4);
        QCOMPARE(generatedIds.size() + savedIds.size() - shared, 11);
        for (const QString &id : savedIds)
            QCOMPARE(ids.count(id), 1);
    }

    // Where a mix is in both lists, the one record that has a `dateAdded` is the
    // saved one, and that is the half the sidebar's ordering needs - so it has to
    // survive the dedup although the generated record is the one kept.
    void aDateFromTheSavedListSurvivesTheDedup() {
        const QList<Mix> mixes = merged();

        // Daily Discovery is on both. The generated record carries no date.
        const Mix discovery = *std::find_if(mixes.cbegin(), mixes.cend(),
            [](const Mix &m) { return m.isDailyDiscovery(); });
        QCOMPARE(discovery.addedAt, instant("2026-06-08T19:33:03.142667Z"));

        // "My Mix 1" is on both; "My Mix 2" is generated only and has no date.
        const Mix one = *std::find_if(mixes.cbegin(), mixes.cend(),
            [](const Mix &m) { return m.title == QStringLiteral("My Mix 1"); });
        const Mix two = *std::find_if(mixes.cbegin(), mixes.cend(),
            [](const Mix &m) { return m.title == QStringLiteral("My Mix 2"); });
        QCOMPARE(one.addedAt, instant("2026-09-27T19:44:46.754991Z"));
        QCOMPARE(two.addedAt, 0LL);

        // It holds whichever way round the lists are merged; only the position
        // depends on the order.
        const QList<Mix> other = TidalClient::mergeMixLists(
            {TidalClient::parseSavedMixes(savedPage()), TidalClient::parseMixPage(generatedPage())});
        const Mix otherDiscovery = *std::find_if(other.cbegin(), other.cend(),
            [](const Mix &m) { return m.isDailyDiscovery(); });
        QCOMPARE(otherDiscovery.addedAt, discovery.addedAt);
    }

    // A source that failed is an absent source, not an empty list: fetchHomeMixes
    // hands the merge whatever came back, and one source answering must still
    // produce the mixes it holds.
    void oneMissingSourceStillYieldsTheOther() {
        const QList<Mix> generated = TidalClient::parseMixPage(generatedPage());
        const QList<Mix> saved     = TidalClient::parseSavedMixes(savedPage());
        QCOMPARE(idsOf(TidalClient::mergeMixLists({generated, {}})), idsOf(generated));
        QCOMPARE(idsOf(TidalClient::mergeMixLists({{}, saved})),
                 idsOf(TidalClient::mergeMixLists({saved})));
        QVERIFY(TidalClient::mergeMixLists({}).isEmpty());
        QVERIFY(TidalClient::mergeMixLists({{}, {}}).isEmpty());
    }

    // ── video mixes ──────────────────────────────────────────────────────

    // The app has no video playback anywhere, and `pages/mix` answers one of
    // these with a VIDEO_LIST of "Music Video" items rather than a TRACK_LIST,
    // so fetchMixTracks finds nothing in it. Eight of the seventeen tiles on
    // the Collection page were that.
    void videoMixesAreDropped() {
        QCOMPARE(rawItems(generatedPage(), 0).size(), 17);
        int rawVideo = 0;
        for (const QJsonValue &v : rawItems(generatedPage(), 0))
            if (v.toObject()["mixType"].toString() == QStringLiteral("VIDEO_DAILY_MIX")) ++rawVideo;
        QCOMPARE(rawVideo, 8);

        const QList<Mix> mixes = TidalClient::parseMixPage(generatedPage());
        QCOMPARE(mixes.size(), 9);
        QVERIFY2(typesOf(mixes).count(QStringLiteral("VIDEO_DAILY_MIX")) == 0,
                 qPrintable(listing(mixes)));
        for (const Mix &m : mixes)
            QVERIFY2(!m.isVideoMix(), qPrintable(m.title));
    }

    // Two different mixes on that page are both called "My Video Mix 7".
    // Dropping the video mixes disposes of the duplicate with them, which is
    // why nothing has to deduplicate on the title.
    void theDuplicateVideoMixTitleGoesWithThem() {
        QStringList rawTitles;
        for (const QJsonValue &v : rawItems(generatedPage(), 0))
            rawTitles << v.toObject()["title"].toString();
        QCOMPARE(rawTitles.count(QStringLiteral("My Video Mix 7")), 2);

        const QStringList titles = titlesOf(merged());
        for (const QString &t : titles)
            QVERIFY2(titles.count(t) == 1,
                     qPrintable(QStringLiteral("%1 is listed twice: %2")
                                    .arg(t, titles.join(QLatin1String(", ")))));
    }

    // `pages/for_you` has a third MIX_LIST row, "Radio stations for you", holding
    // fifteen ARTIST_MIX entries. They are *suggestions* - the user never saved
    // them - so nothing fetches that page, and a saved radio reaches the tab
    // through v2/favorites/mixes instead. The guard is that the only two sources
    // are the ones below.
    void nothingComesFromTheSuggestedRadioRow() {
        const QStringList ids = idsOf(merged());
        const QStringList fromSources =
            idsOf(TidalClient::parseMixPage(generatedPage()))
            + idsOf(TidalClient::parseSavedMixes(savedPage()));
        for (const QString &id : ids)
            QVERIFY2(fromSources.contains(id),
                     qPrintable(QStringLiteral("%1 came from neither source").arg(id)));
        QCOMPARE(merged().size(), 11);
    }

    // ── mixType is the only handle ───────────────────────────────────────

    // mixType is a *string* on these endpoints. Read as an object - which is
    // what Mix::fromJson used to do, to look for artwork in it - every mix
    // comes out with an empty one and there is no locale-safe way to tell them
    // apart, nor any way to filter the video ones.
    void mixTypeIsParsedAsAnIdentifier() {
        const QList<Mix> mixes = merged();

        const Mix discovery = *std::find_if(mixes.cbegin(), mixes.cend(),
            [](const Mix &m) { return m.isDailyDiscovery(); });
        QCOMPARE(discovery.title, QStringLiteral("My Daily Discovery"));
        QCOMPARE(discovery.id, QStringLiteral("016e5b32dafd59b9749297f12f5483"));

        const Mix arrivals = *std::find_if(mixes.cbegin(), mixes.cend(),
            [](const Mix &m) { return m.isNewArrivals(); });
        QCOMPARE(arrivals.title, QStringLiteral("My New Arrivals"));
        QCOMPARE(arrivals.id, QStringLiteral("011881f03495a3b81fe3c1dac0cde4"));

        // A "My Mix N" or a radio station is neither of the two.
        for (const Mix &m : mixes) {
            if (m.isDailyDiscovery() || m.isNewArrivals()) continue;
            QVERIFY2(!m.isDailyDiscovery() && !m.isNewArrivals(), qPrintable(m.title));
        }
    }

    // The ordering is on mixType, never on the title. A German account gets the
    // same mixes in the same places; matching the English title would leave the
    // two at the end for every user outside one locale.
    void orderingDoesNotReadTheTitle() {
        const auto germanise = [](const char *json) {
            QByteArray g(json);
            g.replace("My Daily Discovery", "Meine taegliche Entdeckung");
            g.replace("My New Arrivals",    "Meine Neuheiten");
            g.replace("My Mix ",            "Mein Mix ");
            return g;
        };
        const QByteArray gen   = germanise(kGeneratedPage);
        const QByteArray saved = germanise(kSavedMixes);

        const QList<Mix> mixes = TidalClient::mergeMixLists(
            {TidalClient::parseMixPage(pageOf(gen.constData())),
             TidalClient::parseSavedMixes(pageOf(saved.constData()))});
        QCOMPARE(mixes.size(), 11);
        QCOMPARE(mixes.at(0).title, QStringLiteral("Meine taegliche Entdeckung"));
        QCOMPARE(mixes.at(1).title, QStringLiteral("Meine Neuheiten"));
        QCOMPARE(mixes.at(2).title, QStringLiteral("Mein Mix 1"));
        QCOMPARE(mixes.at(9).title, QStringLiteral("Mein Mix 8"));
        // And the dedup is on the id, so the renamed German mixes still collapse
        // to one row each rather than doubling.
        const QStringList ids = idsOf(mixes);
        QCOMPARE(QSet<QString>(ids.cbegin(), ids.cend()).size(), 11);
    }

    // ── shapes that are not those responses ──────────────────────────────

    void unlabelledMixesAreKeptInPlace() {
        // An endpoint that does not label its mixes (an older page) still has to
        // come back whole and in order. Nothing is promoted and nothing is
        // dropped: the video filter matches a mixType, so an absent one is kept.
        const QJsonObject page = pageOf(R"json({"rows":[{"modules":[
            {"type":"MIX_LIST","pagedList":{"items":[
              {"id":"a","title":"First"},
              {"id":"b","title":"Second"}
            ]}}]}]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(titlesOf(mixes), QStringList({QStringLiteral("First"), QStringLiteral("Second")}));
        QVERIFY(mixes.at(0).mixType.isEmpty());
        QVERIFY(!mixes.at(0).isDailyDiscovery());
        QVERIFY(!mixes.at(0).isVideoMix());
    }

    void modulesThatAreNotMixListsAreSkipped() {
        const QJsonObject page = pageOf(R"json({"rows":[
            {"modules":[{"type":"TRACK_LIST","pagedList":{"items":[{"id":1,"title":"a track"}]}}]},
            {"modules":[{"type":"MIX_LIST","pagedList":{"items":[
              {"id":"m","title":"a mix","mixType":"DAILY_MIX"}]}}]}
          ]})json");
        const QList<Mix> mixes = TidalClient::parseMixPage(page);
        QCOMPARE(titlesOf(mixes), QStringList({QStringLiteral("a mix")}));

        // A page feed mixes module types freely - the captured for_you page has an
        // ALBUM_LIST beside its MIX_LISTs - and only MIX_LIST is read.
        const QJsonObject mixed = pageOf(R"json({"rows":[
            {"modules":[{"type":"ALBUM_LIST","pagedList":{"items":[
              {"id":1,"title":"an album"}]}}]},
            {"modules":[{"type":"MIX_LIST","pagedList":{"items":[
              {"id":"m2","title":"the only mix","mixType":"DAILY_MIX"}]}}]}
          ]})json");
        QCOMPARE(titlesOf(TidalClient::parseMixPage(mixed)),
                 QStringList({QStringLiteral("the only mix")}));
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
        const QList<Mix> mixes = merged();
        // These are absolute, pre-signed URLs, so the requested size is not
        // ours to choose: coverUrl() hands them back as they are.
        QCOMPARE(mixes.at(0).coverUrl(320),
                 QStringLiteral("https://images.tidal.com/0/016e5b/1500x1500?token=t"));
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
