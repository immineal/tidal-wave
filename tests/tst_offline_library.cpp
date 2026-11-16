// A start without a connection. TidalBridge and LibraryIndex keep the library
// as last loaded whole on disk and show that copy when the sign-in load gets
// nothing. A list with no copy is reported as not loaded, not as empty. The
// bridge says it is offline when a request got no answer, asks again on a
// growing interval, and reloads what failed once Tidal answers. A fake client
// answers every call; nothing here touches the network.

#include <QTest>
#include <QSignalSpy>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>

#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/LibraryIndex.h"
#include "api/FavoritesCache.h"
#include "api/Models.h"

using namespace Tidal;

namespace {

constexpr qint64 kUid = 900000071;   // invented

Artist mkArtist(qint64 id, const QString &name, qint64 addedAt = 0) {
    Artist a; a.id = id; a.name = name; a.picture = QStringLiteral("ab-cd"); a.addedAt = addedAt;
    return a;
}
Album mkAlbum(qint64 id, const QString &title, qint64 addedAt = 0) {
    Album a; a.id = id; a.title = title; a.cover = QStringLiteral("aa-bb"); a.numTracks = 9;
    a.artists = {mkArtist(3, QStringLiteral("Eine Band"))}; a.addedAt = addedAt;
    a.mediaTags = {QStringLiteral("LOSSLESS")};
    return a;
}
Track mkTrack(qint64 id, const QString &title) {
    Track t; t.id = id; t.title = title; t.duration = 201;
    t.album = mkAlbum(11, QStringLiteral("Ein Album"));
    t.artists = {mkArtist(3, QStringLiteral("Eine Band"))};
    t.trackMixId = QStringLiteral("00ab");
    return t;
}
Playlist mkPlaylist(const QString &uuid, const QString &title, qint64 addedAt) {
    Playlist p; p.uuid = uuid; p.title = title; p.numTracks = 4; p.type = QStringLiteral("USER");
    p.creatorId = kUid; p.addedAt = addedAt;
    return p;
}

// Answers the sign-in calls from the lists below, at once. `offline` makes
// every call fail with Qt's sentence for a host that is not found.
class FakeClient : public TidalClient {
    Q_OBJECT
public:
    FakeClient() : TidalClient(nullptr) {}

    bool offline = false;
    QList<Track>    tracks;
    QList<Album>    albums;
    QList<Artist>   artists;
    QList<Playlist> playlists;
    int calls = 0;
    int probes = 0;

    QString err() const { return offline ? QStringLiteral("Host api.tidal.com not found") : QString(); }

    template <typename T, typename Cb>
    void page(const QList<T> &all, Cb cb, int limit, int offset) {
        ++calls;
        if (offline) { cb({}, err()); return; }
        cb(all.mid(offset, limit), {});
    }

    void fetchFavoriteTracksNewestFirst(TracksCallback cb, int limit, int offset) override {
        page(tracks, cb, limit, offset);
    }
    void fetchFavoriteTracksByIndex(TracksCallback cb, int limit, int offset, bool) override {
        page(tracks, cb, limit, offset);
    }
    void fetchFavoriteAlbums(AlbumsCallback cb, int limit, int offset) override {
        page(albums, cb, limit, offset);
    }
    void fetchFavoriteArtists(ArtistsCallback cb, int limit, int offset) override {
        page(artists, cb, limit, offset);
    }
    void fetchUserPlaylists(PlaylistsCallback cb, int limit, int offset) override {
        page(playlists, cb, limit, offset);
    }
    void fetchFavoriteIds(FavoriteIdsCallback cb) override {
        ++calls;
        cb({}, err());
    }
    void fetchFavoriteMixes(MixesCallback cb) override {
        ++calls;
        cb({}, err());
    }
    // The probe. Its answer is what TidalApi would report as reachable.
    void fetchFavoritesHead(FavoriteKind, HeadCallback cb) override {
        ++probes;
        if (!offline) emit reachableChanged(true);
        cb({}, err());
    }
};

// The sidebar's side, fed from the same lists through the fetch seams.
class FakeLibrary : public LibraryIndex {
public:
    FakeLibrary() : LibraryIndex(nullptr, nullptr, nullptr) {}
    bool offline = false;
    QList<Track>    tracks;
    QList<Album>    albums;
    QList<Artist>   artists;
    QList<Playlist> playlists;
    QList<Mix>      mixes;

protected:
    template <typename T, typename Cb>
    void page(const QList<T> &all, Cb cb, int offset, int limit) {
        if (offline) { cb({}, QStringLiteral("Host api.tidal.com not found")); return; }
        cb(all.mid(offset, limit), {});
    }
    void fetchPlaylistPage(int o, int l, PlaylistsCb cb) override { page(playlists, cb, o, l); }
    void fetchAlbumPage(int o, int l, AlbumsCb cb) override       { page(albums, cb, o, l); }
    void fetchArtistPage(int o, int l, ArtistsCb cb) override     { page(artists, cb, o, l); }
    void fetchTrackPage(int o, int l, TracksCb cb) override       { page(tracks, cb, o, l); }
    void fetchTrackIndexPage(int o, int l, TracksCb cb) override  { page(tracks, cb, o, l); }
    void fetchMixList(MixesCb cb) override {
        if (offline) { cb({}, QStringLiteral("Host api.tidal.com not found")); return; }
        cb(mixes, {});
    }
    void fetchAlbumTracklist(qint64, TracksCb cb) override { cb({}, QStringLiteral("not here")); }
};

void fill(FakeClient &c) {
    c.tracks    = {mkTrack(501, QStringLiteral("Weit hinter dem Horizont")),
                   mkTrack(502, QStringLiteral("Nachtfahrt"))};
    c.albums    = {mkAlbum(601, QStringLiteral("Abendrunde"), 1700000000123)};
    c.artists   = {mkArtist(701, QStringLiteral("Eine Band"), 1700000000456)};
    c.playlists = {mkPlaylist(QStringLiteral("p-1"), QStringLiteral("Zugfahrt"), 1700000000789)};
}

QStringList titles(const QVariantList &rows, const char *key = "title") {
    QStringList out;
    for (const QVariant &v : rows) out << v.toMap().value(QLatin1String(key)).toString();
    return out;
}

} // namespace

class TestOfflineLibrary : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_offline_library"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        // Never the real data dir: the copy on disk is written there.
        QStandardPaths::setTestModeEnabled(true);
        qputenv("HOME", m_dir.path().toUtf8());
    }

    void init() {
        QSettings().clear();
        QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)).removeRecursively();
    }

    // ── the copy on disk ─────────────────────────────────────────────────

    void everyFieldTheListsShowSurvivesTheRoundTrip() {
        FavoritesCache::Lists in;
        in.tracks = {mkTrack(501, QStringLiteral("Weit hinter dem Horizont"))};
        in.albums = {mkAlbum(601, QStringLiteral("Abendrunde"), 1700000000123)};
        in.artists = {mkArtist(701, QStringLiteral("Eine Band"), 1700000000456)};
        in.playlists = {mkPlaylist(QStringLiteral("p-1"), QStringLiteral("Zugfahrt"), 1700000000789)};
        Mix m; m.id = QStringLiteral("00ff"); m.title = QStringLiteral("Mix 1");
        m.subTitle = QStringLiteral("Eine Band"); m.cover = QStringLiteral("https://x.invalid/c.jpg");
        m.mixType = QStringLiteral("DISCOVERY_MIX");
        in.mixes = {m};
        const QString path = FavoritesCache::path(QStringLiteral("t"), kUid);
        QVERIFY(FavoritesCache::save(path, kUid, in));

        const FavoritesCache::Lists out = FavoritesCache::load(path, kUid);
        QVERIFY(out.loaded);
        const Track &t = out.tracks.value(0);
        QCOMPARE(t.id, 501);
        QCOMPARE(t.title, QStringLiteral("Weit hinter dem Horizont"));
        QCOMPARE(t.duration, 201);
        QCOMPARE(t.album.title, QStringLiteral("Ein Album"));
        QCOMPARE(t.coverUrl(80), in.tracks[0].coverUrl(80));
        QCOMPARE(t.artistNames(), QStringLiteral("Eine Band"));
        QCOMPARE(t.trackMixId, QStringLiteral("00ab"));
        QCOMPARE(out.albums.value(0).addedAt, 1700000000123);
        QCOMPARE(out.albums.value(0).mediaTags, QStringList{QStringLiteral("LOSSLESS")});
        QCOMPARE(out.artists.value(0).addedAt, 1700000000456);
        QCOMPARE(out.artists.value(0).picture, QStringLiteral("ab-cd"));
        QCOMPARE(out.playlists.value(0).addedAt, 1700000000789);
        QCOMPARE(out.playlists.value(0).creatorId, kUid);
        QCOMPARE(out.mixes.value(0).coverUrl(), m.coverUrl());
        QCOMPARE(out.mixes.value(0).mixType, m.mixType);

        // Another account's file reads as none.
        QVERIFY(!FavoritesCache::load(path, kUid + 1).loaded);
    }

    // ── TidalBridge ──────────────────────────────────────────────────────

    void anOfflineStartShowsTheLibraryLastLoaded() {
        {
            FakeClient online;
            fill(online);
            TidalBridge bridge(&online);
            online.setUserId(kUid);
            QCOMPARE(bridge.searchFavoriteTracks({}).size(), 2);
            QVERIFY(QFile::exists(bridge.cachePath()));
        }
        FakeClient off;
        off.offline = true;
        TidalBridge bridge(&off);
        off.setUserId(kUid);
        QVERIFY(!bridge.favoritesLoading());
        QCOMPARE(titles(bridge.searchFavoriteTracks({})),
                 (QStringList{QStringLiteral("Weit hinter dem Horizont"), QStringLiteral("Nachtfahrt")}));
        QCOMPARE(titles(bridge.searchFavoriteAlbums({})), QStringList{QStringLiteral("Abendrunde")});
        QCOMPARE(titles(bridge.searchFavoriteArtists({}), "name"), QStringList{QStringLiteral("Eine Band")});
        QCOMPARE(titles(bridge.searchFavoritePlaylists({})), QStringList{QStringLiteral("Zugfahrt")});
        QVERIFY(bridge.isTrackFavorite(501));
        QVERIFY(bridge.unloadedKinds().isEmpty());
        QVERIFY(bridge.libraryFromCache());
    }

    void anOfflineStartWithNoCopySaysTheListsDidNotLoad() {
        FakeClient off;
        off.offline = true;
        TidalBridge bridge(&off);
        off.setUserId(kUid);
        QVERIFY(!bridge.favoritesLoading());
        QCOMPARE(bridge.unloadedKinds(),
                 (QStringList{QStringLiteral("tracks"), QStringLiteral("albums"),
                              QStringLiteral("artists"), QStringLiteral("playlists")}));
        QVERIFY(!bridge.libraryFromCache());
        QVERIFY(!QFile::exists(bridge.cachePath()));
    }

    void aFailedLoadLeavesTheCopyAlone() {
        {
            FakeClient online;
            fill(online);
            TidalBridge bridge(&online);
            online.setUserId(kUid);
        }
        {
            FakeClient off;
            off.offline = true;
            TidalBridge bridge(&off);
            off.setUserId(kUid);
        }
        const auto disk = FavoritesCache::load(
            FavoritesCache::path(QStringLiteral("favorites"), kUid), kUid);
        QCOMPARE(disk.tracks.size(), 2);
        QCOMPARE(disk.playlists.size(), 1);
    }

    // ── offline, the probe, and coming back ──────────────────────────────

    void noAnswerMeansOfflineUntilTheProbeGetsOne() {
        FakeClient c;
        c.offline = true;
        TidalBridge bridge(&c);
        c.setUserId(kUid);
        QSignalSpy offlineSpy(&bridge, &TidalBridge::offlineChanged);
        QSignalSpy restored(&bridge, &TidalBridge::connectionRestored);

        emit c.reachableChanged(false);
        QVERIFY(bridge.offline());
        QCOMPARE(offlineSpy.count(), 1);
        QCOMPARE(bridge.nextProbeMsForTest(), TidalBridge::kProbeFirstMs);

        // Still away: each probe waits twice as long, up to the ceiling.
        bridge.retryConnection();
        QCOMPARE(c.probes, 1);
        QVERIFY(bridge.offline());
        QCOMPARE(bridge.nextProbeMsForTest(), TidalBridge::kProbeFirstMs);
        QTRY_COMPARE_WITH_TIMEOUT(c.probes, 2, TidalBridge::kProbeFirstMs + 2000);
        QCOMPARE(bridge.nextProbeMsForTest(), 2 * TidalBridge::kProbeFirstMs);

        // Back: the probe's answer clears the state and the lists load again.
        fill(c);
        c.offline = false;
        const int before = c.calls;
        bridge.retryConnection();
        QVERIFY(!bridge.offline());
        QCOMPARE(restored.count(), 1);
        QCOMPARE(bridge.nextProbeMsForTest(), -1);
        QVERIFY2(c.calls > before, "nothing was asked again once Tidal answered");
        QCOMPARE(bridge.searchFavoriteTracks({}).size(), 2);
        QVERIFY(bridge.unloadedKinds().isEmpty());
        QVERIFY(QFile::exists(bridge.cachePath()));
    }

    // ── LibraryIndex, the sidebar ────────────────────────────────────────

    void theSidebarShowsItsCopyOfflineAndSaysWhenItHasNone() {
        {
            FakeLibrary lib;
            lib.albums = {mkAlbum(601, QStringLiteral("Abendrunde"), 1700000000123)};
            lib.playlists = {mkPlaylist(QStringLiteral("p-1"), QStringLiteral("Zugfahrt"), 1)};
            lib.setUserId(kUid);
            lib.refresh();
            QCOMPARE(lib.entries().size(), 2);
            QVERIFY(!lib.loadFailed());
            QVERIFY(!lib.needsRefresh());
        }
        {
            FakeLibrary off;
            off.offline = true;
            off.setUserId(kUid);
            off.refresh();
            QCOMPARE(titles(off.entries()),
                     (QStringList{QStringLiteral("Abendrunde"), QStringLiteral("Zugfahrt")}));
            QVERIFY(off.needsRefresh());
        }
        QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)).removeRecursively();
        FakeLibrary none;
        none.offline = true;
        none.setUserId(kUid);
        none.refresh();
        QVERIFY(none.entries().isEmpty());
        QVERIFY(none.loadFailed());
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestOfflineLibrary)
#include "tst_offline_library.moc"
