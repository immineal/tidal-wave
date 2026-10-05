// LibraryIndex: the flat sidebar library and the search over it
// (spec S1 to S6, plus P5 for the pinned entries). S7, result expansion, was
// withdrawn by the user; the case below named for it is the one that keeps it
// from coming back.
//
// The ordering S2 described - pinned, then recently played, then A-Z - is gone
// too. The A-Z tier put an album the user had just saved at alphabetical
// position 589 of 971, which they could not tell from its not being saved, so
// there is now one list under the pinned block, ordered by the most recent of
// (last played, date added). The cases under "one list, newest first" below are
// that rule; the fixtures that carry no dates at all still come out A-Z, because
// collation is the tie-break.
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
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>

#include <climits>

#include "api/LibraryIndex.h"
#include "ui/PinStore.h"

using namespace Tidal;

namespace {

// `addedAt` defaults to 0 - "no date on the response" - which is what most of
// these fixtures want: with no dates anywhere, the ordering falls through to the
// collation tie-break and the expectations stay readable. The cases that are
// about the date pass one in.
Artist mkArtist(qint64 id, const QString &name, qint64 addedAt = 0) {
    Artist a; a.id = id; a.name = name; a.picture = QStringLiteral("pic-%1").arg(id);
    a.addedAt = addedAt;
    return a;
}

Album mkAlbum(qint64 id, const QString &title, const QList<Artist> &artists, int numTracks = 2,
              qint64 addedAt = 0) {
    Album a; a.id = id; a.title = title; a.artists = artists;
    a.numTracks = numTracks; a.cover = QStringLiteral("cov-%1").arg(id);
    a.addedAt = addedAt;
    return a;
}

Playlist mkPlaylist(const QString &uuid, const QString &title, int numTracks = 10,
                    qint64 addedAt = 0) {
    Playlist p; p.uuid = uuid; p.title = title; p.numTracks = numTracks;
    p.image = QStringLiteral("img-%1").arg(uuid);
    p.addedAt = addedAt;
    return p;
}

// A fixed instant to hang the date cases off, so nothing depends on the clock.
constexpr qint64 kDay = 24LL * 60 * 60 * 1000;
constexpr qint64 kJan2026 = 1767225600000LL;   // 2026-01-01T00:00:00Z
qint64 daysAfterJan(int days) { return kJan2026 + days * kDay; }

Mix mkMix(const QString &id, const QString &title, qint64 addedAt = 0) {
    Mix m; m.id = id; m.title = title; m.subTitle = QStringLiteral("mix sub");
    m.addedAt = addedAt;
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

// What LibraryIndex has actually written down for this account, so a test can
// say "and nothing was stored" as well as "and the order changed".
QVariantMap storedRecents(qint64 uid) {
    QSettings settings;
    const QJsonDocument doc = QJsonDocument::fromJson(
        settings.value(QStringLiteral("user_%1/library/lastPlayed").arg(uid)).toString().toUtf8());
    return doc.object().toVariantMap();
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
        // that has to move somewhere disposable: a test run must not read or
        // overwrite the real install's cache.
        //
        // This was done by pointing HOME, XDG_DATA_HOME, XDG_CACHE_HOME and the
        // two Windows variables at the temporary directory, which only ever
        // worked on Linux. On the first macOS run it aborted this whole binary in
        // initTestCase: QStandardPaths there does not read XDG_DATA_HOME at all,
        // AppDataLocation stayed in the real ~/Library/Application Support, and
        // the assertion below failed before a single test ran.
        //
        // setTestModeEnabled() is the mechanism Qt provides for exactly this and
        // it is honoured on every platform. It roots the standard locations at
        // QDir::homePath() + "/.qttest", which is why HOME is still set: on both
        // Linux and macOS that is what QDir::homePath() reads, so it is what
        // keeps the cache inside the temporary directory instead of in the
        // developer's home. The XDG_* and Windows variables are gone rather than
        // kept alongside, because test mode ignores them and leaving them here
        // would go on suggesting they were the thing doing the isolating.
        QStandardPaths::setTestModeEnabled(true);
        qputenv("HOME", m_dir.path().toUtf8());
        const QString appData =
            QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY2(appData.contains(QLatin1String("qttest")),
                 qPrintable(QStringLiteral("standard paths are not in test mode: %1")
                                .arg(appData)));
#if defined(Q_OS_UNIX)
        // Wherever HOME governs QDir::homePath(), which is Linux and macOS both,
        // the cache is inside the temporary directory and is thrown away with it.
        QVERIFY2(appData.startsWith(m_dir.path()),
                 qPrintable(QStringLiteral("the tracklist cache would land outside %1: %2")
                                .arg(m_dir.path(), appData)));
#endif

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

    // ── one list, newest first, under the pinned block ───────────────────

    // With no dates on the fixture at all, the list is the play times and then
    // the collation tie-break - which is the old three-tier output, and is here
    // to show that taking the A-Z tier out did not disturb it.
    void pinnedThenPlayedThenTheRest() {
        PinStore pins;
        pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"),  QStringLiteral("12"), QStringLiteral("The Wall"), QString(), QString());
        pins.pin(QStringLiteral("artist"), QStringLiteral("20"), QStringLiteral("Alder Vane"),    QString(), QString());

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
        lib.artists = {mkArtist(1, QStringLiteral("alder vane")),
                       mkArtist(2, QStringLiteral("Ärzte")),
                       mkArtist(3, QStringLiteral("Beatles")),
                       mkArtist(4, QStringLiteral("Zero 7")),
                       mkArtist(5, QStringLiteral("Örsted"))};
        lib.setUserId(kUser);
        lib.refresh();
        QCOMPARE(titlesOf(lib.entries()), QStringList({
            QStringLiteral("alder vane"), QStringLiteral("Ärzte"), QStringLiteral("Beatles"),
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

    // ── search (S5, S6) ────────────────────────────────────────────────

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

    void whereTheQueryLandsInTheTitleDecidesMostOfTheOrder() {
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

    // S7 is withdrawn. The user saw the greyed, indented rows it produced,
    // asked what they were, and said to drop the whole idea: a result is now
    // only ever something whose own title was typed.
    void searchingAnArtistNoLongerDragsInTheirAlbumsAndSongs() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        // Portishead the artist, and nothing else. "Dummy", "Glory Box" and
        // "Roads" are all theirs and all saved, and none of them is a match
        // for what was typed.
        const QStringList artistHit = keysOf(lib.search(QStringLiteral("portishead"), {}));
        QCOMPARE(artistHit, QStringList{QStringLiteral("artist:21")});

        // And the other direction: a song no longer brings its album along.
        const QStringList songHit = keysOf(lib.search(QStringLiteral("bachelorette"), {}));
        QCOMPARE(songHit, QStringList{QStringLiteral("track:503")});

        // No row carries the flags the expansion used to set.
        for (const QVariant &v : lib.search(QStringLiteral("glory"), {})) {
            const QVariantMap row = v.toMap();
            QVERIFY(!row.contains(QStringLiteral("expanded")));
            QVERIFY(!row.contains(QStringLiteral("expandedFrom")));
        }
    }

    // ── what "most relevant" means (S5) ──────────────────────────────────

    // Type a name that is an artist, one of their albums, a playlist about
    // them and a song on that album, and the artist is what was meant.
    void typingANameThatIsAnArtistPutsTheArtistFirst() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillRankingLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QStringList hits = keysOf(lib.search(QStringLiteral("moderat"), {}));
        QCOMPARE(hits, (QStringList{QStringLiteral("artist:40"),      // Moderat
                                    QStringLiteral("album:300"),      // "Moderat"
                                    QStringLiteral("playlist:p-mod"), // "Moderat Mixtape"
                                    QStringLiteral("track:701")}));   // "Moderat Intro"
    }

    // "Sun" is certainly what was meant. "Sun King" probably. "Sunflower
    // Reverie" gives three of its seventeen characters to the query, which is
    // the weakest claim of the three, so it comes last.
    void aShortTitleMatchedInFullBeatsALongOneThatMerelyStartsWithIt() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillRankingLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QStringList hits = titlesOf(lib.search(QStringLiteral("sun"),
                                                     {QStringLiteral("album")}));
        QCOMPARE(hits, (QStringList{QStringLiteral("Sun"),
                                    QStringLiteral("Sun King"),
                                    QStringLiteral("Sunflower Reverie")}));
    }

    // Three albums whose titles are the same length and begin with the same
    // word, so nothing but the user's own history can separate them. The
    // sidebar list is ordered pinned, then recently played, then the rest
    // (S2); the search agrees with it.
    void amongEquallyGoodMatchesThePinnedAndRecentlyPlayedComeFirst() {
        PinStore pins; pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("310"),
                 QStringLiteral("Blue Grass"), QString(), QString());
        pins.pin(QStringLiteral("album"), QStringLiteral("313"),
                 QStringLiteral("Deep Blue"), QString(), QString());
        TestLibrary lib(&pins);
        fillRankingLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("311"));   // Blue Train

        const QStringList hits = titlesOf(lib.search(QStringLiteral("blue"),
                                                     {QStringLiteral("album")}));
        QCOMPARE(hits.mid(0, 3), (QStringList{QStringLiteral("Blue Grass"),
                                              QStringLiteral("Blue Train"),
                                              QStringLiteral("Blue Horse")}));

        // ...but only among equals. "Deep Blue" is pinned too and still comes
        // last, because the query is not where its title starts. Pinning
        // breaks ties; it does not override what was typed.
        QCOMPARE(hits.last(), QStringLiteral("Deep Blue"));
    }

    // A song the user liked is a song they chose. A song the background
    // indexer found on a saved album is one they have possibly never heard.
    void aLikedSongBeatsOneMerelyFoundOnASavedAlbum() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillRankingLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QStringList hits = titlesOf(lib.search(QStringLiteral("ocean"),
                                                     {QStringLiteral("track")}));
        QCOMPARE(hits, (QStringList{QStringLiteral("Ocean Choir"),    // liked
                                    QStringLiteral("Ocean Drive")})); // only indexed
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

    // PlaylistPage decides whether a playlist is editable from its Tidal
    // type, and the sidebar row is where it reads that: without it the page
    // had to guess from the bridge's cache and fell back to read-only.
    void playlistRowsCarryTheirType() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        Playlist mine = mkPlaylist(QStringLiteral("p-mine"), QStringLiteral("Mine"));
        mine.type = QStringLiteral("USER");
        Playlist theirs = mkPlaylist(QStringLiteral("p-theirs"), QStringLiteral("Theirs"));
        theirs.type = QStringLiteral("EDITORIAL");
        lib.playlists = {mine, theirs};
        lib.albums = {mkAlbum(10, QStringLiteral("Blue Train"), {mkArtist(99, QStringLiteral("Various"))})};
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-mine"))
                     .value(QStringLiteral("type")).toString(), QStringLiteral("USER"));
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-theirs"))
                     .value(QStringLiteral("type")).toString(), QStringLiteral("EDITORIAL"));
        // Only playlists have one; nothing else should grow a stray key.
        QVERIFY(!rowFor(lib.entries(), QStringLiteral("album:10"))
                     .contains(QStringLiteral("type")));
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

    // ── liking something has to reach the sidebar at once ────────────────
    //
    // The 0.4.0 bug, in the user's words: "if I go in and like a previously
    // unliked album, it should also appear in my left sidebar, right? because
    // it just didn't for me". TidalBridge and LibraryIndex page the same
    // favourites endpoints into two separate copies, and only the bridge's was
    // being updated on a like - so the album page's Save button flipped to
    // "Saved" while the sidebar went on showing the library it had fetched at
    // sign-in. These pin the sidebar's half of it.

    void savingAnAlbumPutsItInTheSidebarWithoutARefetch() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("album:4242");
        QCOMPARE(indexOfKey(lib.entries(), key), -1);
        const int before = lib.albumRequests;

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.addAlbum(mkAlbum(4242, QStringLiteral("Crystallized"),
                             {mkArtist(98, QStringLiteral("Brakence"))}));

        QVERIFY2(indexOfKey(lib.entries(), key) >= 0,
                 qPrintable(QStringLiteral("the sidebar did not gain album:4242; it holds %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Crystallized"));
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("subtitle")).toString(),
                 QStringLiteral("Brakence"));
        // The sidebar is told, exactly once, and nothing was re-paged for it.
        QCOMPARE(spy.count(), 1);
        QCOMPARE(lib.albumRequests, before);
    }

    void unsavingAnAlbumTakesItOutOfTheSidebarAtOnce() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("album:11");       // "Ärzte Live"
        QVERIFY(indexOfKey(lib.entries(), key) >= 0);
        const int was = lib.entries().size();

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("11"));

        QVERIFY2(indexOfKey(lib.entries(), key) < 0,
                 qPrintable(QStringLiteral("album:11 is still in the sidebar: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QCOMPARE(lib.entries().size(), was - 1);
        QCOMPARE(spy.count(), 1);
    }

    // ── a saved mix, which is how a track radio reaches the sidebar ─────
    //
    // The owner's complaint, at the sidebar: "I liked the hell of a time track
    // radio and it is displayed in my sidebar as a mix ... but it doesn't have a
    // way to unsave it". The row could arrive - fetchHomeMixes merges
    // v2/favorites/mixes in - and nothing in the app could ever take it back out
    // again, because removeEntry had no mix branch at all.
    //
    // The id is a string and not a number, which is the trap this case exists
    // for: the album and artist branches call toLongLong(), and a mix id put
    // through that is 0 for every mix, so one copy of that branch would delete
    // the wrong row or none.
    void savingAndUnsavingAMixMoveTheSidebar() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        // Invented, at a real mix id's shape: 30 lowercase hex characters.
        const QString mixId = QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8");
        const QString key   = QStringLiteral("mix:") + mixId;
        QCOMPARE(indexOfKey(lib.entries(), key), -1);
        const int before = lib.albumRequests;

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.addMix(mkMix(mixId, QStringLiteral("Weit hinter dem Horizont")));

        QVERIFY2(indexOfKey(lib.entries(), key) >= 0,
                 qPrintable(QStringLiteral("the sidebar did not gain %1; it holds %2")
                                .arg(key, keysOf(lib.entries()).join(QLatin1String(", ")))));
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Weit hinter dem Horizont"));
        QCOMPARE(spy.count(), 1);
        QCOMPARE(lib.albumRequests, before);   // nothing was re-paged for it

        lib.removeEntry(QStringLiteral("mix"), mixId);
        QVERIFY2(indexOfKey(lib.entries(), key) < 0,
                 qPrintable(QStringLiteral("%1 is still in the sidebar: %2")
                                .arg(key, keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // Unsaving one mix must take out that mix. With a numeric id the two would
    // both fold to 0 and the first row in the list would go instead.
    void unsavingOneMixLeavesTheOtherAlone() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.mixes = {mkMix(QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8"),
                           QStringLiteral("Erstes Radio")),
                     mkMix(QStringLiteral("ffeeddccbbaa99887766554433221100"),
                           QStringLiteral("Zweites Radio"))};
        lib.setUserId(kUser);
        lib.refresh();

        lib.removeEntry(QStringLiteral("mix"),
                        QStringLiteral("ffeeddccbbaa99887766554433221100"));

        QCOMPARE(keysOf(lib.entries()),
                 QStringList{QStringLiteral("mix:0a1b2c3d4e5f60718293a4b5c6d7e8")});
    }

    // A mix already in the list is not added twice - the user may save one that
    // the merged list already carried.
    void savingAMixAlreadyListedAddsNoSecondRow() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        const int was = lib.entries().size();

        lib.addMix(mkMix(QStringLiteral("m1"), QStringLiteral("The Cosmos")));

        QCOMPARE(lib.entries().size(), was);
        QCOMPARE(keysOf(lib.entries()).count(QStringLiteral("mix:m1")), 1);
    }

    // The sidebar row carries the mix's type, so MixPage can head a saved track
    // radio "Radio" from the first frame instead of flipping from "Mix" when its
    // own request lands. This is the exact route the complaint came in on.
    void aSidebarMixRowSaysWhichKindOfMixItIs() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        Mix radio = mkMix(QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8"),
                          QStringLiteral("Weit hinter dem Horizont"));
        radio.mixType = QStringLiteral("TRACK_MIX");
        lib.mixes = {radio};
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(rowFor(lib.entries(),
                        QStringLiteral("mix:0a1b2c3d4e5f60718293a4b5c6d7e8"))
                     .value(QStringLiteral("mixType")).toString(),
                 QStringLiteral("TRACK_MIX"));
    }

    // Following an artist is the same gap wearing a different hat, and so is
    // unfollowing: a stale row left behind is as wrong as a missing one.
    void followingAndUnfollowingAnArtistMoveTheSidebar() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("artist:30");
        QCOMPARE(indexOfKey(lib.entries(), key), -1);

        lib.addArtist(mkArtist(30, QStringLiteral("Brakence")));
        QVERIFY2(indexOfKey(lib.entries(), key) >= 0,
                 qPrintable(QStringLiteral("the sidebar did not gain artist:30; it holds %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));

        lib.removeEntry(QStringLiteral("artist"), QStringLiteral("30"));
        QVERIFY2(indexOfKey(lib.entries(), key) < 0,
                 qPrintable(QStringLiteral("artist:30 is still in the sidebar: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // A liked song is generally not a row of the library list, but the finder's
    // Tracks chip and every search read it, so it has to arrive there just the
    // same. The one exception - a song whose album is not saved - is the
    // subject of theSidebarKeepsOnlyTheLikedSongsNothingElseLeadsTo() below.
    void likingASongReachesTheTracksChipAndSearch() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const Album host = mkAlbum(4242, QStringLiteral("Crystallized"),
                                   {mkArtist(98, QStringLiteral("Brakence"))});
        const Track t = mkTrack(777, QStringLiteral("death rolL"), host,
                                {mkArtist(98, QStringLiteral("Brakence"))});
        const QStringList chip{QStringLiteral("track")};
        const QString key = QStringLiteral("track:777");

        QCOMPARE(indexOfKey(lib.entriesForKinds(chip), key), -1);

        lib.addTrack(t);
        QVERIFY2(indexOfKey(lib.entriesForKinds(chip), key) >= 0,
                 qPrintable(QStringLiteral("the Tracks chip did not gain track:777; it holds %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
        QVERIFY(indexOfKey(lib.search(QStringLiteral("death"), {}), key) >= 0);
        // Liking a song off an album that *is* saved adds no row to the library
        // list: the album's own row already leads to it. (Album 10 is "Blue
        // Train", which fillMixedLibrary saves.)
        const Album saved = mkAlbum(10, QStringLiteral("Blue Train"),
                                    {mkArtist(99, QStringLiteral("Various"))});
        lib.addTrack(mkTrack(778, QStringLiteral("Locomotion"), saved,
                             {mkArtist(99, QStringLiteral("Various"))}));
        QVERIFY(indexOfKey(lib.entriesForKinds(chip), QStringLiteral("track:778")) >= 0);
        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:778")) < 0,
                 qPrintable(QStringLiteral("track:778 took a library row although album 10 is saved: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));

        lib.removeEntry(QStringLiteral("track"), QStringLiteral("777"));
        QVERIFY2(indexOfKey(lib.entriesForKinds(chip), key) < 0,
                 qPrintable(QStringLiteral("track:777 is still under the Tracks chip: %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
    }

    // Re-liking something already saved must not double the row, and the
    // sidebar must not be told that nothing happened.
    void savingSomethingAlreadySavedChangesNothing() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const int was = lib.entries().size();
        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);

        lib.addAlbum(mkAlbum(10, QStringLiteral("Blue Train"),
                             {mkArtist(99, QStringLiteral("Various"))}));
        lib.addArtist(mkArtist(20, QStringLiteral("Alder Vane")));
        // Nothing saved under this id, so there is nothing to take out either.
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("9999"));

        QCOMPARE(keysOf(lib.entries()).count(QStringLiteral("album:10")), 1);
        QCOMPARE(keysOf(lib.entries()).count(QStringLiteral("artist:20")), 1);
        QCOMPARE(lib.entries().size(), was);
        QCOMPARE(spy.count(), 0);
    }

    // The bug that produced this whole ordering: the user saved an album and it
    // did not appear. It was saved, and it filed at alphabetical position 589 of
    // 971. A just-saved album is now the first row under the pinned block.
    //
    // "Avalon" is deliberately a title that collates into the middle - between
    // "Ärzte Live" and "Beatles" in German - so an alphabetical placement and a
    // newest-first one cannot agree.
    void aJustSavedAlbumIsTheFirstRowUnderThePins() {
        PinStore pins; pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("12"), QStringLiteral("The Wall"),
                 QString(), QString());

        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        lib.addAlbum(mkAlbum(4242, QStringLiteral("Avalon"),
                             {mkArtist(98, QStringLiteral("Isle Trio"))}));

        const QStringList keys = keysOf(lib.entries());
        QCOMPARE(keys.at(0), QStringLiteral("album:12"));      // the pin keeps its place
        QVERIFY2(keys.at(1) == QStringLiteral("album:4242"),
                 qPrintable(QStringLiteral("the album just saved is not the first row under the "
                                           "pinned block; the list is %1")
                                .arg(keys.join(QLatin1String(", ")))));
        // And it did not land there alphabetically.
        const QStringList titles = titlesOf(lib.entries());
        QVERIFY2(titles.indexOf(QStringLiteral("Avalon")) < titles.indexOf(QStringLiteral("Ärzte Live")),
                 qPrintable(titles.join(QLatin1String(", "))));
    }

    // The date comes from the API on every sign-in, so the order a fresh launch
    // produces is the same one, with nothing played yet.
    void aRefreshOrdersByTheDateTheItemsWereAdded() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        // Titles ascending, dates descending, so A-Z and newest-first disagree
        // on every pair.
        lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),  {various}, 2, daysAfterJan(1)),
                      mkAlbum(2, QStringLiteral("Barrow"), {various}, 2, daysAfterJan(9)),
                      mkAlbum(3, QStringLiteral("Cinder"), {various}, 2, daysAfterJan(5))};
        lib.artists   = {mkArtist(20, QStringLiteral("Dune Choir"), daysAfterJan(7))};
        lib.playlists = {mkPlaylist(QStringLiteral("p-1"), QStringLiteral("Embers"), 10,
                                    daysAfterJan(3))};
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(titlesOf(lib.entries()), QStringList({
            QStringLiteral("Barrow"),      // day 9
            QStringLiteral("Dune Choir"),  // day 7, an artist ranks with the rest
            QStringLiteral("Cinder"),      // day 5
            QStringLiteral("Embers"),      // day 3, and so does a playlist
            QStringLiteral("Anvil")}));    // day 1

        // The row carries both halves of the key it was placed by.
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("album:2"))
                     .value(QStringLiteral("addedAt")).toLongLong(), daysAfterJan(9));
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("album:2"))
                     .value(QStringLiteral("recency")).toLongLong(), daysAfterJan(9));
    }

    // "playing from something and (re)saving it should both just put it at the
    // top with the same priority": one timestamp, and the later of the two wins.
    void playingAndSavingAreOneSignalOnOneTimestamp() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),  {various}, 2, daysAfterJan(1)),
                      mkAlbum(2, QStringLiteral("Barrow"), {various}, 2, daysAfterJan(9))};
        lib.setUserId(kUser);
        lib.refresh();
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("album:2"));

        // Playing the older one lifts it over the newer save: markPlayed stamps
        // now, and now is after January.
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("1"));
        QCOMPARE(keysOf(lib.entries()), QStringList({QStringLiteral("album:1"),
                                                     QStringLiteral("album:2")}));

        // Re-saving the other one lifts it back, by the same measure. Re-saving
        // is un-save then save, which is how it arrives from the bridge.
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("2"));
        lib.addAlbum(mkAlbum(2, QStringLiteral("Barrow"), {various}, 2, daysAfterJan(9)));
        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("album:2"),
                 qPrintable(QStringLiteral("re-saving did not lift the album: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        // It was lifted by being re-saved *now*, not by the January date the
        // response still carried.
        QVERIFY(rowFor(lib.entries(), QStringLiteral("album:2"))
                    .value(QStringLiteral("recency")).toLongLong() > daysAfterJan(9));
    }

    // The stamp a play or a save gets is strictly later than every play and save
    // already recorded, rather than whatever the clock says. Two actions inside
    // one millisecond would otherwise tie, and the tie-break below a pin is the
    // title, so the thing the user had just done could come out second.
    //
    // Driven with a date the clock cannot beat, so the collision is certain
    // rather than a race against the millisecond boundary - which is the same
    // collision, and is also a real shape: a server `created` can be ahead of a
    // local clock that is behind or in the wrong zone.
    void aPlayOrSaveIsNeverBehindWhatIsAlreadyRecorded() {
        const qint64 ahead = QDateTime::currentMSecsSinceEpoch() + 60 * 60 * 1000;

        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.albums = {mkAlbum(1, QStringLiteral("Already ahead"), {various}, 2, ahead)};
        lib.setUserId(kUser);
        lib.refresh();

        // Saving something now has to beat it, although the clock does not.
        lib.addAlbum(mkAlbum(2, QStringLiteral("Saved now"), {various}));
        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("album:2"),
                 qPrintable(QStringLiteral("the album just saved lost to a date ahead of the "
                                           "clock: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QVERIFY(rowFor(lib.entries(), QStringLiteral("album:2"))
                    .value(QStringLiteral("recency")).toLongLong() > ahead);

        // And so does playing it, by the same measure.
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("1"));
        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("album:1"),
                 qPrintable(QStringLiteral("the album just played lost to a stamp from a moment "
                                           "ago: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // Nothing resets on a restart: the play times are on disk and the dates come
    // back from the API, so a second launch over the same data is the same list.
    void theOrderIsTheSameAfterARestart() {
        PinStore pins; pins.setUserId(kUser);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const auto fill = [&](TestLibrary &lib) {
            lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),  {various}, 2, daysAfterJan(1)),
                          mkAlbum(2, QStringLiteral("Barrow"), {various}, 2, daysAfterJan(9)),
                          mkAlbum(3, QStringLiteral("Cinder"), {various}, 2, daysAfterJan(5))};
        };

        QStringList first;
        {
            TestLibrary lib(&pins);
            fill(lib);
            lib.setUserId(kUser);
            lib.refresh();
            lib.markPlayed(QStringLiteral("album"), QStringLiteral("1"));
            first = keysOf(lib.entries());
            QCOMPARE(first, QStringList({QStringLiteral("album:1"), QStringLiteral("album:2"),
                                         QStringLiteral("album:3")}));
        }
        TestLibrary again(&pins);
        fill(again);
        again.setUserId(kUser);
        again.refresh();
        QCOMPARE(keysOf(again.entries()), first);
    }

    // A mix Tidal merely generated - "My Mix 1".."My Mix 8" - is not something
    // the user added, and Tidal regenerates the set, so it carries no date and
    // files below everything that does. Until it is played.
    void aGeneratedMixHasNoDateAndFilesBelowWhatDoes() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),
                              {mkArtist(99, QStringLiteral("Various"))}, 2, daysAfterJan(1))};
        lib.mixes  = {mkMix(QStringLiteral("m1"), QStringLiteral("Aardvark Mix"))};
        lib.setUserId(kUser);
        lib.refresh();
        QCOMPARE(keysOf(lib.entries()), QStringList({QStringLiteral("album:1"),
                                                     QStringLiteral("mix:m1")}));
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("mix:m1"))
                     .value(QStringLiteral("addedAt")).toLongLong(), 0LL);

        lib.markPlayed(QStringLiteral("mix"), QStringLiteral("m1"));
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("mix:m1"));
    }

    // A mix the user *saved* does carry one - v2/favorites/mixes reports
    // `dateAdded` per item - and ranks against the saved albums and artists on it,
    // not in a block of its own at the end.
    void aSavedMixRanksOnItsDateLikeEverythingElse() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),  {various}, 2, daysAfterJan(9)),
                      mkAlbum(2, QStringLiteral("Barrow"), {various}, 2, daysAfterJan(1))};
        lib.artists = {mkArtist(20, QStringLiteral("Dune Choir"), daysAfterJan(3))};
        // Titles chosen so an alphabetical order would put both mixes first.
        lib.mixes  = {mkMix(QStringLiteral("saved"),     QStringLiteral("Aardvark Mix"),
                            daysAfterJan(5)),
                      mkMix(QStringLiteral("generated"), QStringLiteral("Abacus Mix"))};
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(keysOf(lib.entries()), QStringList({
            QStringLiteral("album:1"),      // day 9
            QStringLiteral("mix:saved"),    // day 5, in among the albums
            QStringLiteral("artist:20"),    // day 3
            QStringLiteral("album:2"),      // day 1
            QStringLiteral("mix:generated")}));   // no date at all
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("mix:saved"))
                     .value(QStringLiteral("addedAt")).toLongLong(), daysAfterJan(5));
    }

    // The size the bug was reported at: an album saved into a library of 971.
    // The point is that the ordering holds at that size and that one save still
    // only re-sorts what is already in hand - nothing is re-paged for it.
    void aThousandRowsStillOrderByRecency() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        // Titles ascending with the id, dates descending, so A-Z and
        // newest-first are exact opposites over the whole list.
        for (int i = 0; i < 971; ++i)
            lib.albums.append(mkAlbum(1000 + i,
                                      QStringLiteral("Album %1").arg(i, 4, 10, QChar('0')),
                                      {various}, 2, daysAfterJan(971 - i)));
        lib.setUserId(kUser);
        lib.refresh();

        QCOMPARE(lib.entries().size(), 971);
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("album:1000"));
        QCOMPARE(keysOf(lib.entries()).last(),  QStringLiteral("album:1970"));

        // The reported case, at the reported size: save one more and it is first.
        const int pagedBefore = lib.albumRequests;
        lib.addAlbum(mkAlbum(50, QStringLiteral("Album 9999"), {various}));
        QCOMPARE(lib.entries().size(), 972);
        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("album:50"),
                 qPrintable(QStringLiteral("the saved album is at position %1 of %2")
                                .arg(indexOfKey(lib.entries(), QStringLiteral("album:50")))
                                .arg(lib.entries().size())));
        QCOMPARE(lib.albumRequests, pagedBefore);

        // And playing something from the far end of the list lifts it over that.
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("1970"));
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("album:1970"));
    }

    // Following an artist is the same signal as saving an album, and the two
    // rank against each other rather than in separate blocks.
    void followingAnArtistRanksWithSavingAnAlbum() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.albums = {mkAlbum(1, QStringLiteral("Anvil"),
                              {mkArtist(99, QStringLiteral("Various"))}, 2, daysAfterJan(9))};
        lib.setUserId(kUser);
        lib.refresh();
        QCOMPARE(keysOf(lib.entries()).first(), QStringLiteral("album:1"));

        lib.addArtist(mkArtist(30, QStringLiteral("Zephyr Nine")));
        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("artist:30"),
                 qPrintable(QStringLiteral("the artist just followed is not first: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // ── and its songs have to reach the search index with it ─────────────
    //
    // The sidebar row was only half of it. A saved album's tracklist is what
    // makes its songs findable, and startTrackIndex() ran from one place only,
    // the end of a refresh - so the album the user had just saved showed up in
    // the sidebar while every song on it stayed unsearchable until the next
    // launch.

    void savingAnAlbumIndexesItsTracksForSearch() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);
        QCOMPARE(lib.indexedAlbumCount(), lib.albums.size());

        const Artist moderat = mkArtist(40, QStringLiteral("Moderat"));
        const Album saved = mkAlbum(200, QStringLiteral("III"), {moderat});
        lib.albumTracks[200] = {mkTrack(600, QStringLiteral("Eating Hooks"), saved, {moderat}),
                                mkTrack(601, QStringLiteral("Reminder"),     saved, {moderat})};
        const int before = lib.tracklistRequests;
        QVERIFY(lib.search(QStringLiteral("eating hooks"), {}).isEmpty());

        lib.addAlbum(saved);
        QTest::qWait(5);

        const QStringList chip{QStringLiteral("track")};
        QVERIFY2(indexOfKey(lib.search(QStringLiteral("eating hooks"), {}), QStringLiteral("track:600")) >= 0,
                 qPrintable(QStringLiteral("\"Eating Hooks\" is not searchable; the index holds %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
        QVERIFY(indexOfKey(lib.entriesForKinds(chip), QStringLiteral("track:601")) >= 0);
        QCOMPARE(lib.indexedAlbumCount(), lib.albums.size() + 1);
        // One tracklist, the one just saved - not the library over again.
        QCOMPARE(lib.tracklistRequests, before + 1);
    }

    // The naive way to do the above is to call startTrackIndex() again, which
    // bumps the index generation and rebuilds the whole queue: every reply the
    // run already had in flight is dropped on the floor and its album asked for
    // a second time. Saving an album has to join the run in progress, not
    // restart it.
    void savingAnAlbumDuringAnIndexRunDoesNotRestartIt() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.deferTracklists = true;
        lib.setUserId(kUser);
        lib.refresh();

        QVERIFY(lib.indexing());
        lib.deliverOneTracklist();              // album 100 lands
        QTest::qWait(1);
        QCOMPARE(lib.indexedAlbumCount(), 1);
        const int requestsBefore = lib.tracklistRequests;   // 100 done, 101 in flight

        const Artist moderat = mkArtist(40, QStringLiteral("Moderat"));
        const Album saved = mkAlbum(200, QStringLiteral("III"), {moderat}, 1);
        lib.albumTracks[200] = {mkTrack(600, QStringLiteral("Eating Hooks"), saved, {moderat})};
        lib.addAlbum(saved);

        QCOMPARE(lib.tracklistRequests, requestsBefore + 1);

        lib.deliverAllTracklists();
        QTRY_VERIFY(!lib.indexing());

        // One request per album and not one more. A restart would have thrown
        // away the reply for album 101 that was in flight when the save landed
        // and gone back for it.
        QCOMPARE(lib.tracklistRequests, int(lib.albums.size()) + 1);
        QCOMPARE(lib.indexedAlbumCount(), lib.albums.size() + 1);
        QVERIFY2(indexOfKey(lib.search(QStringLiteral("roads"), {}), QStringLiteral("track:504")) >= 0,
                 "album 101's tracklist did not survive the save");
        QVERIFY(indexOfKey(lib.search(QStringLiteral("eating hooks"), {}), QStringLiteral("track:600")) >= 0);
    }

    // ── and unsaving one has to take them out again ───────────────────────
    //
    // rebuildTrackEntries() walked every album in the tracklist cache without
    // asking whether that album was still saved, and the cache itself was only
    // pruned when a whole index run finished. So the songs of an album the user
    // had just removed went on answering searches for the rest of the session.
    void unsavingAnAlbumTakesItsTracksOutOfTheSearchIndex() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        const QStringList chip{QStringLiteral("track")};
        // Album 101 is "Dummy". "Roads" is only ever found through its
        // tracklist; "Glory Box" sits on it too but is also a liked song.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("roads"), {}), QStringLiteral("track:504")) >= 0);
        QVERIFY(indexOfKey(lib.entriesForKinds(chip), QStringLiteral("track:501")) >= 0);

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("101"));

        QVERIFY2(lib.search(QStringLiteral("roads"), {}).isEmpty(),
                 qPrintable(QStringLiteral("\"Roads\" still answers a search; the index holds %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
        QVERIFY2(indexOfKey(lib.entriesForKinds(chip), QStringLiteral("track:504")) < 0,
                 qPrintable(QStringLiteral("track:504 is still under the Tracks chip: %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
        // A liked song is a favourite in its own right, so it stays even though
        // the album it happens to sit on has gone.
        QVERIFY2(indexOfKey(lib.entriesForKinds(chip), QStringLiteral("track:501")) >= 0,
                 qPrintable(QStringLiteral("unsaving the album took the liked song with it; left: %1")
                                .arg(keysOf(lib.entriesForKinds(chip)).join(QLatin1String(", ")))));
        // Every other album keeps its songs.
        QVERIFY(indexOfKey(lib.search(QStringLiteral("bachelorette"), {}), QStringLiteral("track:503")) >= 0);
        QCOMPARE(lib.indexedAlbumCount(), lib.albums.size() - 1);
        QCOMPARE(spy.count(), 1);
    }

    // The pruning above is guarded, and this is the guard: the tracklist cache
    // is read off disk at sign-in, before the album list has been paged in, and
    // with no album list yet nothing counts as "no longer saved". Without that,
    // the index would start out empty on every launch and the disk cache would
    // buy nothing. saveTrackCache() has the same guard for the same reason.
    void theDiskCacheAnswersBeforeTheAlbumListArrives() {
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
        again.setUserId(kUser);          // reads the cache; no refresh() yet
        QCOMPARE(again.entries().size(), 0);
        QVERIFY2(indexOfKey(again.search(QStringLiteral("roads"), {}), QStringLiteral("track:504")) >= 0,
                 "the cached tracklists answer nothing before the album list arrives");
    }

    // ── the one liked song that does earn a sidebar row ──────────────────
    //
    // Liked songs stay out of the library list on purpose: liking an album and
    // then five songs off it would bury everything else. The exception the user
    // asked for is the song nothing else leads to - one whose album they have
    // not saved - because without a row of its own it cannot be reached from
    // the sidebar at all.
    //
    // Both directions are live, and the second is the interesting one: saving
    // the album takes the song's row away again, and unsaving it gives the row
    // back.
    void theSidebarKeepsOnlyTheLikedSongsNothingElseLeadsTo() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const Artist brakence = mkArtist(98, QStringLiteral("Brakence"));
        const Album  orphan   = mkAlbum(4242, QStringLiteral("Hypochondriac"), {brakence});
        const Album  saved    = mkAlbum(10, QStringLiteral("Blue Train"),
                                        {mkArtist(99, QStringLiteral("Various"))});

        // One song off an unsaved album, one off a saved one.
        lib.addTrack(mkTrack(777, QStringLiteral("Deepfake"), orphan, {brakence}));
        lib.addTrack(mkTrack(778, QStringLiteral("Locomotion"), saved, {brakence}));

        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:777")) >= 0,
                 qPrintable(QStringLiteral("the unreachable song got no row; the list holds %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:778")) < 0,
                 qPrintable(QStringLiteral("the song on a saved album took a row too: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));

        // Saving the album it sits on makes the row redundant, so it goes.
        lib.addAlbum(orphan);
        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:777")) < 0,
                 qPrintable(QStringLiteral("saving the album left the song's row behind: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QVERIFY(indexOfKey(lib.entries(), QStringLiteral("album:4242")) >= 0);

        // ...and unsaving it hands the row back, because nothing leads to the
        // song again.
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("4242"));
        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:777")) >= 0,
                 qPrintable(QStringLiteral("unsaving the album did not bring the song's row back: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));

        // Unliking it is the end of it either way.
        lib.removeEntry(QStringLiteral("track"), QStringLiteral("777"));
        QVERIFY2(indexOfKey(lib.entries(), QStringLiteral("track:777")) < 0,
                 qPrintable(QStringLiteral("unliking left the row in place: %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        // The song is still never a row twice, and the Tracks chip is a
        // different list that was never filtered this way.
        lib.addTrack(mkTrack(777, QStringLiteral("Deepfake"), orphan, {brakence}));
        QCOMPARE(keysOf(lib.entries()).count(QStringLiteral("track:777")), 1);
        QVERIFY(indexOfKey(lib.entriesForKinds({QStringLiteral("track")}),
                           QStringLiteral("track:778")) >= 0);
    }

    // ── the Tracks chip is ordered by when a song was liked ──────────────
    //
    // It used to be A-Z, which made the chip useless for the thing it is for:
    // finding the song just liked. The order comes from the favourites endpoint
    // itself (order=DATE, oldest first), so it covers likes made on the phone
    // too - Tidal exposes no cross-device play history, so a local play time
    // never could.
    void theTracksChipIsOrderedByWhenASongWasLiked() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        // The pager keeps the endpoint's order, which is oldest like first. The
        // titles run backwards against it on purpose, so an alphabetical sort
        // and a by-liking sort cannot agree.
        lib.favoriteTracks = {mkTrack(801, QStringLiteral("Alpha"),   host, {various}),
                              mkTrack(802, QStringLiteral("Bravo"),   host, {various}),
                              mkTrack(803, QStringLiteral("Charlie"), host, {various})};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList chip{QStringLiteral("track")};
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)), QStringList({
            QStringLiteral("Charlie"), QStringLiteral("Bravo"), QStringLiteral("Alpha")}));

        // The case the user actually hits: like a song, and it is the first one
        // under the chip.
        lib.addTrack(mkTrack(804, QStringLiteral("Zulu"), host, {various}));
        const QStringList after = titlesOf(lib.entriesForKinds(chip));
        QVERIFY2(!after.isEmpty() && after.first() == QStringLiteral("Zulu"),
                 qPrintable(QStringLiteral("the song just liked is not first: %1")
                                .arg(after.join(QLatin1String(", ")))));
        QCOMPARE(after, QStringList({QStringLiteral("Zulu"), QStringLiteral("Charlie"),
                                     QStringLiteral("Bravo"), QStringLiteral("Alpha")}));
    }

    // ── ...and by when it was played, which is the same rule ────────────
    //
    // "isn't the sidebar with song filter pill selected supposed to show all
    // the latest played songs?" It was not: liking was the only thing the chip
    // ordered by. It is the same list of songs as before - liked songs, plus
    // the saved albums' tracklists - and the same tier under the library kinds;
    // only the order changed, to the most recent of played or liked, which is
    // the rule the rest of the sidebar already follows.

    void theTracksChipPutsTheSongJustPlayedFirst() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        lib.favoriteTracks = {mkTrack(801, QStringLiteral("Alpha"),   host, {various}),
                              mkTrack(802, QStringLiteral("Bravo"),   host, {various}),
                              mkTrack(803, QStringLiteral("Charlie"), host, {various})};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList chip{QStringLiteral("track")};
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)), QStringList({
            QStringLiteral("Charlie"), QStringLiteral("Bravo"), QStringLiteral("Alpha")}));

        // The oldest like of the three, played: it goes to the top, and the
        // two that were not played keep their order under it.
        lib.markTrackPlayed(QStringLiteral("801"));
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)), QStringList({
            QStringLiteral("Alpha"), QStringLiteral("Charlie"), QStringLiteral("Bravo")}));

        // A second play stacks on the first rather than replacing it.
        lib.markTrackPlayed(QStringLiteral("803"));
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)), QStringList({
            QStringLiteral("Charlie"), QStringLiteral("Alpha"), QStringLiteral("Bravo")}));
    }

    // Playing and liking are one axis, as they are for the four library kinds:
    // a song liked now sits above one played an hour ago. Liking is the half of
    // it that has no date from Tidal, so the like has to be stamped where it
    // happens - the favourites endpoint only gives an order, not an instant.
    void aSongJustLikedOutranksOneAlreadyPlayed() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        lib.favoriteTracks = {mkTrack(801, QStringLiteral("Alpha"), host, {various}),
                              mkTrack(802, QStringLiteral("Bravo"), host, {various})};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList chip{QStringLiteral("track")};
        lib.markTrackPlayed(QStringLiteral("801"));
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)).first(), QStringLiteral("Alpha"));

        lib.addTrack(mkTrack(804, QStringLiteral("Zulu"), host, {various}));
        QCOMPARE(titlesOf(lib.entriesForKinds(chip)), QStringList({
            QStringLiteral("Zulu"), QStringLiteral("Alpha"), QStringLiteral("Bravo")}));
    }

    // The separation that makes the whole thing affordable: a song play feeds
    // the chip and nothing else. The library list must not reorder because a
    // song played - rebuild() sorts a thousand rows and runs on every pin, play
    // and like - and a liked song whose album is not saved does have a row down
    // there, so there is something to get wrong.
    void aSongPlayDoesNotReorderTheLibraryList() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  saved   = mkAlbum(10,  QStringLiteral("Blue Train"), {various}, 2, daysAfterJan(1));
        const Album  wall    = mkAlbum(11,  QStringLiteral("The Wall"),   {various}, 2, daysAfterJan(2));
        const Album  unsaved = mkAlbum(900, QStringLiteral("Host"),       {various});
        lib.albums = {saved, wall};
        // 810's album is not saved, so it earns a row of its own in the library
        // list; 811's is, so it only ever appears under the chip.
        lib.favoriteTracks = {mkTrack(810, QStringLiteral("Orphan Song"), unsaved, {various}),
                              mkTrack(811, QStringLiteral("Album Song"),  saved,   {various})};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList before = keysOf(lib.entries());
        QVERIFY2(before.contains(QStringLiteral("track:810")),
                 qPrintable(QStringLiteral("the fixture has no orphan song row: %1")
                                .arg(before.join(QLatin1String(", ")))));

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.markTrackPlayed(QStringLiteral("810"));

        QCOMPARE(keysOf(lib.entries()), before);
        // Not even a rebuild: the sort it would run is the cost this is about.
        QCOMPARE(spy.count(), 0);
        const QVariantMap row = rowFor(lib.entries(), QStringLiteral("track:810"));
        QCOMPARE(row.value(QStringLiteral("lastPlayed")).toLongLong(), 0LL);
        QCOMPARE(row.value(QStringLiteral("recency")).toLongLong(), 0LL);

        // The chip is the one list that did change.
        QCOMPARE(titlesOf(lib.entriesForKinds({QStringLiteral("track")})), QStringList({
            QStringLiteral("Orphan Song"), QStringLiteral("Album Song")}));
    }

    void songPlayTimesSurviveARestart() {
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        const QList<Track> liked = {mkTrack(821, QStringLiteral("Alpha"),   host, {various}),
                                    mkTrack(822, QStringLiteral("Bravo"),   host, {various}),
                                    mkTrack(823, QStringLiteral("Charlie"), host, {various})};
        {
            PinStore pins; pins.setUserId(kUser);
            TestLibrary lib(&pins);
            lib.favoriteTracks = liked;
            lib.setUserId(kUser);
            lib.refresh();
            lib.markTrackPlayed(QStringLiteral("821"));
        }

        PinStore pins; pins.setUserId(kUser);
        TestLibrary again(&pins);
        again.favoriteTracks = liked;
        again.setUserId(kUser);
        again.refresh();
        QCOMPARE(titlesOf(again.entriesForKinds({QStringLiteral("track")})), QStringList({
            QStringLiteral("Alpha"), QStringLiteral("Charlie"), QStringLiteral("Bravo")}));
    }

    // The chip is the library's songs, not a play history. A song played once
    // from somebody else's playlist is not in the library and must not turn up
    // in it - the user asked for exactly that - so its play is not recorded at
    // all, which is also what keeps the stored play times bounded by the
    // library rather than by how much the user listens to.
    void aSongPlayedFromOutsideTheLibraryIsNotRemembered() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        lib.favoriteTracks = {mkTrack(801, QStringLiteral("Alpha"), host, {various})};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList chip{QStringLiteral("track")};
        const QStringList before = keysOf(lib.entriesForKinds(chip));
        lib.markTrackPlayed(QStringLiteral("99999"));

        QCOMPARE(keysOf(lib.entriesForKinds(chip)), before);
        QVERIFY2(!storedRecents(kUser).contains(QStringLiteral("track:99999")),
                 qPrintable(QStringLiteral("a play from outside the library was written down: %1")
                                .arg(QStringList(storedRecents(kUser).keys())
                                         .join(QLatin1String(", ")))));
    }

    // The bound on what is stored: a play time is worth keeping only while the
    // song is still in the library, because the chip is the only thing that
    // reads it. Unliking a song, and unsaving the album a song came in on, both
    // drop it.
    void playTimesAreForgottenWhenTheSongLeavesTheLibrary() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        lib.markTrackPlayed(QStringLiteral("500"));   // liked, on saved album 100
        lib.markTrackPlayed(QStringLiteral("504"));   // only on saved album 101
        QVERIFY(storedRecents(kUser).contains(QStringLiteral("track:500")));
        QVERIFY(storedRecents(kUser).contains(QStringLiteral("track:504")));

        // Unliking song 500 does not take it out of the index - album 100 is
        // saved and its tracklist holds it - so its play time stays.
        lib.removeEntry(QStringLiteral("track"), QStringLiteral("500"));
        QVERIFY(storedRecents(kUser).contains(QStringLiteral("track:500")));

        // Unsaving the album takes both the song and its play time.
        lib.removeEntry(QStringLiteral("album"), QStringLiteral("100"));
        QVERIFY2(!storedRecents(kUser).contains(QStringLiteral("track:500")),
                 qPrintable(QStringLiteral("a song no longer in the library kept its play time: %1")
                                .arg(QStringList(storedRecents(kUser).keys())
                                         .join(QLatin1String(", ")))));
        QVERIFY(storedRecents(kUser).contains(QStringLiteral("track:504")));

        // And the four library kinds are not pruned with them: they are the
        // list this file is mostly about, and an album keeps its play time
        // whether or not it is still saved.
        lib.markPlayed(QStringLiteral("album"), QStringLiteral("101"));
        QVERIFY(storedRecents(kUser).contains(QStringLiteral("album:101")));
    }

    // Signing in is the other place the bound is applied: a stored play time
    // for a song that is no longer anywhere in the library - unliked on the
    // phone, say - is dropped once the library has finished loading and it is
    // clear what "in the library" means.
    void staleSongPlayTimesAreDroppedOnSignIn() {
        {
            QSettings s;
            s.setValue(QStringLiteral("user_%1/library/lastPlayed").arg(kUser),
                       QStringLiteral("{\"track:777\":1700000000000,\"album:10\":1700000000000}"));
        }

        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        const Album  host    = mkAlbum(900, QStringLiteral("Host"), {various});
        lib.favoriteTracks = {mkTrack(801, QStringLiteral("Alpha"), host, {various})};
        lib.setUserId(kUser);
        lib.refresh();
        // A play of a song that *is* in the library, to show that the prune is
        // a different question from the write and does not take this one with
        // it.
        lib.markTrackPlayed(QStringLiteral("801"));

        const QVariantMap stored = storedRecents(kUser);
        QVERIFY2(!stored.contains(QStringLiteral("track:777")),
                 qPrintable(QStringLiteral("a song that left the library kept its play time: %1")
                                .arg(QStringList(stored.keys()).join(QLatin1String(", ")))));
        // The library kinds are left alone: an album the user unsaved on the
        // phone is still something they may re-save, and the list of four kinds
        // is small enough that it has never needed a bound.
        QVERIFY(stored.contains(QStringLiteral("album:10")));
        QVERIFY(stored.contains(QStringLiteral("track:801")));
    }

    // A song the background indexer merely found on a saved album has no liking
    // date, so it goes after every liked one, by title - which is where it was
    // before. And the four library kinds keep their own tiers above the songs:
    // thousands of tracks must not push an album out of sight.
    void songsWithNoLikingDateFollowTheLikedOnes() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillSearchLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();
        waitForIndex(lib);

        // Albums and tracks together: the albums come first, then the songs.
        const QVariantList both =
            lib.entriesForKinds({QStringLiteral("album"), QStringLiteral("track")});
        const QStringList keys = keysOf(both);
        int lastAlbum = -1, firstTrack = INT_MAX;
        for (int i = 0; i < keys.size(); ++i) {
            if (keys.at(i).startsWith(QLatin1String("album:"))) lastAlbum = i;
            else if (keys.at(i).startsWith(QLatin1String("track:")) && i < firstTrack) firstTrack = i;
        }
        QVERIFY2(lastAlbum < firstTrack,
                 qPrintable(QStringLiteral("a song came before an album: %1")
                                .arg(keys.join(QLatin1String(", ")))));

        // Among the songs: the three liked ones first, newest like first
        // (500, 501, 502 is the order they were fetched in), then everything the
        // indexer found, by title.
        QStringList trackKeys;
        for (const QString &k : keys)
            if (k.startsWith(QLatin1String("track:"))) trackKeys << k;
        QCOMPARE(trackKeys.mid(0, 3), QStringList({QStringLiteral("track:502"),
                                                   QStringLiteral("track:501"),
                                                   QStringLiteral("track:500")}));
        const QVariantList rows = both;
        QStringList indexedTitles;
        for (const QVariant &v : rows) {
            const QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("kind")).toString() != QLatin1String("track")) continue;
            const QString k = QStringLiteral("track:") + m.value(QStringLiteral("id")).toString();
            if (trackKeys.indexOf(k) < 3) continue;
            indexedTitles << m.value(QStringLiteral("title")).toString();
        }
        QStringList sorted = indexedTitles;
        std::sort(sorted.begin(), sorted.end());
        QCOMPARE(indexedTitles, sorted);
    }

    // ── a playlist the user creates ───────────────────────────────────────
    //
    // createPlaylist() updated neither TidalBridge's playlist list nor this
    // one, so a new playlist would have been missing from the sidebar until the
    // next launch - the same gap as liking an album, and with no favourite
    // action for playlists anywhere in the interface, creating one is the only
    // way a playlist row can appear at all.
    //
    // This was written as the sidebar half of the wiring waiting for a button
    // that did not exist. The button exists now - the "New playlist" row above
    // the library list, the Collection page's Playlists tab and the track
    // menu's picker all reach TidalBridge::createPlaylist, and
    // tests/qml/tst_new_playlist.qml drives them - so the two halves below are
    // a live path, not plumbing.
    void creatingAPlaylistPutsItInTheSidebar() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("playlist:p-new");
        QCOMPARE(indexOfKey(lib.entries(), key), -1);
        const int before = lib.playlistRequests;

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        lib.addPlaylist(mkPlaylist(QStringLiteral("p-new"), QStringLiteral("Avalon Mix"), 0));

        QVERIFY2(indexOfKey(lib.entries(), key) >= 0,
                 qPrintable(QStringLiteral("the sidebar did not gain playlist:p-new; it holds %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Avalon Mix"));
        QCOMPARE(spy.count(), 1);
        QCOMPARE(lib.playlistRequests, before);

        // Creating is not liking: there is no second time, but a repeat must
        // not double the row either.
        lib.addPlaylist(mkPlaylist(QStringLiteral("p-new"), QStringLiteral("Avalon Mix"), 0));
        QCOMPARE(keysOf(lib.entries()).count(key), 1);
        QCOMPARE(spy.count(), 1);
    }

    // ...and it has to land where the user will look for it, which is the head
    // of the unpinned block.
    //
    // addPlaylist() stamps `addedAt = stampNow()` before appending, and that
    // stamp is the only thing that puts the row there: rebuild() orders the
    // unpinned tier by max(last played, addedAt) and falls through to collation
    // for rows with no date. Drop the stamp and a playlist created in a library
    // of a thousand rows lands wherever its title happens to sort, which is the
    // same class of bug as the A-Z tier that sent a just-saved album to
    // alphabetical position 589 of 971.
    //
    // The fixture is built here rather than from fillMixedLibrary() because
    // that one carries no dates at all - every row's recency is 0, so the whole
    // list is in collation order and "Avalon Mix" would reach the front of it
    // alphabetically whether it had been stamped or not. The test above passes
    // either way. So: the other rows carry real dates, there is a pinned row to
    // make "top of the unpinned block" different from "top of the list", and
    // the new playlist is named so that it sorts *last* of the three.
    void aCreatedPlaylistLeadsTheUnpinnedBlock() {
        PinStore pins; pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("12"), QStringLiteral("The Wall"),
                 QString(), QString());

        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.playlists = {mkPlaylist(QStringLiteral("p-jan"), QStringLiteral("Abendrot"), 10,
                                    daysAfterJan(1)),
                         mkPlaylist(QStringLiteral("p-feb"), QStringLiteral("Alte Liste"), 10,
                                    daysAfterJan(20))};
        lib.albums = {mkAlbum(12, QStringLiteral("The Wall"), {various}, 2, daysAfterJan(10))};
        lib.setUserId(kUser);
        lib.refresh();

        // Pinned first, then the two playlists newest-date first.
        QCOMPARE(keysOf(lib.entries()),
                 QStringList({QStringLiteral("album:12"),
                              QStringLiteral("playlist:p-feb"),
                              QStringLiteral("playlist:p-jan")}));

        lib.addPlaylist(mkPlaylist(QStringLiteral("p-new"),
                                   QStringLiteral("Zuletzt erstellt"), 0));

        QCOMPARE(keysOf(lib.entries()),
                 QStringList({QStringLiteral("album:12"),
                              QStringLiteral("playlist:p-new"),
                              QStringLiteral("playlist:p-feb"),
                              QStringLiteral("playlist:p-jan")}));
        // Second, not first: the pinned album keeps the head of the list.
        QCOMPARE(indexOfKey(lib.entries(), QStringLiteral("playlist:p-new")), 1);
    }

    // The same thing when the response carries a date of its own, which is the
    // case the bridge's own comment flags: a POST reply may or may not include
    // `created`, and a playlist made now that arrives carrying January must
    // still read as made now. The stamp is unconditional for that reason, and
    // this is the case that says so - the one above would pass with
    // `if (p.addedAt == 0) created.addedAt = stampNow();`.
    void aCreatedPlaylistIsStampedNowWhateverDateItArrivesWith() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.playlists = {mkPlaylist(QStringLiteral("p-feb"), QStringLiteral("Alte Liste"), 10,
                                    daysAfterJan(20))};
        lib.setUserId(kUser);
        lib.refresh();

        // Named to sort last and dated nineteen days *before* the row already
        // in the library, so neither collation nor its own date can put it
        // first.
        lib.addPlaylist(mkPlaylist(QStringLiteral("p-stale"),
                                   QStringLiteral("Zuletzt erstellt"), 0, daysAfterJan(1)));

        QVERIFY2(keysOf(lib.entries()).first() == QStringLiteral("playlist:p-stale"),
                 qPrintable(QStringLiteral("a created playlist kept the stale date its reply "
                                           "carried; the list reads %1")
                                .arg(keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // ── a playlist the user renames ───────────────────────────────────────
    //
    // The sidebar keeps its own copy of the library, so a rename made on a
    // playlist's own page reached TidalBridge and stopped there: the page
    // relabelled itself and the sidebar went on showing the old name until the
    // next launch. This is the hand-across, and it is deliberately *not*
    // addPlaylist: the uuid is already here, so addPlaylist would be a no-op.
    void renamingAPlaylistRelabelsTheSidebarRow() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("playlist:p-morning");
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Morning"));
        const int before = lib.playlistRequests;

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        Playlist renamed;
        renamed.uuid  = QStringLiteral("p-morning");
        renamed.title = QStringLiteral("Früh am Tag");
        lib.updatePlaylist(renamed);

        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Früh am Tag"));
        QCOMPARE(spy.count(), 1);
        // Handed across, not re-paged. A rename that went back to the account
        // would show the right thing for the wrong reason.
        QCOMPARE(lib.playlistRequests, before);
        // One row, not two: a rename must not leave the old name behind, and
        // it must certainly not add a second row for the same uuid.
        QCOMPARE(keysOf(lib.entries()).count(key), 1);
    }

    // ...and the row must not move.
    //
    // This is the whole reason updatePlaylist exists beside addPlaylist rather
    // than reusing it. addPlaylist() stamps `addedAt = stampNow()`, and
    // rebuild() orders the unpinned tier by max(last played, addedAt) and
    // falls through to collation for rows with no date - so a rename that
    // re-stamped would send the playlist to the top of the sidebar for having
    // been given a new name.
    //
    // The fixture is built here rather than from fillMixedLibrary() for the
    // reason that one is called out above: its rows all carry addedAt == 0, so
    // the list is in pure collation order and a re-stamp would be invisible.
    // Here the rows carry real dates, a pinned album makes "top of the
    // unpinned block" different from "top of the list", and the *new* title
    // sorts first alphabetically - so a re-collation would move the row too,
    // and renaming the older of the two playlists is the only case where a
    // re-stamp shows.
    void renamingAPlaylistDoesNotMoveIt() {
        PinStore pins; pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("12"), QStringLiteral("The Wall"),
                 QString(), QString());

        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.playlists = {mkPlaylist(QStringLiteral("p-jan"), QStringLiteral("Morgenrot"), 10,
                                    daysAfterJan(1)),
                         mkPlaylist(QStringLiteral("p-feb"), QStringLiteral("Zugfahrt"), 10,
                                    daysAfterJan(20))};
        lib.albums = {mkAlbum(12, QStringLiteral("The Wall"), {various}, 2, daysAfterJan(10))};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList before = keysOf(lib.entries());
        QCOMPARE(before, QStringList({QStringLiteral("album:12"),
                                      QStringLiteral("playlist:p-feb"),
                                      QStringLiteral("playlist:p-jan")}));

        // The *last* row, renamed to a title that sorts first.
        Playlist renamed;
        renamed.uuid  = QStringLiteral("p-jan");
        renamed.title = QStringLiteral("Abends am Fluss");
        lib.updatePlaylist(renamed);

        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-jan"))
                     .value(QStringLiteral("title")).toString(),
                 QStringLiteral("Abends am Fluss"));
        QVERIFY2(keysOf(lib.entries()) == before,
                 qPrintable(QStringLiteral("renaming a playlist moved it: the list was %1 "
                                           "and is now %2")
                                .arg(before.join(QLatin1String(", ")),
                                     keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // A uuid the sidebar has never listed is ignored rather than added. The
    // signal that carries a rename has no artwork and no track count on it -
    // an edit answers with no body - so there is nothing here to build a row
    // out of, and a row built anyway would be a blank tile with a name.
    void renamingAPlaylistTheSidebarDoesNotHaveAddsNothing() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList before = keysOf(lib.entries());
        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);

        Playlist renamed;
        renamed.uuid  = QStringLiteral("p-never-seen");
        renamed.title = QStringLiteral("Abends am Fluss");
        lib.updatePlaylist(renamed);

        QCOMPARE(keysOf(lib.entries()), before);
        QCOMPARE(spy.count(), 0);
    }

    // Saving the dialog without having changed anything is a rename the server
    // accepts and the sidebar has nothing to do about. Rebuilding anyway is
    // not wrong, but it is an entriesChanged every list in the app reacts to,
    // for nothing.
    void renamingToTheNameItAlreadyHasRebuildsNothing() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        Playlist same;
        same.uuid  = QStringLiteral("p-morning");
        same.title = QStringLiteral("Morning");
        lib.updatePlaylist(same);

        QCOMPARE(spy.count(), 0);
    }

    // ── a playlist the user puts a track on ───────────────────────────────
    //
    // The fourth hand-across this split between two caches has needed, and the
    // one a user reported: a playlist they had just put two songs into still
    // called itself empty. The bridge re-reads the playlist's header after an
    // accepted add and this is the far end of it.
    //
    // Deliberately not routed through updatePlaylist. That one returns early when
    // the title and description already match, which after a track add they
    // always do, so the count would never be written - see
    // theCountSurvivesAnOtherwiseIdenticalHeader below, which is that mutation as
    // a test.
    void aTrackAddedMovesTheSidebarRowsCount() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        // Distinct counts across the three rows, so an assertion cannot pass by
        // reading the wrong one.
        lib.playlists = {mkPlaylist(QStringLiteral("p-zebra"),   QStringLiteral("Zebra Nights"), 41),
                         mkPlaylist(QStringLiteral("p-morning"), QStringLiteral("Morning"),      0),
                         mkPlaylist(QStringLiteral("p-dusk"),    QStringLiteral("Dusk"),         7)};
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("playlist:p-morning");
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt(), 0);
        const int before = lib.playlistRequests;

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        Playlist fresh;
        fresh.uuid      = QStringLiteral("p-morning");
        fresh.title     = QStringLiteral("Morning");
        fresh.numTracks = 2;
        fresh.image     = QStringLiteral("mosaic-two");
        lib.refreshPlaylistMeta(fresh);

        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt(), 2);
        QCOMPARE(spy.count(), 1);
        // The two neighbours are untouched: this writes one row, not the list.
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-zebra"))
                     .value(QStringLiteral("trackCount")).toInt(), 41);
        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-dusk"))
                     .value(QStringLiteral("trackCount")).toInt(), 7);
        // Handed across, not re-paged. The whole argument for the header read is
        // that it is one request on a mutation; a sidebar that re-paged the
        // account on top of it would give the right answer at the wrong price.
        QCOMPARE(lib.playlistRequests, before);
        QCOMPARE(keysOf(lib.entries()).count(key), 1);
    }

    // ...and the row must not move. This is the trap, and it has a rejected fork
    // patch behind it.
    //
    // `playlists/<uuid>` carries no favourites wrapper, so Playlist::fromJson
    // falls back to the playlist's own `created` - the *original author's* date,
    // which on a playlist the user merely follows can be years old. Half of
    // rebuild()'s ordering key is max(last played, addedAt), so a merge that
    // copied it would sink a playlist to the bottom of the library for the crime
    // of having a song dropped on it.
    //
    // The fixture is shaped the way renamingAPlaylistDoesNotMoveIt is, and for
    // the same reason: real dates, so a re-stamp is visible at all, and a pinned
    // album above so "top of the unpinned block" is not "top of the list". The
    // row refreshed is the *newer* of the two playlists and the payload carries a
    // 2019 date, so copying it would push that row below the other one - the only
    // direction the mistake actually goes.
    void aTrackAddedDoesNotMoveTheSidebarRow() {
        PinStore pins; pins.setUserId(kUser);
        pins.pin(QStringLiteral("album"), QStringLiteral("12"), QStringLiteral("The Wall"),
                 QString(), QString());

        TestLibrary lib(&pins);
        const Artist various = mkArtist(99, QStringLiteral("Various"));
        lib.playlists = {mkPlaylist(QStringLiteral("p-jan"), QStringLiteral("Morgenrot"), 10,
                                    daysAfterJan(1)),
                         mkPlaylist(QStringLiteral("p-feb"), QStringLiteral("Zugfahrt"), 10,
                                    daysAfterJan(20))};
        lib.albums = {mkAlbum(12, QStringLiteral("The Wall"), {various}, 2, daysAfterJan(10))};
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList before = keysOf(lib.entries());
        QCOMPARE(before, QStringList({QStringLiteral("album:12"),
                                      QStringLiteral("playlist:p-feb"),
                                      QStringLiteral("playlist:p-jan")}));

        Playlist fresh;
        fresh.uuid      = QStringLiteral("p-feb");
        fresh.title     = QStringLiteral("Zugfahrt");
        fresh.numTracks = 11;
        // 2019-01-01, the shape of date the endpoint really does answer for a
        // followed playlist.
        fresh.addedAt   = 1546300800000LL;
        lib.refreshPlaylistMeta(fresh);

        QCOMPARE(rowFor(lib.entries(), QStringLiteral("playlist:p-feb"))
                     .value(QStringLiteral("trackCount")).toInt(), 11);
        QVERIFY2(keysOf(lib.entries()) == before,
                 qPrintable(QStringLiteral("a track added to a playlist moved its row: the "
                                           "list was %1 and is now %2")
                                .arg(before.join(QLatin1String(", ")),
                                     keysOf(lib.entries()).join(QLatin1String(", ")))));
    }

    // The count moves even though the title and description are exactly what the
    // row already carries, which is the whole reason this is not updatePlaylist:
    // that one reads those two fields, finds them unchanged and returns before
    // writing anything.
    void theCountSurvivesAnOtherwiseIdenticalHeader() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("playlist:p-morning");
        const int was = rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt();
        QCOMPARE(was, 10);   // fillMixedLibrary's default

        Playlist fresh;
        fresh.uuid      = QStringLiteral("p-morning");
        fresh.title     = QStringLiteral("Morning");   // byte for byte what is there
        fresh.numTracks = 12;
        fresh.image     = QStringLiteral("img-p-morning");  // also unchanged
        lib.refreshPlaylistMeta(fresh);

        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt(), 12);
    }

    // A header read whose answer the row already agrees with is not a redraw.
    // rebuild() collates and re-tiers every row in the library and runs on every
    // pin, play and like; entriesChanged is what the sidebar rebuilds on.
    void aHeaderThatSaysNothingNewRebuildsNothing() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);
        Playlist same;
        same.uuid      = QStringLiteral("p-morning");
        same.title     = QStringLiteral("Morning");
        same.numTracks = 10;
        same.image     = QStringLiteral("img-p-morning");
        lib.refreshPlaylistMeta(same);

        QCOMPARE(spy.count(), 0);
    }

    // A uuid this list has never carried is ignored rather than added, the same
    // answer the rename path gives: a header carries no pin state and no
    // acquisition date, so a row built out of one would be a guess, and the next
    // full page brings the real row in.
    void aHeaderForAPlaylistTheSidebarDoesNotHaveAddsNothing() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        fillMixedLibrary(lib);
        lib.setUserId(kUser);
        lib.refresh();

        const QStringList before = keysOf(lib.entries());
        QSignalSpy spy(&lib, &LibraryIndex::entriesChanged);

        Playlist fresh;
        fresh.uuid      = QStringLiteral("p-never-seen");
        fresh.title     = QStringLiteral("Somewhere Else");
        fresh.numTracks = 4;
        lib.refreshPlaylistMeta(fresh);

        QCOMPARE(keysOf(lib.entries()), before);
        QCOMPARE(spy.count(), 0);
    }

    // Emptying a playlist takes the row back to no tracks. The add direction is
    // the reported bug, but the remove direction left every cached count one too
    // high and is the same single line of code.
    void aTrackRemovedMovesTheSidebarRowsCountDown() {
        PinStore pins; pins.setUserId(kUser);
        TestLibrary lib(&pins);
        lib.playlists = {mkPlaylist(QStringLiteral("p-morning"), QStringLiteral("Morning"), 1)};
        lib.setUserId(kUser);
        lib.refresh();

        const QString key = QStringLiteral("playlist:p-morning");
        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt(), 1);

        Playlist fresh;
        fresh.uuid      = QStringLiteral("p-morning");
        fresh.title     = QStringLiteral("Morning");
        fresh.numTracks = 0;
        // Tidal takes the mosaic away with the last track, so the empty string
        // here is a fact about the playlist and not a failed parse.
        fresh.image     = QString();
        lib.refreshPlaylistMeta(fresh);

        QCOMPARE(rowFor(lib.entries(), key).value(QStringLiteral("trackCount")).toInt(), 0);
        QVERIFY(rowFor(lib.entries(), key).value(QStringLiteral("imageUrl")).toString().isEmpty());
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
        lib.artists = {mkArtist(20, QStringLiteral("Alder Vane")),
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

    // A library built for the ranking cases. One name is shared by four kinds;
    // one family of titles differs only in length; one differs only in how
    // familiar it is, down to the character count, so coverage ties exactly
    // and nothing but pinning and play history can decide the order.
    static void fillRankingLibrary(TestLibrary &lib) {
        const Artist moderat = mkArtist(40, QStringLiteral("Moderat"));
        const Artist various = mkArtist(41, QStringLiteral("Various"));

        const Album selfTitled = mkAlbum(300, QStringLiteral("Moderat"), {moderat}, 1);
        const Album sun        = mkAlbum(301, QStringLiteral("Sun"), {various}, 0);
        const Album sunKing    = mkAlbum(302, QStringLiteral("Sun King"), {various}, 0);
        const Album sunflower  = mkAlbum(303, QStringLiteral("Sunflower Reverie"), {various}, 0);
        const Album blueGrass  = mkAlbum(310, QStringLiteral("Blue Grass"), {various}, 0);
        const Album blueTrain  = mkAlbum(311, QStringLiteral("Blue Train"), {various}, 0);
        const Album blueHorse  = mkAlbum(312, QStringLiteral("Blue Horse"), {various}, 0);
        const Album deepBlue   = mkAlbum(313, QStringLiteral("Deep Blue"),  {various}, 0);
        const Album ocean      = mkAlbum(320, QStringLiteral("Ocean Sides"), {various}, 2);

        lib.artists = {moderat, various};
        lib.albums  = {selfTitled, sun, sunKing, sunflower,
                       blueGrass, blueTrain, blueHorse, deepBlue, ocean};
        lib.playlists = {mkPlaylist(QStringLiteral("p-mod"), QStringLiteral("Moderat Mixtape"))};

        lib.favoriteTracks = {mkTrack(700, QStringLiteral("Ocean Choir"), ocean, {various})};

        lib.albumTracks[300] = {mkTrack(701, QStringLiteral("Moderat Intro"), selfTitled, {moderat})};
        lib.albumTracks[320] = {mkTrack(700, QStringLiteral("Ocean Choir"), ocean, {various}),
                                mkTrack(702, QStringLiteral("Ocean Drive"), ocean, {various})};
    }

    static void waitForIndex(TestLibrary &lib) {
        QTRY_VERIFY_WITH_TIMEOUT(!lib.indexing(), 5000);
    }

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestLibraryIndex)
#include "tst_library.moc"
