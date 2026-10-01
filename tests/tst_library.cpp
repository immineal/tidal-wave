// LibraryIndex: the flat sidebar library and the search over it
// (spec S1 to S7, plus P5 for the pinned entries).
//
// Written before LibraryIndex.cpp. The interesting cases are the ones the live
// API made expensive to reach: paging that has to terminate even when the
// server keeps handing back the same page, and a background tracklist index
// that has to answer searches correctly while it is still half built.
//
// Nothing here touches the network. LibraryIndex keeps every request behind a
// protected virtual, and TestLibrary below overrides all six of them with
// lists the test owns, so a run needs no Tidal session and no event loop
// beyond the zero-timer the indexer yields on.

#include <QTest>
#include <QDir>
#include <QSignalSpy>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>

#include <climits>

#include "api/LibraryIndex.h"
#include "ui/PinStore.h"

using namespace Tidal;

namespace {

Artist mkArtist(qint64 id, const QString &name) {
    Artist a; a.id = id; a.name = name; a.picture = QStringLiteral("pic-%1").arg(id);
    return a;
}

Album mkAlbum(qint64 id, const QString &title, const QList<Artist> &artists, int numTracks = 2) {
    Album a; a.id = id; a.title = title; a.artists = artists;
    a.numTracks = numTracks; a.cover = QStringLiteral("cov-%1").arg(id);
    return a;
}

Playlist mkPlaylist(const QString &uuid, const QString &title, int numTracks = 10) {
    Playlist p; p.uuid = uuid; p.title = title; p.numTracks = numTracks;
    p.image = QStringLiteral("img-%1").arg(uuid);
    return p;
}

Mix mkMix(const QString &id, const QString &title) {
    Mix m; m.id = id; m.title = title; m.subTitle = QStringLiteral("mix sub");
    return m;
}

Track mkTrack(qint64 id, const QString &title, const Album &album, const QList<Artist> &artists) {
    Track t; t.id = id; t.title = title; t.album = album; t.artists = artists;
    return t;
}

QStringList keysOf(const QVariantList &rows) {
    QStringList out;
    for (const QVariant &v : rows) {
        const QVariantMap m = v.toMap();
        out << m.value(QStringLiteral("kind")).toString() + QLatin1Char(':')
               + m.value(QStringLiteral("id")).toString();
    }
    return out;
}

QStringList titlesOf(const QVariantList &rows) {
    QStringList out;
    for (const QVariant &v : rows) out << v.toMap().value(QStringLiteral("title")).toString();
    return out;
}

int indexOfKey(const QVariantList &rows, const QString &key) {
    return keysOf(rows).indexOf(key);
}

QVariantMap rowFor(const QVariantList &rows, const QString &key) {
    for (const QVariant &v : rows) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("kind")).toString() + QLatin1Char(':')
                + m.value(QStringLiteral("id")).toString() == key)
            return m;
    }
    return {};
}

// A LibraryIndex with the network replaced by lists the test fills in.
class TestLibrary : public LibraryIndex {
public:
    explicit TestLibrary(PinStore *pins) : LibraryIndex(nullptr, pins, nullptr) {}

    QList<Playlist> playlists;
    QList<Album>    albums;
    QList<Artist>   artists;
    QList<Track>    favoriteTracks;
    QList<Mix>      mixes;
    QHash<qint64, QList<Track>> albumTracks;

    // Pretend the API never advances: every page comes back as the first one.
    // That is the shape that would spin forever without a guard.
    bool repeatFirstPage = false;
    // Hold tracklist replies so a test can decide how much of the background
    // index has finished by the time it searches.
    bool deferTracklists = false;

    int playlistRequests  = 0;
    int albumRequests     = 0;
    int tracklistRequests = 0;

    int parkedTracklists() const { return m_parked.size(); }

    // Releases the oldest held tracklist reply. The indexer yields through a
    // zero timer between albums, so callers pump the loop afterwards.
    void deliverOneTracklist() {
        if (m_parked.isEmpty()) return;
        const Parked p = m_parked.takeFirst();
        p.cb(albumTracks.value(p.albumId), QString());
    }

    void deliverAllTracklists() {
        while (!m_parked.isEmpty()) {
            deliverOneTracklist();
            QTest::qWait(1);
        }
    }

protected:
    void fetchPlaylistPage(int offset, int limit, PlaylistsCb cb) override {
        ++playlistRequests;
        cb(slice(playlists, offset, limit), QString());
    }
    void fetchAlbumPage(int offset, int limit, AlbumsCb cb) override {
        ++albumRequests;
        cb(slice(albums, offset, limit), QString());
    }
    void fetchArtistPage(int offset, int limit, ArtistsCb cb) override {
        cb(slice(artists, offset, limit), QString());
    }
    void fetchTrackPage(int offset, int limit, TracksCb cb) override {
        cb(slice(favoriteTracks, offset, limit), QString());
    }
    void fetchMixList(MixesCb cb) override {
        cb(mixes, QString());
    }
    void fetchAlbumTracklist(qint64 albumId, TracksCb cb) override {
        ++tracklistRequests;
        if (deferTracklists) { m_parked.append({albumId, cb}); return; }
        cb(albumTracks.value(albumId), QString());
    }

private:
    template <typename T>
    QList<T> slice(const QList<T> &all, int offset, int limit) const {
        if (repeatFirstPage) return all.mid(0, limit);
        return all.mid(offset, limit);
    }

    struct Parked { qint64 albumId; TracksCb cb; };
    QList<Parked> m_parked;
};

} // namespace

class TestLibraryIndex : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_library"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

        // LibraryIndex also caches album tracklists under AppDataLocation, so
        // the platform data roots have to move into the temporary directory
        // too. A test run must not read or overwrite the real install's cache.
        qputenv("HOME",         m_dir.path().toUtf8());
        qputenv("XDG_DATA_HOME", (m_dir.path() + QStringLiteral("/share")).toUtf8());
        qputenv("XDG_CACHE_HOME", (m_dir.path() + QStringLiteral("/cache")).toUtf8());
        qputenv("APPDATA",      m_dir.path().toUtf8());        // Windows
        qputenv("LOCALAPPDATA", m_dir.path().toUtf8());
        QVERIFY2(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                     .startsWith(m_dir.path()),
                 "the tracklist cache would land outside the temporary directory");

        // A-Z ordering goes through QCollator, which follows the default
        // locale. Pin it so the expectations below mean the same thing on
        // every machine.
        QLocale::setDefault(QLocale(QLocale::German, QLocale::Germany));
    }

    void init() {
        QSettings().clear();
        QSettings().sync();
        QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)).removeRecursively();
    }

    // ── ordering: pinned, then recently played, then A to Z (S2) ─────────

    void threeTierOrdering() {
        PinStore pins;
        pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"),  QStringLiteral("12"), QStringLiteral("The Wall"), QString(), QString());
        pins.pin(QStringLiteral("artist"), QStringLiteral("20"), QStringLiteral("Adele"),    QString(), QString());

        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        // Two plays, oldest first, so the newest has to end up on top.
        lib.markPlayed(QStringLiteral("playlist"), QStringLiteral("p-zebra"));
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("10"));

        QCOMPARE(keysOf(lib.entries()), QStringList({
            QStringLiteral("album:12"),      // pinned, first in the pin order
            QStringLiteral("artist:20"),     // pinned, second
            QStringLiteral("album:10"),      // played most recently
            QStringLiteral("playlist:p-zebra"),
            QStringLiteral("album:11"),      // never played, "Aerzte Live"
            QStringLiteral("artist:21"),     // "Beatles"
            QStringLiteral("mix:m1"),        // "The Cosmos", the article does not count
            QStringLiteral("playlist:p-morning"),
        }));

        // The pinned rows say so, and carry the pin order.
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("album:12")).value(QStringLiteral("pinned")).toBool(), true);
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("album:10")).value(QStringLiteral("pinned")).toBool(), false);
        QVERIFY(rowFor(lib.entries(), QStringLiteral("album:10")).value(QStringLiteral("lastPlayed")).toLongLong() > 0);
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("artist:21")).value(QStringLiteral("lastPlayed")).toLongLong(), 0LL);
    }

    // "Ärzte" belongs with the As, not after Z, and case must not matter.
    // That is QCollator's job, not QString::compare's.
    void alphabeticalOrderIsCollatedNotByteWise() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.artists = {mkArtist(1, QStringLiteral("adele")),
                       mkArtist(2, QStringLiteral("Ärzte")),
                       mkArtist(3, QStringLiteral("Beatles")),
                       mkArtist(4, QStringLiteral("Zero 7")),
                       mkArtist(5, QStringLiteral("Örsted"))};
        lib.setUserId(kUser);
        lib.refresh();
        QCOMPARE(titlesOf(lib.entries()), QStringList({
            QStringLiteral("adele"), QStringLiteral("Ärzte"), QStringLiteral("Beatles"),
            QStringLiteral("Örsted"), QStringLiteral("Zero 7")}));
    }

    // P5: a pinned entry lives in the pinned block and nowhere else.
    void aPinnedEntryAppearsExactlyOnce() {
        PinStore pins;
        pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("12"), QStringLiteral("The Wall"), QString(), QString());

        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("12"));   // pinned and played

        QCOMPARE(keysOf(lib.entries()).count(QStringLiteral("album:12")), 1);
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("album:12"));
        QCOMPARE(lib.entries().size(), 8);
    }

    void pinningRebuildsTheListImmediately() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        pins.pin(QStringLiteral("playlist"), QStringLiteral("p-morning"),
                 QStringLiteral("Morning"), QString(), QString());
        QVERIFY(spy.count() >= 1);
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("playlist:p-morning"));
    }

    // ── paging (S3): the reported "new playlists never show up" bug ──────

    void pagingAssemblesEveryPage() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        for (int i = 0; i < 120; ++i)
            lib.playlists << mkPlaylist(QStringLiteral("p-%1").arg(i, 3, 10, QChar('0')),
                                        QStringLiteral("Playlist %1").arg(i, 3, 10, QChar('0')));
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(lib.entries().size(), 120);
        // 50 + 50 + 20: the short third page is what ends it.
        QCOMPARE(lib.playlistRequests, 3);
        QVERIFY(keysOf(lib.entries()).contains(QStringLiteral("playlist:p-119")));
    }

    // An exact multiple of the page size has no short page, so the run only
    // ends when a request comes back empty.
    void pagingTerminatesOnAnEmptyPage() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        for (int i = 0; i < 2 * LibraryIndex::pageSize; ++i)
            lib.playlists << mkPlaylist(QStringLiteral("p-%1").arg(i), QStringLiteral("P %1").arg(i));
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(lib.entries().size(), 2 * LibraryIndex::pageSize);
        QCOMPARE(lib.playlistRequests, 3);
    }

    // The guard that matters: a server that keeps answering with a full first
    // page must not keep the app asking forever.
    void pagingTerminatesOnARepeatingFullPage() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.repeatFirstPage = true;
        for (int i = 0; i < 400; ++i)
            lib.playlists << mkPlaylist(QStringLiteral("p-%1").arg(i), QStringLiteral("P %1").arg(i));
        lib.setUserId(kUser);
        lib.refresh();

        // One page of real items, one more that added nothing, then stop.
        QCOMPARE(lib.playlistRequests, 2);
        QCOMPARE(lib.entries().size(), LibraryIndex::pageSize);
        QVERIFY(lib.playlistRequests < LibraryIndex::maxPages);
    }

    // ── recently played is local (S4) ────────────────────────────────────

    void markPlayedReordersAndPersists() {
        PinStore pins; pins.setUserId(kUser);
        {
            TestLibrary lib(&pins);
            fillMixedLibrary(lib);
            lib.setUserId(kUser);
            lib.refresh();

            QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
            lib.markPlayed(QStringLiteral("mix"), QStringLiteral("m1"));
            QVERIFY(spy.count() >= 1);
            QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("mix:m1"));

            // All four kinds get a local timestamp, not just playlists.
            lib.markPlayed(QStringLiteral("artist"), QStringLiteral("21"));
            QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("artist:21"));
            QCOMPARE(keysOf(lib.entries()).at(1), QStringLiteral("mix:m1"));

            lib.markPlayed(QStringLiteral("album"), QStringLiteral("10"));
            lib.markPlayed(QStringLiteral("playlist"), QStringLiteral("p-zebra"));
            QCOMPARE(keysOf(lib.entries()).mid(0, 4), QStringList({
                QStringLiteral("playlist:p-zebra"), QStringLiteral("album:10"),
                QStringLiteral("artist:21"), QStringLiteral("mix:m1")}));
        }

        // Still there after a restart.
        TestLibrary again(&pins);
        fillMixedLibrary(again);
        again.setUserId(kUser);
        again.refresh();
        QCOMPARE(keysOf(again.entries()).mid(0, 4), QStringList({
            QStringLiteral("playlist:p-zebra"), QStringLiteral("album:10"),
            QStringLiteral("artist:21"), QStringLiteral("mix:m1")}));
    }

    void markPlayedIgnoresNonsense() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        const QStringList before = keysOf(lib.entries());

        lib.markPlayed(QStringLiteral("podcast"), QStringLiteral("1"));
        lib.markPlayed(QStringLiteral("album"), QString());
        lib.markPlayed(QString(), QString());
        QCOMPARE(keysOf(lib.entries()), before);
    }

    void playHistoryIsPerAccount() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary first(&pins);
        fillMixedLibrary(first);
        first.setUserId(kUser);
        first.refresh();
        first.markPlayed(QStringLiteral("mix"), QStringLiteral("m1"));
        QCOMPARE(keysOf(first.entries()).first(), QStringLiteral("mix:m1"));

        TestLibrary second(&pins);
        fillMixedLibrary(second);
        second.setUserId(kOtherUser);
        second.refresh();
        QVERIFY(keysOf(second.entries()).first() != QStringLiteral("mix:m1"));
    }

    // ── search (S5 to S7) ────────────────────────────────────────────────

    void searchIgnoresCaseAndAccents() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        for (const QString &q : {QStringLiteral("björk"), QStringLiteral("Bjork"),
                                 QStringLiteral("BJÖRK"), QStringLiteral("bjork")}) {
            const QVariantList hits = lib.search(q, {});
            QVERIFY2(indexOfKey(hits, QStringLiteral("artist:20")) >= 0, qPrintable(q));
        }

        // ...and the same for a song title.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("joga"), {}), QStringLiteral("track:500")) >= 0);
        QVERIFY(indexOfKey(lib.search(QStringLiteral("JÓGA"), {}), QStringLiteral("track:500")) >= 0);

        // A query matching nothing comes back empty rather than matching all.
        QVERIFY(lib.search(QStringLiteral("zzzzz"), {}).isEmpty());
        // An empty query is the plain library, which the sidebar already shows.
        QVERIFY(lib.search(QString(), {}).isEmpty());
        QVERIFY(lib.search(QStringLiteral("   "), {}).isEmpty());
    }

    void searchRanksPrefixAboveWordStartAboveMidWord() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QVariantList hits = lib.search(QStringLiteral("love"), {});
        const int lovely  = indexOfKey(hits, QStringLiteral("album:102"));    // "Lovely Days"
        const int supreme = indexOfKey(hits, QStringLiteral("track:505"));    // "Love Supreme"
        const int endless = indexOfKey(hits, QStringLiteral("track:502"));    // "Endless Love"
        const int clover  = indexOfKey(hits, QStringLiteral("album:103"));    // "Clover Field"
        QVERIFY(lovely >= 0 && supreme >= 0 && endless >= 0 && clover >= 0);

        QVERIFY2(lovely < endless,  "a prefix match must outrank a word-start match");
        QVERIFY2(supreme < endless, "a prefix match must outrank a word-start match");
        QVERIFY2(endless < clover,  "a word-start match must outrank a mid-word match");

        // Scores come back with the rows and never increase down the list.
        int previous = INT_MAX;
        for (const QVariant &v : hits) {
            const int s = v.toMap().value(QStringLiteral("score")).toInt();
            QVERIFY(s <= previous);
            previous = s;
        }
    }

    void searchFiltersByKind() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QVariantList all = lib.search(QStringLiteral("love"), {});
        QVERIFY(all.size() > 2);

        const QVariantList albumsOnly = lib.search(QStringLiteral("love"), {QStringLiteral("album")});
        QVERIFY(!albumsOnly.isEmpty());
        for (const QVariant &v : albumsOnly)
            QCOMPARE(v.toMap().value(QStringLiteral("kind")).toString(), QStringLiteral("album"));

        const QVariantList songsOnly = lib.search(QStringLiteral("love"), {QStringLiteral("track")});
        QVERIFY(!songsOnly.isEmpty());
        for (const QVariant &v : songsOnly)
            QCOMPARE(v.toMap().value(QStringLiteral("kind")).toString(), QStringLiteral("track"));

        // Two kinds at once, and a kind nobody matches.
        const QVariantList two = lib.search(QStringLiteral("love"),
                                            {QStringLiteral("album"), QStringLiteral("playlist")});
        QVERIFY(indexOfKey(two, QStringLiteral("album:102")) >= 0);
        QVERIFY(indexOfKey(two, QStringLiteral("playlist:p-love")) >= 0);
        QVERIFY(indexOfKey(two, QStringLiteral("track:505")) < 0);
        QVERIFY(lib.search(QStringLiteral("love"), {QStringLiteral("mix")}).isEmpty());
        QVERIFY(lib.search(QStringLiteral("love"), {QStringLiteral("podcast")}).isEmpty());
    }

    // S7: an artist hit drags in that artist's saved albums and saved songs.
    void anArtistMatchExpandsToItsAlbumsAndSongs() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QVariantList hits = lib.search(QStringLiteral("portishead"), {});
        QCOMPARE(keysOf(hits).first(), QStringLiteral("artist:21"));

        for (const QString &key : {QStringLiteral("album:101"),      // "Dummy"
                                   QStringLiteral("track:501"),      // liked song
                                   QStringLiteral("track:504")}) {   // only in the album index
            const QVariantMap row = rowFor(hits, key);
            QVERIFY2(!row.isEmpty(), qPrintable(key));
            QVERIFY2(row.value(QStringLiteral("expanded")).toBool(), qPrintable(key));
            QCOMPARE(row.value(QStringLiteral("expandedFrom")).toString(), QStringLiteral("artist:21"));
        }

        // Another artist's work stays out of it.
        QVERIFY(indexOfKey(hits, QStringLiteral("album:100")) < 0);
        QVERIFY(indexOfKey(hits, QStringLiteral("track:500")) < 0);

        // The artist itself is a direct hit, not an expansion.
        QCOMPARE(rowFor(hits, QStringLiteral("artist:21")).value(QStringLiteral("expanded")).toBool(), false);
    }

    // S7, the other direction: a song hit drags in the album holding it.
    void aSongMatchExpandsToItsAlbum() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QVariantList hits = lib.search(QStringLiteral("bachelorette"), {});
        QCOMPARE(keysOf(hits).first(), QStringLiteral("track:503"));
        const QVariantMap album = rowFor(hits, QStringLiteral("album:100"));
        QVERIFY(!album.isEmpty());
        QVERIFY(album.value(QStringLiteral("expanded")).toBool());
        QCOMPARE(album.value(QStringLiteral("expandedFrom")).toString(), QStringLiteral("track:503"));
    }

    void expandedResultsNeverDisplaceADirectHit() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        // "Glory Box" is a prefix hit, "Morning Glory" only a word-start hit,
        // and "Dummy" matches the query not at all: it is here because the
        // song that matched sits on it. It has to come last even so.
        const QVariantList hits = lib.search(QStringLiteral("glory"), {});
        const int box     = indexOfKey(hits, QStringLiteral("track:501"));
        const int morning = indexOfKey(hits, QStringLiteral("playlist:p-glory"));
        const int dummy   = indexOfKey(hits, QStringLiteral("album:101"));
        QVERIFY(box >= 0 && morning >= 0 && dummy >= 0);
        QVERIFY(box < morning);
        QVERIFY2(morning < dummy, "an expansion must rank below every direct hit");

        // Every direct hit precedes every expansion, not just this pair.
        bool seenExpanded = false;
        for (const QVariant &v : hits) {
            const bool expanded = v.toMap().value(QStringLiteral("expanded")).toBool();
            if (expanded) seenExpanded = true;
            else QVERIFY2(!seenExpanded, "a direct hit turned up after an expanded one");
        }

        // An entry that is both a direct hit and an expansion is listed once,
        // as the direct hit.
        QCOMPARE(keysOf(hits).count(QStringLiteral("album:101")), 1);
    }

    // ── the lazy album tracklist index (S6) ──────────────────────────────

    void searchingDuringIncompleteIndexingWorks() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.deferTracklists = true;
        lib.setUserId(kUser);
        lib.refresh();

        QVERIFY(lib.indexing());
        QCOMPARE(lib.indexedAlbumCount(), 0);

        // Liked songs are cached already, so they answer before any album is
        // indexed. "Roads" exists only inside album 101's tracklist.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("glory box"), {}), QStringLiteral("track:501")) >= 0);
        QVERIFY(lib.search(QStringLiteral("roads"), {}).isEmpty());
        QVERIFY(lib.search(QStringLiteral("bachelorette"), {}).isEmpty());

        // One album lands. Its tracks are searchable; the rest still are not.
        lib.deliverOneTracklist();
        QTest::qWait(1);
        QCOMPARE(lib.indexedAlbumCount(), 1);
        QVERIFY(indexOfKey(lib.search(QStringLiteral("bachelorette"), {}), QStringLiteral("track:503")) >= 0);
        QVERIFY(lib.search(QStringLiteral("roads"), {}).isEmpty());
        // ...and an artist expansion only offers what is indexed so far.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("portishead"), {}), QStringLiteral("track:504")) < 0);
        QVERIFY(indexOfKey(lib.search(QStringLiteral("portishead"), {}), QStringLiteral("track:501")) >= 0);

        lib.deliverAllTracklists();
        QTRY_VERIFY(!lib.indexing());
        QCOMPARE(lib.indexedAlbumCount(), lib.albums.size());
        QVERIFY(indexOfKey(lib.search(QStringLiteral("roads"), {}), QStringLiteral("track:504")) >= 0);
    }

    void cancellingTheIndexStopsItAndKeepsWhatIsDone() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.deferTracklists = true;
        lib.setUserId(kUser);
        lib.refresh();

        lib.deliverOneTracklist();
        QTest::qWait(1);
        const int requestsBefore = lib.tracklistRequests;
        QCOMPARE(lib.indexedAlbumCount(), 1);

        lib.cancelIndexing();
        QVERIFY(!lib.indexing());

        // A reply that was already in flight when the cancel landed is
        // harmless, and nothing new is asked for.
        lib.deliverOneTracklist();
        QTest::qWait(5);
        QCOMPARE(lib.tracklistRequests, requestsBefore);
        QVERIFY(!lib.indexing());

        // What was indexed before the cancel is still searchable.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("bachelorette"), {}), QStringLiteral("track:503")) >= 0);
    }

    // The point of the disk cache: a second launch does not re-fetch every
    // saved album's tracklist.
    void theTracklistCacheSurvivesARestart() {
        PinStore pins; pins.setUserId(kUser);
        {
            TestLibrary lib(&pins);
            fillSearchLibrary(lib);
            lib.setUserId(kUser);
            lib.refresh();
            waitForIndex(lib);
            QCOMPARE(lib.indexedAlbumCount(), lib.albums.size());
        }

        TestLibrary again(&pins);
        fillSearchLibrary(again);
        again.setUserId(kUser);
        again.refresh();
        waitForIndex(again);
        QCOMPARE(again.tracklistRequests, 0);
        QVERIFY(indexOfKey(again.search(QStringLiteral("roads"), {}), QStringLiteral("track:504")) >= 0);

        // A different account does not get to read it.
        TestLibrary other(&pins);
        fillSearchLibrary(other);
        other.setUserId(kOtherUser);
        other.refresh();
        QVERIFY(other.tracklistRequests > 0);
    }

    // An album whose track count changed is stale and gets indexed again;
    // the others are left alone.
    void aChangedAlbumIsReindexed() {
        PinStore pins; pins.setUserId(kUser);
        {
            TestLibrary lib(&pins);
            fillSearchLibrary(lib);
            lib.setUserId(kUser);
            lib.refresh();
            waitForIndex(lib);
        }

        TestLibrary again(&pins);
        fillSearchLibrary(again);
        for (Album &a : again.albums)
            if (a.id == 101) a.numTracks = 3;
        again.albumTracks[101] << mkTrack(507, QStringLiteral("Mysterons"),
                                          again.albums.at(1), {mkArtist(21, QStringLiteral("Portishead"))});
        again.setUserId(kUser);
        again.refresh();
        waitForIndex(again);

        QCOMPARE(again.tracklistRequests, 1);
        QVERIFY(indexOfKey(again.search(QStringLiteral("mysterons"), {}), QStringLiteral("track:507")) >= 0);
    }

    // ── nothing at all ───────────────────────────────────────────────────

    void anEmptyLibrarySearchesCleanly() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.setUserId(kUser);

        // Before any fetch at all.
        QVERIFY(lib.entries().isEmpty());
        QVERIFY(lib.search(QStringLiteral("anything"), {}).isEmpty());
        QVERIFY(lib.search(QString(), {QStringLiteral("album")}).isEmpty());

        lib.refresh();
        QVERIFY(!lib.loading());
        QVERIFY(!lib.indexing());
        QVERIFY(lib.entries().isEmpty());
        QCOMPARE(lib.indexedAlbumCount(), 0);
        QVERIFY(lib.search(QStringLiteral("anything"), {}).isEmpty());
        QVERIFY(lib.search(QStringLiteral("a"), {QStringLiteral("track")}).isEmpty());

        // Marking a play on something that is not there must not invent a row.
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("999"));
        QVERIFY(lib.entries().isEmpty());
    }

    void loadingIsAnnouncedAroundARefresh() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        QVERIFY(!lib.loading());
        QSignalSpy spy(&lib, &LibraryIndex::loadingChanged);
        lib.refresh();
        QCOMPARE(spy.count(), 2);      // on, then off
        QVERIFY(!lib.loading());
    }

private:
    static constexpr qint64 kUser      = 1001;
    static constexpr qint64 kOtherUser = 2002;

    // Playlists, albums, artists and mixes together, which is the whole point
    // of S1: one flat list with a type icon per row.
    static void fillMixedLibrary(TestLibrary &lib) {
        lib.playlists = {mkPlaylist(QStringLiteral("p-zebra"),   QStringLiteral("Zebra Nights")),
                         mkPlaylist(QStringLiteral("p-morning"), QStringLiteral("Morning"))};
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.albums = {mkAlbum(10, QStringLiteral("Blue Train"),  {various}),
                      mkAlbum(11, QStringLiteral("Ärzte Live"),  {various}),
                      mkAlbum(12, QStringLiteral("The Wall"),    {various})};
        lib.artists = {mkArtist(20, QStringLiteral("Adele")),
                       mkArtist(21, QStringLiteral("Beatles"))};
        lib.mixes = {mkMix(QStringLiteral("m1"), QStringLiteral("The Cosmos"))};
    }

    static void fillSearchLibrary(TestLibrary &lib) {
        const Artist bjork   = mkArtist(20, QStringLiteral("Björk"));
        const Artist porti   = mkArtist(21, QStringLiteral("Portishead"));
        const Artist various = mkArtist(99, QStringLiteral("Various"));

        const Album homogenic = mkAlbum(100, QStringLiteral("Homogenic"),   {bjork});
        const Album dummy     = mkAlbum(101, QStringLiteral("Dummy"),       {porti});
        const Album lovely    = mkAlbum(102, QStringLiteral("Lovely Days"), {various});
        const Album clover    = mkAlbum(103, QStringLiteral("Clover Field"), {various}, 1);

        lib.artists = {bjork, porti};
        lib.albums  = {homogenic, dummy, lovely, clover};
        lib.playlists = {mkPlaylist(QStringLiteral("p-love"),  QStringLiteral("Love Letters")),
                         mkPlaylist(QStringLiteral("p-glory"), QStringLiteral("Morning Glory"))};
        lib.mixes = {mkMix(QStringLiteral("m9"), QStringLiteral("Daily Discovery"))};

        // Liked songs: cached already, so instant.
        lib.favoriteTracks = {mkTrack(500, QStringLiteral("Jóga"),        homogenic, {bjork}),
                              mkTrack(501, QStringLiteral("Glory Box"),   dummy,     {porti}),
                              mkTrack(502, QStringLiteral("Endless Love"), lovely,   {various})};

        // Saved album tracklists: these are what the background index pulls in.
        lib.albumTracks[100] = {mkTrack(500, QStringLiteral("Jóga"),         homogenic, {bjork}),
                                mkTrack(503, QStringLiteral("Bachelorette"), homogenic, {bjork})};
        lib.albumTracks[101] = {mkTrack(501, QStringLiteral("Glory Box"),    dummy, {porti}),
                                mkTrack(504, QStringLiteral("Roads"),        dummy, {porti})};
        lib.albumTracks[102] = {mkTrack(502, QStringLiteral("Endless Love"), lovely, {various}),
                                mkTrack(505, QStringLiteral("Love Supreme"), lovely, {various})};
        lib.albumTracks[103] = {mkTrack(506, QStringLiteral("Clover Song"),  clover, {various})};
    }

    static void waitForIndex(TestLibrary &lib) {
        QTRY_VERIFY_WITH_TIMEOUT(!lib.indexing(), 5000);
    }

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestLibraryIndex)
#include "tst_library.moc"
