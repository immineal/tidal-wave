// An artist's discography: the three requests it takes, and what happens when
// one of them does not come back. artists/<id>/albums with no `filter` answers
// the albums only. EPs and singles need filter=EPSANDSINGLES, compilations
// filter=COMPILATIONS, and each run is paged to its end.
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

using namespace Tidal;

namespace {

const QString kNoFilter    = QString();
const QString kEpsSingles  = QString::fromLatin1(TidalClient::kFilterEpsAndSingles);
const QString kComps       = QString::fromLatin1(TidalClient::kFilterCompilations);

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
        QJsonArray items;
        for (int i = r.offset; i < all.size() && items.size() < r.limit; ++i)
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
};

void start(TidalClient &client, Run &run) {
    client.fetchArtistAlbums(kArtistId, [&run](QList<Album> albums, QString err) {
        ++run.replies;
        run.albums = albums;
        run.err    = err;
    });
}

// An artist with one of each: album 1, single 2, compilation 3.
void seedOneOfEach(FakeApi &api) {
    api.catalogue[kNoFilter]   = { release(900001001, QStringLiteral("Ein Album"), QStringLiteral("ALBUM"), 11,
                                           QStringLiteral("11111111-0000-0000-0000-000000000000")) };
    api.catalogue[kEpsSingles] = { release(900001002, QStringLiteral("Eine Single"), QStringLiteral("SINGLE"), 1,
                                           QStringLiteral("22222222-0000-0000-0000-000000000000")),
                                   release(900001003, QStringLiteral("Eine EP"), QStringLiteral("EP"), 4,
                                           QStringLiteral("33333333-0000-0000-0000-000000000000")) };
    api.catalogue[kComps]      = { release(900001004, QStringLiteral("Eine Sammlung"), QStringLiteral("COMPILATION"), 20,
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
        QVERIFY2(asked.contains(kComps),
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
        QVERIFY2(run.has(900001004), "the compilation is missing from the discography");
        QVERIFY2(run.has(900001001), "the album is missing from the discography");
    }

    // ArtistPage splits the list on `type` and falls back to the track count
    // only when there is none. Album::type has to survive the parse, or a
    // 4-track EP is filed as an album.
    void theReleaseTypeSurvivesTheParse() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        const Album *album  = run.find(900001001);
        const Album *single = run.find(900001002);
        const Album *ep     = run.find(900001003);
        const Album *comp   = run.find(900001004);
        QVERIFY(album && single && ep && comp);
        QCOMPARE(album->type,  QStringLiteral("ALBUM"));
        QCOMPARE(single->type, QStringLiteral("SINGLE"));
        QCOMPARE(ep->type,     QStringLiteral("EP"));
        QCOMPARE(comp->type,   QStringLiteral("COMPILATION"));
        // The fallback must not be the thing doing the work: this EP has four
        // tracks, which `numTracks <= 3` would file under Albums.
        QCOMPARE(ep->numTracks, 4);
    }

    // The last hop before the page: ArtistPage reads `type` off the map
    // TidalBridge::albumToMap builds. The QML tests run on a stub bridge and
    // cannot see it.
    void theReleaseTypeSurvivesTheHopToQml() {
        Album a;
        a.id        = 900008001;
        a.title     = QStringLiteral("Eine EP");
        a.type      = QStringLiteral("EP");
        a.numTracks = 4;

        const QVariantMap m = TidalBridge::albumToMap(a);
        QCOMPARE(m.value(QStringLiteral("type")).toString(), QStringLiteral("EP"));
        QCOMPARE(m.value(QStringLiteral("numTracks")).toInt(), 4);
    }

    // ── one of three failing ─────────────────────────────────────────────────

    // An artist with albums and a failed compilations request still has a
    // discography. ArtistPage shows its failure panel only when nothing arrived,
    // so no error is handed over here.
    void oneFilterFailingKeepsTheOtherTwo() {
        FakeApi api;
        seedOneOfEach(api);
        api.errors[kComps] = QStringLiteral("503 Service Unavailable");
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(run.err, QString());
        QCOMPARE(run.albums.size(), 3);
        QVERIFY2(run.has(900001001), "a failed compilations request took the albums with it");
        QVERIFY2(run.has(900001002), "a failed compilations request took the singles with it");
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
        QVERIFY2(run.has(900001004), "a failed singles request took the compilations with it");
    }

    // The total failure that ArtistPage's failure panel is for: a withdrawn
    // artist answers 404 on all three.
    void allThreeFailingReportsTheReason() {
        FakeApi api;
        seedOneOfEach(api);
        api.errors[kNoFilter]   = QStringLiteral("404 Not Found");
        api.errors[kEpsSingles] = QStringLiteral("404 Not Found");
        api.errors[kComps]      = QStringLiteral("404 Not Found");
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
        api.catalogue[kComps] = {
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

    // The albums come first and the compilations last, because that is the
    // order the three lists are merged in and the sections preserve it.
    void theAlbumsComeBeforeTheRest() {
        FakeApi api;
        seedOneOfEach(api);
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.ids(), (QList<qint64>{900001001, 900001002, 900001003, 900001004}));
    }

    // Each filter pages to its own end, so a prolific artist is not cut at the
    // first fifty.
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
    }

    // ── the merge on its own ─────────────────────────────────────────────────

    void mergeAlbumListsKeepsTheFirstPositionAndDropsRepeats() {
        Album a; a.id = 900007001; a.title = QStringLiteral("A");
        Album b; b.id = 900007002; b.title = QStringLiteral("B");
        Album bAgain = b;
        Album c; c.id = 900007003; c.title = QStringLiteral("C");

        const QList<Album> merged =
            TidalClient::mergeAlbumLists({{a, b}, {bAgain, c}});
        QCOMPARE(merged.size(), 3);
        QCOMPARE(merged.at(0).id, a.id);
        QCOMPARE(merged.at(1).id, b.id);
        QCOMPARE(merged.at(2).id, c.id);
    }
};

QTEST_GUILESS_MAIN(TestArtistDiscography)
#include "tst_artist_discography.moc"
