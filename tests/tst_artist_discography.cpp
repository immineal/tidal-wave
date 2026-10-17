// An artist's discography: the three requests it takes, which of them marks a
// release as a guest appearance, and what happens when one does not come back.
// artists/<id>/albums with no `filter` answers the albums only. EPs and singles
// need filter=EPSANDSINGLES. filter=COMPILATIONS answers records by other
// artists that this one appears on. The artist's own two runs are paged to
// their end. The appears-on run is one request. What comes out holds one entry
// per record: the rule for that is tested in tests/tst_record_versions.cpp.
// FakeApi overrides TidalApi::get, so the cases drive the real TidalClient and
// can see filters and offsets. Every id, title and cover below is invented.

#include <QTest>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrlQuery>
#include <QVariantMap>

#include <functional>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/Models.h"
#include "api/RecordVersions.h"

using namespace Tidal;

namespace {

const QString kNoFilter    = QString();
const QString kEpsSingles  = QString::fromLatin1(TidalClient::kFilterEpsAndSingles);
const QString kAppearsOn   = QString::fromLatin1(TidalClient::kFilterAppearsOn);

constexpr qint64 kArtistId = 900000001;

QJsonObject release(qint64 id, const QString &title, const QString &type,
                    int numTracks, const QString &cover = QStringLiteral("aaaaaaaa-0000-0000-0000-000000000000"))
{
    QJsonObject o;
    o["id"]             = qint64(id);
    o["title"]          = title;
    o["type"]           = type;
    o["numberOfTracks"] = numTracks;
    o["cover"]          = cover;
    return o;
}

const QStringList kStereo   = {QStringLiteral("STEREO")};
const QStringList kAtmos    = {QStringLiteral("DOLBY_ATMOS")};
const QStringList kLossless = {QStringLiteral("LOSSLESS")};
const QStringList kHiRes    = {QStringLiteral("LOSSLESS"), QStringLiteral("HIRES_LOSSLESS")};

// One product of a record as the server lists it, with a cover of its own.
// `tags` is mediaMetadata.tags.
QJsonObject product(qint64 id, const QString &title, const QString &type, int numTracks,
                    int duration, bool isExplicit, const QStringList &modes,
                    const QStringList &tags, int popularity = 0)
{
    QJsonObject o = release(id, title, type, numTracks,
                            QStringLiteral("%1-0000-0000-0000-000000000000")
                                .arg(id % 100000000, 8, 10, QLatin1Char('0')));
    o["duration"]       = duration;
    o["explicit"]       = isExplicit;
    o["audioQuality"]   = modes == kAtmos ? QStringLiteral("LOW") : QStringLiteral("LOSSLESS");
    o["audioModes"]     = QJsonArray::fromStringList(modes);
    o["mediaMetadata"]  = QJsonObject{{QStringLiteral("tags"), QJsonArray::fromStringList(tags)}};
    o["numberOfVideos"] = 0;
    o["popularity"]     = popularity;
    o["allowStreaming"] = true;
    o["streamReady"]    = true;
    return o;
}

// The six products of one record: explicit and clean, each as 16-bit stereo,
// hi-res stereo and Dolby Atmos only. The explicit hi-res stereo one is
// `firstId + 4`. A Dolby Atmos one leads and is the most played.
QList<QJsonObject> sixProducts(qint64 firstId, const QString &title, const QString &type,
                               int numTracks, int duration)
{
    return {
        product(firstId,     title, type, numTracks, duration + 4, true,  kAtmos,  kAtmos,    80),
        product(firstId + 1, title, type, numTracks, duration - 1, false, kStereo, kLossless, 40),
        product(firstId + 2, title, type, numTracks, duration - 1, false, kStereo, kHiRes,    45),
        product(firstId + 3, title, type, numTracks, duration,     true,  kStereo, kLossless, 60),
        product(firstId + 4, title, type, numTracks, duration,     true,  kStereo, kHiRes,    70),
        product(firstId + 5, title, type, numTracks, duration + 3, false, kAtmos,  kAtmos,    30),
    };
}

// A TidalApi whose GETs are answered out of a per-filter catalogue, paged as
// the server pages. Synchronous by default. setDeferred(true) parks the replies
// so a test can land them in any order.
class FakeApi : public TidalApi {
public:
    struct Request {
        QString endpoint;
        QString filter;
        int     limit  = 0;
        int     offset = 0;
    };

    QList<Request> requests;

    // filter -> the releases the server has under it. "" is the unfiltered
    // request.
    QHash<QString, QList<QJsonObject>> catalogue;
    // filter -> the error that request answers with. Empty means it succeeds.
    QHash<QString, QString> errors;
    // filter -> the first offset at which `errors` applies. 0 (the default)
    // fails the filter outright; a higher number fails it part-way through its
    // paging run.
    QHash<QString, int> errorFromOffset;
    // filter -> the most items one reply carries, whatever `limit` asks for.
    // Absent means the server fills the page.
    QHash<QString, int> pageCap;

    void setDeferred(bool on) { m_deferred = on; }
    int  parked() const { return int(m_parked.size()); }
    // In the order they were asked.
    void flush() {
        QList<std::function<void()>> pending;
        pending.swap(m_parked);
        for (auto &p : pending) p();
    }
    // Last asked, first answered.
    void flushReversed() {
        QList<std::function<void()>> pending;
        pending.swap(m_parked);
        for (auto it = pending.rbegin(); it != pending.rend(); ++it) (*it)();
    }

    QStringList filtersAsked() const {
        QStringList out;
        for (const Request &r : requests) out << r.filter;
        return out;
    }
    QList<int> offsetsAsked(const QString &filter) const {
        QList<int> out;
        for (const Request &r : requests)
            if (r.filter == filter) out << r.offset;
        return out;
    }

    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) override {
        Request r;
        r.endpoint = endpoint;
        r.filter   = params.queryItemValue(QStringLiteral("filter"));
        r.limit    = params.queryItemValue(QStringLiteral("limit")).toInt();
        r.offset   = params.queryItemValue(QStringLiteral("offset")).toInt();
        requests.append(r);

        const QString err = errors.value(r.filter);
        if (!err.isEmpty() && r.offset >= errorFromOffset.value(r.filter, 0)) {
            answer(std::move(cb), QJsonObject(), err);
            return;
        }

        const QList<QJsonObject> all = catalogue.value(r.filter);
        const int most = qMin(r.limit, pageCap.value(r.filter, r.limit));
        QJsonArray items;
        for (int i = r.offset; i < all.size() && items.size() < most; ++i)
            items.append(all.at(i));

        QJsonObject root;
        root["limit"]              = r.limit;
        root["offset"]             = r.offset;
        root["totalNumberOfItems"] = int(all.size());
        root["items"]              = items;
        answer(std::move(cb), root, QString());
    }

private:
    void answer(JsonCallback cb, const QJsonObject &root, const QString &err) {
        if (!m_deferred) { cb(root, err); return; }
        m_parked.append([cb, root, err]() { cb(root, err); });
    }

    bool m_deferred = false;
    QList<std::function<void()>> m_parked;
};

// One fetchArtistAlbums() run and what it delivered.
struct Run {
    QList<Album> albums;
    QString      err;
    int          replies = 0;

    QList<qint64> ids() const {
        QList<qint64> out;
        for (const Album &a : albums) out << a.id;
        return out;
    }
    bool has(qint64 id) const { return ids().contains(id); }
    const Album *find(qint64 id) const {
        for (const Album &a : albums) if (a.id == id) return &a;
        return nullptr;
    }
    QList<qint64> featuredIds() const {
        QList<qint64> out;
        for (const Album &a : albums) if (a.featured) out << a.id;
        return out;
    }
    QList<qint64> titleSharedIds() const {
        QList<qint64> out;
        for (const Album &a : albums) if (a.titleShared) out << a.id;
        return out;
    }
};

void start(TidalClient &client, Run &run) {
    client.fetchArtistAlbums(kArtistId, [&run](QList<Album> albums, QString err) {
        ++run.replies;
        run.albums = albums;
        run.err    = err;
    });
}

// `count` releases of one type, ids counting up from `firstId`.
QList<QJsonObject> releases(qint64 firstId, int count, const QString &type, int numTracks) {
    QList<QJsonObject> out;
    for (int i = 0; i < count; ++i)
        out << release(firstId + i, QStringLiteral("Nummer %1").arg(i + 1), type, numTracks);
    return out;
}

// An artist with one of each: an album, a single, an EP, and one record by
// somebody else under the appears-on filter. The guest record has the shape of
// the artist's own album, so `type` cannot tell the two apart.
void seedOneOfEach(FakeApi &api) {
    api.catalogue[kNoFilter]   = { release(900001001, QStringLiteral("Ein Album"), QStringLiteral("ALBUM"), 11,
                                           QStringLiteral("11111111-0000-0000-0000-000000000000")) };
    api.catalogue[kEpsSingles] = { release(900001002, QStringLiteral("Eine Single"), QStringLiteral("SINGLE"), 1,
                                           QStringLiteral("22222222-0000-0000-0000-000000000000")),
                                   release(900001003, QStringLiteral("Eine EP"), QStringLiteral("EP"), 4,
                                           QStringLiteral("33333333-0000-0000-0000-000000000000")) };
    api.catalogue[kAppearsOn]  = { release(900001004, QStringLiteral("Fremdes Album"), QStringLiteral("ALBUM"), 12,
                                           QStringLiteral("44444444-0000-0000-0000-000000000000")) };
}

} // namespace

class TestArtistDiscography : public QObject {
    Q_OBJECT

private slots:

    // ── the three requests ───────────────────────────────────────────────────

    // All three filters go out against the one path.
    void threeFiltersAgainstTheOnePath() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        const QStringList asked = api.filtersAsked();
        QVERIFY2(asked.contains(kNoFilter),
                 "the unfiltered request - the one that answers the albums - was not sent");
        QVERIFY2(asked.contains(kEpsSingles),
                 qPrintable(QStringLiteral("no filter=EPSANDSINGLES request was sent; filters asked: [%1]")
                            .arg(asked.join(QStringLiteral(", ")))));
        // The wire value is pinned as a literal: the constant is named for what
        // the filter answers, and the server only takes this spelling.
        QVERIFY2(asked.contains(QStringLiteral("COMPILATIONS")),
                 qPrintable(QStringLiteral("no filter=COMPILATIONS request was sent; filters asked: [%1]")
                            .arg(asked.join(QStringLiteral(", ")))));

        for (const FakeApi::Request &r : api.requests)
            QCOMPARE(r.endpoint, QStringLiteral("artists/900000001/albums"));
    }

    // The single and the EP have to be in the list the page is handed, or its
    // Singles & EPs section has nothing to show and hides itself.
    void singlesAndEpsReachTheCaller() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 4);
        QVERIFY2(run.has(900001002), "the single is missing from the discography");
        QVERIFY2(run.has(900001003), "the EP is missing from the discography");
        QVERIFY2(run.has(900001004), "the guest appearance is missing from the list");
        QVERIFY2(run.has(900001001), "the album is missing from the discography");
    }

    // The row of a release comes from `type`, and from the track count only
    // when there is none. Album::type has to survive the parse, or a 4-track
    // EP is filed as an album.
    void theReleaseTypeSurvivesTheParse() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        const Album *album  = run.find(900001001);
        const Album *single = run.find(900001002);
        const Album *ep     = run.find(900001003);
        const Album *guest  = run.find(900001004);
        QVERIFY(album && single && ep && guest);
        QCOMPARE(album->type,  QStringLiteral("ALBUM"));
        QCOMPARE(single->type, QStringLiteral("SINGLE"));
        QCOMPARE(ep->type,     QStringLiteral("EP"));
        QCOMPARE(guest->type,  QStringLiteral("ALBUM"));
        // The fallback must not be the thing doing the work: this EP has four
        // tracks, which `numTracks <= 3` would file under Albums.
        QCOMPARE(ep->numTracks, 4);
    }

    // The last hop before a page: the map TidalBridge::albumToMap builds. The
    // QML tests run on a stub bridge and cannot see it.
    void theReleaseTypeSurvivesTheHopToQml() {
        Album a;
        a.id        = 900008001;
        a.title     = QStringLiteral("Eine EP");
        a.type      = QStringLiteral("EP");
        a.numTracks = 4;

        const QVariantMap m = TidalBridge::albumToMap(a);
        QCOMPARE(m.value(QStringLiteral("type")).toString(), QStringLiteral("EP"));
        QCOMPARE(m.value(QStringLiteral("numTracks")).toInt(), 4);
        // The type decides: four tracks alone would say Albums.
        QCOMPARE(m.value(QStringLiteral("section")).toString(), QStringLiteral("s"));
    }

    // ── whose record it is ───────────────────────────────────────────────────

    // The three responses carry the same fields, so only the request says that
    // a release is somebody else's. The client has to mark it.
    void theAppearsOnReleasesAreMarked() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.albums.size(), 4);
        const Album *guest = run.find(900001004);
        QVERIFY(guest);
        QVERIFY2(guest->featured,
                 "the release from filter=COMPILATIONS came back unmarked, so the page "
                 "shows another artist's record as this one's own");
        // A flag set on everything would empty both of the artist's own rows.
        QCOMPARE(run.featuredIds(), (QList<qint64>{900001004}));
    }

    // The appears-on run is one request. The row holds that page, in the order
    // the server sent it, and every card of it is marked.
    void theAppearsOnRunStopsAfterOnePage() {
        FakeApi api;
        api.catalogue[kNoFilter] = {
            release(900009001, QStringLiteral("Eigenes"), QStringLiteral("ALBUM"), 10) };
        api.catalogue[kAppearsOn] = releases(900009100, 120, QStringLiteral("ALBUM"), 12);
        QList<qint64> firstPage;
        for (int i = 0; i < 50; ++i) firstPage << 900009100 + i;
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(api.offsetsAsked(kAppearsOn), (QList<int>{0}));
        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 51);
        QCOMPARE(run.featuredIds(), firstPage);
    }

    // One request also when the server cuts the page short of `limit`.
    void aShortAppearsOnPageStillEndsTheRun() {
        FakeApi api;
        api.catalogue[kNoFilter] = {
            release(900009301, QStringLiteral("Eigenes"), QStringLiteral("ALBUM"), 10) };
        api.catalogue[kAppearsOn] = releases(900009400, 120, QStringLiteral("ALBUM"), 12);
        api.pageCap[kAppearsOn] = 30;
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(api.offsetsAsked(kAppearsOn), (QList<int>{0}));
        QCOMPARE(run.albums.size(), 31);
        QCOMPARE(run.featuredIds().size(), 30);
    }

    // A long career: the artist's own two runs page to their end beside an
    // appears-on run of one request.
    void aLongCareerCostsOneAppearsOnRequest() {
        FakeApi api;
        api.catalogue[kNoFilter]   = releases(900010000, 81, QStringLiteral("ALBUM"), 10);
        api.catalogue[kEpsSingles] = releases(900011000, 283, QStringLiteral("SINGLE"), 1);
        api.catalogue[kAppearsOn]  = releases(900020000, 3199, QStringLiteral("COMPILATION"), 20);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(api.requests.size(), 9);
        QCOMPARE(api.offsetsAsked(kNoFilter), (QList<int>{0, 50}));
        QCOMPARE(api.offsetsAsked(kEpsSingles), (QList<int>{0, 50, 100, 150, 200, 250}));
        QCOMPARE(api.offsetsAsked(kAppearsOn), (QList<int>{0}));
        QCOMPARE(run.albums.size(), 81 + 283 + 50);
        QCOMPARE(run.featuredIds().size(), 50);
        QVERIFY2(run.has(900011282), "the last page of the singles was dropped");
    }

    // The last hop before the page. The QML tests build their own maps, so a
    // field dropped in albumToMap() fails nothing over there.
    void theFeaturedFlagSurvivesTheHopToQml() {
        Album own;
        own.id    = 900008101;
        own.title = QStringLiteral("Eigenes Album");
        own.type  = QStringLiteral("ALBUM");

        Album guest    = own;
        guest.id       = 900008102;
        guest.title    = QStringLiteral("Fremdes Album");
        guest.featured = true;

        const QVariantMap ownMap   = TidalBridge::albumToMap(own);
        const QVariantMap guestMap = TidalBridge::albumToMap(guest);

        QVERIFY2(guestMap.contains(QStringLiteral("featured")),
                 "albumToMap() hands QML no `featured` key");
        QCOMPARE(guestMap.value(QStringLiteral("featured")).toBool(), true);
        QCOMPARE(ownMap.value(QStringLiteral("featured")).toBool(), false);
        // The mark is what sends the record to Appears on.
        QCOMPARE(guestMap.value(QStringLiteral("section")).toString(), QStringLiteral("f"));
        QCOMPARE(ownMap.value(QStringLiteral("section")).toString(), QStringLiteral("a"));
    }

    // ── one of three failing ─────────────────────────────────────────────────

    // An artist with albums and a failed appears-on request still has a
    // discography. ArtistPage shows its failure panel only when nothing arrived,
    // so no error is handed over here.
    void oneFilterFailingKeepsTheOtherTwo() {
        FakeApi api;
        seedOneOfEach(api);
        api.errors[kAppearsOn] = QStringLiteral("503 Service Unavailable");
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 3);
        QVERIFY2(run.has(900001001), "a failed appears-on request took the albums with it");
        QVERIFY2(run.has(900001002), "a failed appears-on request took the singles with it");
        QCOMPARE(run.featuredIds(), QList<qint64>());
    }

    // The other way round: a failed singles request must not blank the albums.
    void aFailedSinglesRequestKeepsTheAlbums() {
        FakeApi api;
        seedOneOfEach(api);
        api.errors[kEpsSingles] = QStringLiteral("500 Internal Server Error");
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 2);
        QVERIFY2(run.has(900001001), "a failed singles request took the albums with it");
        QVERIFY2(run.has(900001004), "a failed singles request took the guest appearances with it");
    }

    // The total failure that ArtistPage's failure panel is for: a withdrawn
    // artist answers 404 on all three.
    void allThreeFailingReportsTheReason() {
        FakeApi api;
        seedOneOfEach(api);
        api.errors[kNoFilter]   = QStringLiteral("404 Not Found");
        api.errors[kEpsSingles] = QStringLiteral("404 Not Found");
        api.errors[kAppearsOn]  = QStringLiteral("404 Not Found");
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QVERIFY2(run.albums.isEmpty(), "a refused artist answered with releases");
        QCOMPARE(run.err, QStringLiteral("404 Not Found"));
    }

    // An artist Tidal has nothing filed under is not a failure: the page draws
    // a different thing for each.
    void anArtistWithNothingIsNotAFailure() {
        FakeApi api;
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QVERIFY(run.albums.isEmpty());
        QCOMPARE(run.err, QString());
    }

    // ── ordering, dedup, paging ──────────────────────────────────────────────

    // A release can answer to two filters at once. It belongs in the list once,
    // and where the album list put it: ArtistPage sections the list but keeps
    // the order inside each section.
    void aReleaseUnderTwoFiltersAppearsOnce() {
        FakeApi api;
        api.catalogue[kNoFilter] = {
            release(900002001, QStringLiteral("Erstes"), QStringLiteral("ALBUM"), 10),
            release(900002002, QStringLiteral("Zweites"), QStringLiteral("ALBUM"), 9),
        };
        api.catalogue[kAppearsOn] = {
            // The same id the unfiltered request already answered with.
            release(900002002, QStringLiteral("Zweites"), QStringLiteral("ALBUM"), 9),
            release(900002003, QStringLiteral("Drittes"), QStringLiteral("COMPILATION"), 18),
        };
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.albums.size(), 3);
        const QList<qint64> ids = run.ids();
        QCOMPARE(ids, (QList<qint64>{900002001, 900002002, 900002003}));
    }

    // A record the artist made can also answer the appears-on request. It is
    // theirs and stays unmarked, whichever of their own two lists carries it.
    // The guest-only record is the control: marking nothing would pass the rest.
    void aReleaseUnderTwoFiltersStaysTheArtistsOwn() {
        FakeApi api;
        api.catalogue[kNoFilter] = {
            release(900002101, QStringLiteral("Eigenes"), QStringLiteral("ALBUM"), 10),
        };
        api.catalogue[kEpsSingles] = {
            release(900002103, QStringLiteral("Eigene Single"), QStringLiteral("SINGLE"), 1),
        };
        api.catalogue[kAppearsOn] = {
            release(900002101, QStringLiteral("Eigenes"), QStringLiteral("ALBUM"), 10),
            release(900002102, QStringLiteral("Fremdes"), QStringLiteral("ALBUM"), 12),
            release(900002103, QStringLiteral("Eigene Single"), QStringLiteral("SINGLE"), 1),
        };
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.ids(), (QList<qint64>{900002101, 900002103, 900002102}));
        QCOMPARE(run.featuredIds(), (QList<qint64>{900002102}));
    }

    // The albums come first and the guest appearances last, because that is
    // the order the three lists are merged in and the rows preserve it.
    void theAlbumsComeBeforeTheRest() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.ids(), (QList<qint64>{900001001, 900001002, 900001003, 900001004}));
    }

    // Each of the artist's own filters pages to its end, so a prolific artist
    // is not cut at the first fifty.
    void aProlificArtistIsPagedToTheEnd() {
        FakeApi api;
        QList<QJsonObject> many;
        for (int i = 0; i < 120; ++i)
            many << release(900003000 + i, QStringLiteral("Album %1").arg(i + 1),
                            QStringLiteral("ALBUM"), 10,
                            QStringLiteral("%1-0000-0000-0000-000000000000")
                                .arg(i, 8, 10, QLatin1Char('0')));
        api.catalogue[kNoFilter] = many;
        api.catalogue[kEpsSingles] = {
            release(900004001, QStringLiteral("Eine Single"), QStringLiteral("SINGLE"), 1,
                    QStringLiteral("55555555-0000-0000-0000-000000000000")) };
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 121);
        QCOMPARE(api.offsetsAsked(kNoFilter), (QList<int>{0, 50, 100}));
        // The filter that fits in one page asks once and stops.
        QCOMPARE(api.offsetsAsked(kEpsSingles), (QList<int>{0}));
        QVERIFY2(run.has(900003119), "the last page of a prolific artist's albums was dropped");
        QVERIFY2(run.has(900004001), "paging the albums lost the single");
    }

    // A filter that fails on its second page keeps its first.
    void aFilterThatFailsHalfwayKeepsWhatItHad() {
        FakeApi api;
        QList<QJsonObject> many;
        for (int i = 0; i < 120; ++i)
            many << release(900005000 + i, QStringLiteral("Album %1").arg(i + 1),
                            QStringLiteral("ALBUM"), 10,
                            QStringLiteral("%1-0000-0000-0000-000000000000")
                                .arg(i, 8, 10, QLatin1Char('0')));
        api.catalogue[kNoFilter]      = many;
        api.errors[kNoFilter]         = QStringLiteral("timed out");
        api.errorFromOffset[kNoFilter] = 50;
        api.catalogue[kEpsSingles] = {
            release(900006001, QStringLiteral("Eine Single"), QStringLiteral("SINGLE"), 1,
                    QStringLiteral("66666666-0000-0000-0000-000000000000")) };
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 51);
        QVERIFY2(run.has(900005000), "the page that did arrive was thrown away with the one that did not");
        QVERIFY2(run.has(900006001), "a half-failed albums run took the single with it");
    }

    // ── arrival order ────────────────────────────────────────────────────────

    // Three requests, one reply, whatever order the server answers in.
    // ArtistPage clears `loading` and assigns `albums` in that one callback, so
    // a second or third delivery would blank the page it had just filled.
    void repliesArrivingBackwardsStillDeliverOneMergedList() {
        FakeApi api;
        seedOneOfEach(api);
        api.setDeferred(true);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(api.parked(), 3);
        QCOMPARE(run.replies, 0);
        api.flushReversed();

        QCOMPARE(run.replies, 1);
        QCOMPARE(run.albums.size(), 4);
        // Still albums first: the order is the order the lists are merged in.
        QCOMPARE(run.ids(), (QList<qint64>{900001001, 900001002, 900001003, 900001004}));
        // The appears-on reply landed first here and is still the only marked one.
        QCOMPARE(run.featuredIds(), (QList<qint64>{900001004}));
    }

    // ── one entry per record ─────────────────────────────────────────────────

    // Three lists in, one entry per record out. The album, the single and the
    // record by somebody else share a title, and the first and the last a
    // track count and a length as well.
    void theProductsOfOneRecordReachTheCallerAsOneEntry() {
        FakeApi api;
        const QString t = QStringLiteral("Nachtfahrt");
        api.catalogue[kNoFilter]   = sixProducts(900030000, t, QStringLiteral("ALBUM"), 12, 2710);
        api.catalogue[kNoFilter]  << product(900030100, QStringLiteral("Morgenrot"),
                                             QStringLiteral("ALBUM"), 9, 2400, false, kStereo, kLossless);
        api.catalogue[kEpsSingles] = sixProducts(900031000, t, QStringLiteral("SINGLE"), 1, 215);
        api.catalogue[kAppearsOn]  = sixProducts(900032000, t, QStringLiteral("ALBUM"), 12, 2710);
        api.catalogue[kAppearsOn] << product(900032100, QStringLiteral("Sammlung"),
                                             QStringLiteral("COMPILATION"), 20, 4800, false, kStereo, kLossless);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.err, QString());
        QVERIFY2(run.albums.size() == 5,
                 qPrintable(QStringLiteral("20 products of 5 records came out as %1 entries")
                            .arg(run.albums.size())));
        // Each record where its first product stood, and the explicit hi-res
        // stereo product standing for it.
        QCOMPARE(run.ids(), (QList<qint64>{900030004, 900030100, 900031004, 900032004, 900032100}));
        QCOMPARE(run.featuredIds(), (QList<qint64>{900032004, 900032100}));
        const Album *album = run.find(900030004);
        QVERIFY(album);
        QVERIFY(album->explicit_);
        QCOMPARE(album->audioModes, kStereo);
        QCOMPARE(album->mediaTags, kHiRes);
    }

    // The fields that tell the products of a record apart. The rule reads
    // them off Album, so each has to survive the parse.
    void whatTellsVersionsApartSurvivesTheParse() {
        FakeApi api;
        QJsonObject o = product(900033001, QStringLiteral("Nachtfahrt (Live)"), QStringLiteral("ALBUM"),
                                12, 2713, true, kAtmos, kAtmos, 61);
        o["version"]        = QStringLiteral("Live");
        o["numberOfVideos"] = 2;
        o["streamReady"]    = false;
        api.catalogue[kNoFilter] = { o };
        TidalClient client{&api};
        Run run;
        start(client, run);

        const Album *a = run.find(900033001);
        QVERIFY(a);
        QCOMPARE(a->version, QStringLiteral("Live"));
        QCOMPARE(a->explicit_, true);
        QCOMPARE(a->audioModes, kAtmos);
        QCOMPARE(a->mediaTags, kAtmos);
        QCOMPARE(a->numVideos, 2);
        QCOMPARE(a->popularity, 61);
        QCOMPARE(a->allowStreaming, true);
        QCOMPARE(a->streamReady, false);
        QCOMPARE(a->duration, 2713);
    }

    // An album nested in a track says nothing about streaming and counts as
    // streamable. Only a stated refusal makes it otherwise.
    void anAlbumThatSaysNothingAboutStreamingCountsAsStreamable() {
        const Album silent = Album::fromJson(release(900034001, QStringLiteral("Stilles"),
                                                     QStringLiteral("ALBUM"), 10));
        QVERIFY(silent.allowStreaming);
        QVERIFY(silent.streamReady);
        QVERIFY(!silent.explicit_);
        QVERIFY(silent.audioModes.isEmpty());
        QVERIFY(silent.mediaTags.isEmpty());

        QJsonObject refused = release(900034002, QStringLiteral("Gesperrtes"),
                                      QStringLiteral("ALBUM"), 10);
        refused["allowStreaming"] = false;
        QVERIFY(!Album::fromJson(refused).allowStreaming);
    }

    // The last hop before a page: what it needs to name a version.
    void whatNamesAVersionSurvivesTheHopToQml() {
        Album a;
        a.id         = 900035001;
        a.title      = QStringLiteral("Nachtfahrt");
        a.explicit_  = true;
        a.audioModes = kAtmos;
        a.mediaTags  = kAtmos;

        const QVariantMap m = TidalBridge::albumToMap(a);
        QVERIFY2(m.contains(QStringLiteral("explicit_")), "albumToMap() hands QML no `explicit_` key");
        QCOMPARE(m.value(QStringLiteral("explicit_")).toBool(), true);
        QCOMPARE(m.value(QStringLiteral("audioModes")).toStringList(), kAtmos);
        QCOMPARE(m.value(QStringLiteral("mediaTags")).toStringList(), kAtmos);

        const QVariantMap plain = TidalBridge::albumToMap(Album());
        QCOMPARE(plain.value(QStringLiteral("explicit_")).toBool(), false);
        QVERIFY(plain.contains(QStringLiteral("audioModes")));
        QVERIFY(plain.contains(QStringLiteral("mediaTags")));
    }

    // ArtistPage files a release by the `section` key and works nothing out
    // itself, so the key has to say what the rule says.
    void theRowSurvivesTheHopToQml() {
        Album album;
        album.type      = QStringLiteral("ALBUM");
        album.numTracks = 11;
        Album ep = album;
        ep.type      = QStringLiteral("EP");
        ep.numTracks = 4;
        Album guest = album;
        guest.featured = true;

        QCOMPARE(TidalBridge::albumToMap(album).value(QStringLiteral("section")).toString(),
                 QStringLiteral("a"));
        QCOMPARE(TidalBridge::albumToMap(ep).value(QStringLiteral("section")).toString(),
                 QStringLiteral("s"));
        QCOMPARE(TidalBridge::albumToMap(guest).value(QStringLiteral("section")).toString(),
                 QStringLiteral("f"));
        for (const Album &a : {album, ep, guest})
            QCOMPARE(TidalBridge::albumToMap(a).value(QStringLiteral("section")).toString(),
                     recordSectionKey(a));
    }

    // Records of one title reach the caller marked, each record once, and the
    // same title in another row marks nothing there.
    void entriesThatShareATitleReachTheCallerMarked() {
        FakeApi api;
        const QString t = QStringLiteral("Nachtfahrt");
        api.catalogue[kNoFilter]  = sixProducts(900036000, t, QStringLiteral("ALBUM"), 14, 3400);
        api.catalogue[kNoFilter] << product(900036100, t, QStringLiteral("ALBUM"), 13, 3150,
                                            true, kAtmos, kAtmos);
        api.catalogue[kAppearsOn] = { product(900036200, t, QStringLiteral("ALBUM"), 14, 3400,
                                              false, kStereo, kLossless) };
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.ids(), (QList<qint64>{900036004, 900036100, 900036200}));
        QCOMPARE(run.titleSharedIds(), (QList<qint64>{900036004, 900036100}));
    }

    // ArtistPage words a card by this and works nothing out about titles.
    void aSharedTitleSurvivesTheHopToQml() {
        Album a;
        a.title       = QStringLiteral("Nachtfahrt");
        a.titleShared = true;
        const QVariantMap m = TidalBridge::albumToMap(a);
        QVERIFY2(m.contains(QStringLiteral("titleShared")),
                 "albumToMap() hands QML no `titleShared` key");
        QCOMPARE(m.value(QStringLiteral("titleShared")).toBool(), true);
        QCOMPARE(TidalBridge::albumToMap(Album()).value(QStringLiteral("titleShared")).toBool(),
                 false);
    }

    // ── the merge on its own ─────────────────────────────────────────────────

    void mergeAlbumListsKeepsTheFirstPositionAndDropsRepeats() {
        Album a; a.id = 900007001; a.title = QStringLiteral("A");
        Album b; b.id = 900007002; b.title = QStringLiteral("B");
        Album bAgain = b;
        Album c; c.id = 900007003; c.title = QStringLiteral("C");
        // The later list is the marked one, as fetchArtistAlbums() hands it over.
        bAgain.featured = true;
        c.featured      = true;

        const QList<Album> merged =
            TidalClient::mergeAlbumLists({{a, b}, {bAgain, c}});
        QCOMPARE(merged.size(), 3);
        QCOMPARE(merged.at(0).id, a.id);
        QCOMPARE(merged.at(1).id, b.id);
        QCOMPARE(merged.at(2).id, c.id);
        QVERIFY2(!merged.at(1).featured,
                 "the repeated id kept the later copy's mark");
        QVERIFY2(merged.at(2).featured,
                 "an id that only the later list carries lost its mark");
    }
};

QTEST_GUILESS_MAIN(TestArtistDiscography)
#include "tst_artist_discography.moc"
