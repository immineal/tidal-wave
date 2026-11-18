// SPDX-License-Identifier: GPL-3.0-or-later

#include "LibraryIndex.h"
#include "Fold.h"
#include "FavoritesCache.h"
#include "PageEverything.h"

#include "TidalClient.h"
#include "ui/PinStore.h"

#include <QCollator>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QMutex>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>
#include <QThreadPool>
#include <QTimer>
#include <QWaitCondition>

#include <algorithm>
#include <memory>
#include <optional>

using namespace Tidal;

namespace {

constexpr auto kKindAlbum    = "album";
constexpr auto kKindPlaylist = "playlist";
constexpr auto kKindArtist   = "artist";
constexpr auto kKindMix      = "mix";
constexpr auto kKindTrack    = "track";

// Version of the on-disk tracklist cache. Bumping it discards every cache
// written by an older build.
constexpr int kCacheVersion = 1;
// How long album tracklists that land are gathered before the cache is
// written: at most one write per interval during an index run.
constexpr int kTrackCacheSaveMs = 2000;

// The parts of one refresh, for m_failedParts.
enum Part { kPartPlaylists = 1, kPartAlbums = 2, kPartArtists = 4, kPartTracks = 8,
            kPartMixes = 16 };

// Caps a result list, so a one-letter query does not build a row for every
// song on every keystroke.
constexpr int kMaxResults = 200;

QString recentsKey(qint64 uid) { return QStringLiteral("user_%1/library/lastPlayed").arg(uid); }
// The key TidalBridge::markPlaylistPlayed writes. Read as a fallback so an
// install without the library key keeps its playlist order.
QString legacyPlaylistRecentsKey(qint64 uid) {
    return QStringLiteral("user_%1/playlists/lastPlayed").arg(uid);
}

// Case- and accent-insensitive form used for matching; the Collection field
// folds the same way.
QString fold(const QString &s) { return foldForMatch(s); }

// The sort key: a title files under its first word after the article.
QString stripLeadingArticle(const QString &title) {
    static const QStringList articles = {
        QStringLiteral("the "), QStringLiteral("a "), QStringLiteral("an "),
        QStringLiteral("der "), QStringLiteral("die "), QStringLiteral("das "),
    };
    const QString trimmed = title.trimmed();
    for (const QString &article : articles) {
        if (trimmed.size() > article.size() && trimmed.startsWith(article, Qt::CaseInsensitive))
            return trimmed.mid(article.size()).trimmed();
    }
    return trimmed;
}

// ── how a search result is ranked ───────────────────────────────────────────
// Four terms, added up. Where in the title the query landed sets the tier.
// Coverage, kind and familiarity reorder within a tier and can never cross
// one: the tiers are 100 apart and the three bonuses sum to less.

constexpr int kNoMatch        = 0;
constexpr int kMatchMidWord   = 100;   // buried inside a word
constexpr int kMatchWordStart = 200;   // a later word starts with it
constexpr int kMatchPrefix    = 300;   // the title starts with it
constexpr int kMatchExact     = 400;   // the title is the query

// Ceilings for the three bonuses. Their sum must stay below 100.
constexpr int kCoverageMax    = 40;
constexpr int kKindMax        = 25;
constexpr int kFamiliarityMax = 30;

int matchScore(const QString &foldedHaystack, const QString &foldedNeedle) {
    const qsizetype at = foldedHaystack.indexOf(foldedNeedle);
    if (at < 0) return kNoMatch;
    if (at == 0)
        return foldedHaystack.size() == foldedNeedle.size() ? kMatchExact : kMatchPrefix;
    return foldedHaystack.at(at - 1).isLetterOrNumber() ? kMatchMidWord : kMatchWordStart;
}

// How much of the title the query accounts for. Integer arithmetic, so two
// titles of the same length tie exactly.
int coverageBonus(qsizetype needleLen, qsizetype titleLen) {
    if (titleLen <= 0) return 0;
    return int(kCoverageMax * needleLen / titleLen);
}

// An artist leads: their page reaches every album and song of theirs. A
// liked song beats one that was only found on a saved album.
int kindBonus(const QString &kind, bool liked) {
    if (kind == QLatin1String(kKindArtist))   return kKindMax;        // 25
    if (kind == QLatin1String(kKindAlbum))    return 20;
    if (kind == QLatin1String(kKindPlaylist)) return 20;
    if (kind == QLatin1String(kKindMix))      return 10;
    return liked ? 12 : 0;
}

// Pinned beats played beats neither. Coarse on purpose: how recently
// something was played only breaks ties further down.
int familiarityBonus(int pinIndex, qint64 lastPlayed) {
    if (pinIndex >= 0)  return kFamiliarityMax;   // 30
    if (lastPlayed > 0) return 15;
    return 0;
}

QString artistPictureUrl(const QString &picture, int size = 320) {
    if (picture.isEmpty()) return {};
    QString u = picture;
    u.replace('-', '/');
    return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
}

} // namespace

// At most one write in flight; a snapshot that arrives meanwhile replaces any
// other that waits, so the latest state wins. As Player::QueueStore.
struct LibraryIndex::TrackCacheStore {
    struct Snapshot {
        QString path;
        qint64  userId = 0;
        QHash<qint64, CachedAlbum> cache;   // shared with the GUI thread's copy
        QList<Album> albums;
    };

    QMutex                  mutex;
    QWaitCondition          idle;
    bool                    busy = false;
    std::optional<Snapshot> waiting;

    static QByteArray encode(const Snapshot &s) {
        QSet<qint64> stillSaved;
        for (const Album &a : s.albums) stillSaved.insert(a.id);

        QJsonArray albums;
        for (auto it = s.cache.constBegin(); it != s.cache.constEnd(); ++it) {
            // An unsaved album's tracklist is dropped, so the file stays bounded.
            // With no album list loaded (offline, say) nothing is pruned.
            if (!stillSaved.isEmpty() && !stillSaved.contains(it.key())) continue;

            QJsonArray tracks;
            for (const Entry &e : it.value().tracks) {
                QJsonObject to;
                to[QStringLiteral("i")] = double(e.id.toLongLong());
                to[QStringLiteral("t")] = e.title;
                to[QStringLiteral("s")] = e.subtitle;
                to[QStringLiteral("c")] = e.imageUrl;
                QJsonArray artistIds;
                for (qint64 artistId : e.artistIds) artistIds.append(double(artistId));
                to[QStringLiteral("r")] = artistIds;
                tracks.append(to);
            }

            QJsonObject ao;
            ao[QStringLiteral("id")]     = double(it.key());
            ao[QStringLiteral("n")]      = it.value().numTracks;
            ao[QStringLiteral("tracks")] = tracks;
            albums.append(ao);
        }

        QJsonObject root;
        root[QStringLiteral("version")] = kCacheVersion;
        root[QStringLiteral("userId")]  = double(s.userId);
        root[QStringLiteral("albums")]  = albums;
        return QJsonDocument(root).toJson(QJsonDocument::Compact);
    }

    static void write(const Snapshot &s) {
        QDir().mkpath(QFileInfo(s.path).absolutePath());
        QSaveFile f(s.path);
        if (!f.open(QIODevice::WriteOnly)) {
            qWarning() << "LibraryIndex: could not save the tracklist cache to" << s.path
                       << f.errorString();
            return;
        }
        f.write(encode(s));
        if (!f.commit())
            qWarning() << "LibraryIndex: could not save the tracklist cache to" << s.path
                       << f.errorString();
    }

    static void submit(const std::shared_ptr<TrackCacheStore> &store, Snapshot s) {
        {
            QMutexLocker lock(&store->mutex);
            store->waiting = std::move(s);
            if (store->busy) return;
            store->busy = true;
        }
        QThreadPool::globalInstance()->start([store] {
            for (;;) {
                Snapshot next;
                {
                    QMutexLocker lock(&store->mutex);
                    if (!store->waiting) {
                        store->busy = false;
                        store->idle.wakeAll();
                        return;
                    }
                    next = std::move(*store->waiting);
                    store->waiting.reset();
                }
                write(next);
            }
        });
    }

    // Waits for what is in flight and what waits behind it.
    void flush() {
        QMutexLocker lock(&mutex);
        while (busy) idle.wait(&mutex);
    }
};

LibraryIndex::LibraryIndex(TidalClient *client, PinStore *pins, QObject *parent)
    : QObject(parent), m_client(client), m_pins(pins),
      m_cacheStore(std::make_shared<TrackCacheStore>()) {
    if (m_pins)
        connect(m_pins, &PinStore::changed, this, &LibraryIndex::rebuild);
    m_cacheTimer = new QTimer(this);
    m_cacheTimer->setSingleShot(true);
    m_cacheTimer->setInterval(kTrackCacheSaveMs);
    connect(m_cacheTimer, &QTimer::timeout, this, [this] {
        if (m_cacheDirty) saveTrackCache();
    });
}

// What landed since the last write goes out, and the quit waits for it.
LibraryIndex::~LibraryIndex() {
    if (m_cacheDirty) saveTrackCache();
    m_cacheStore->flush();
}

QVariantList LibraryIndex::entries() const { return m_entries; }
bool LibraryIndex::loading() const  { return m_loading; }
bool LibraryIndex::indexing() const { return m_indexing; }

void LibraryIndex::setLoading(bool v) {
    if (m_loading == v) return;
    m_loading = v;
    emit loadingChanged();
}

void LibraryIndex::setIndexing(bool v) {
    if (m_indexing == v) return;
    m_indexing = v;
    emit indexingChanged();
}

void LibraryIndex::setUserId(qint64 uid) {
    if (uid == m_userId) return;

    // Replies in flight for the previous account must not land in the new
    // one's index. What it had indexed is kept on disk.
    if (m_indexing) cancelIndexing();
    // A save still gathering belongs to the account it was gathered for.
    if (m_cacheDirty) saveTrackCache();
    ++m_indexGen;
    m_indexQueue.clear();

    m_userId = uid;
    m_refreshAgain = false;
    m_playlists.clear();
    m_albums.clear();
    m_artists.clear();
    m_mixes.clear();
    m_favoriteTracks.clear();
    m_albumTrackCache.clear();
    m_recents.clear();
    m_failedParts = 0;
    m_partialRun = false;
    setLoadFailed(false);

    loadRecents();
    loadTrackCache();
    rebuildTrackEntries();
    rebuild();
}

// ── fetching ────────────────────────────────────────────────────────────────

void LibraryIndex::fetchPlaylistPage(int offset, int limit, PlaylistsCb cb) {
    // The error string never reaches the interface; it only stops the pager.
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchUserPlaylists(std::move(cb), limit, offset);
}

void LibraryIndex::fetchAlbumPage(int offset, int limit, AlbumsCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchFavoriteAlbums(std::move(cb), limit, offset);
}

void LibraryIndex::fetchArtistPage(int offset, int limit, ArtistsCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchFavoriteArtists(std::move(cb), limit, offset);
}

// The order is load-bearing: order=DATE with no orderDirection answers oldest
// like first, and Entry::likeIndex is a song's position in that. Adding
// orderDirection=DESC would invert the Tracks chip.
void LibraryIndex::fetchTrackPage(int offset, int limit, TracksCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchFavoriteTracks(std::move(cb), limit, offset);
}

void LibraryIndex::fetchTrackIndexPage(int offset, int limit, TracksCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchFavoriteTracksByIndex(std::move(cb), limit, offset, false);
}

void LibraryIndex::fetchMixList(MixesCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchHomeMixes(std::move(cb));
}

void LibraryIndex::fetchAlbumTracklist(qint64 albumId, TracksCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchAlbumTracks(albumId, std::move(cb));
}

void LibraryIndex::refresh() {
    const int gen = ++m_loadGen;
    m_pending = 5;
    m_loadWhole = true;
    m_refreshAgain = false;
    m_failedParts = 0;
    m_partialRun = false;
    setLoading(true);

    const auto note = [this](int part, bool whole, bool empty) {
        if (whole) return;
        m_partialRun = true;
        if (empty) m_failedParts |= part;
    };

    // The favourites lists come in one page each. They drop unavailable rows
    // after slicing, so a short page proves nothing and they read on.
    constexpr int kBig = TidalClient::kFavoritesPageMax;

    pageEverything<Playlist>(
        [this](int offset, int limit, PlaylistsCb cb) { fetchPlaylistPage(offset, limit, std::move(cb)); },
        [](const Playlist &p) { return p.uuid; },
        [this, gen, note](const QList<Playlist> &all, bool whole) {
            if (gen != m_loadGen) return;
            note(kPartPlaylists, whole, all.isEmpty());
            land(m_playlists, all, whole);
            partFinished(gen);
        },
        pageSize, maxPages);

    const auto albumPage = [this](int offset, int limit, AlbumsCb cb) {
        fetchAlbumPage(offset, limit, std::move(cb)); };
    pageFavorites<Album>(albumPage, albumPage,
        [](const Album &a) { return QString::number(a.id); },
        [this, gen, note](const QList<Album> &all, bool whole, bool fellBack) {
            if (gen != m_loadGen) return;
            note(kPartAlbums, whole, all.isEmpty());
            land(m_albums, all, whole, fellBack);
            partFinished(gen);
        },
        kBig, pageSize, maxPages, "saved albums", true);

    const auto artistPage = [this](int offset, int limit, ArtistsCb cb) {
        fetchArtistPage(offset, limit, std::move(cb)); };
    pageFavorites<Artist>(artistPage, artistPage,
        [](const Artist &a) { return QString::number(a.id); },
        [this, gen, note](const QList<Artist> &all, bool whole, bool fellBack) {
            if (gen != m_loadGen) return;
            note(kPartArtists, whole, all.isEmpty());
            land(m_artists, all, whole, fellBack);
            partFinished(gen);
        },
        kBig, pageSize, maxPages, "followed artists", true);

    pageFavorites<Track>(
        [this](int offset, int limit, TracksCb cb) { fetchTrackPage(offset, limit, std::move(cb)); },
        [this](int offset, int limit, TracksCb cb) { fetchTrackIndexPage(offset, limit, std::move(cb)); },
        [](const Track &t) { return QString::number(t.id); },
        [this, gen, note](const QList<Track> &all, bool whole, bool) {
            if (gen != m_loadGen) return;
            note(kPartTracks, whole, all.isEmpty());
            land(m_favoriteTracks, all, whole);
            partFinished(gen);
        },
        kBig, trackPageSize, maxPages, "liked songs", false);

    fetchMixList([this, gen, note](QList<Mix> mixes, QString err) {
        if (gen != m_loadGen) return;
        note(kPartMixes, err.isEmpty(), mixes.isEmpty());
        if (err.isEmpty()) m_mixes = mixes;
        partFinished(gen);
    });
}

template <typename T>
void LibraryIndex::land(QList<T> &list, const QList<T> &all, bool whole) {
    // A broken run must not cut down a list that is already complete.
    if (whole || list.isEmpty()) list = all;
    m_loadWhole = m_loadWhole && whole;
}

template <typename T>
void LibraryIndex::land(QList<T> &list, const QList<T> &all, bool whole, bool lossy) {
    if (!lossy) { land(list, all, whole); return; }
    // Paged by date, which loses rows that share a save date: it may add to a
    // list on hand but not cut it, nor tell which songs left the library.
    const auto key = [](const T &x) { return QString::number(x.id); };
    list = list.isEmpty() ? all : mergeLossy(list, all, key);
    m_loadWhole = false;
}

void LibraryIndex::partFinished(int gen) {
    if (gen != m_loadGen) return;
    if (--m_pending > 0) return;
    // The server's answer may predate a change made here during the run.
    if (m_refreshAgain) { refresh(); return; }
    if (m_failedParts != 0) fillFromLibraryCache();
    else if (!m_partialRun) { saveLibraryCache(); setLoadFailed(false); }
    rebuildTrackEntries();
    // Only a fully loaded library can say which songs have left it.
    if (m_loadWhole) pruneSongPlays();
    rebuild();
    setLoading(false);
    startTrackIndex();
}

// ── the sidebar list ────────────────────────────────────────────────────────

void LibraryIndex::finishEntry(Entry &e) {
    e.sortKey   = stripLeadingArticle(e.title);
    e.foldTitle = fold(e.title);
}

LibraryIndex::Entry LibraryIndex::entryFor(const Playlist &p) {
    Entry e;
    e.kind         = QLatin1String(kKindPlaylist);
    e.id           = p.uuid;
    e.title        = p.title;
    e.imageUrl     = p.coverUrl(320);
    e.trackCount   = p.numTracks;
    e.playlistType = p.type;
    e.addedAt      = p.addedAt;
    finishEntry(e);
    return e;
}

LibraryIndex::Entry LibraryIndex::entryFor(const Album &a) {
    Entry e;
    e.kind       = QLatin1String(kKindAlbum);
    e.id         = QString::number(a.id);
    e.title      = a.title;
    e.subtitle   = a.artistNames();
    e.imageUrl   = a.coverUrl(320);
    e.trackCount = a.numTracks;
    e.addedAt    = a.addedAt;
    for (const Artist &artist : a.artists) e.artistIds.append(artist.id);
    finishEntry(e);
    return e;
}

LibraryIndex::Entry LibraryIndex::entryFor(const Artist &a) {
    Entry e;
    e.kind     = QLatin1String(kKindArtist);
    e.id       = QString::number(a.id);
    e.title    = a.name;
    e.imageUrl = artistPictureUrl(a.picture);
    e.addedAt  = a.addedAt;
    e.artistIds.append(a.id);
    finishEntry(e);
    return e;
}

// A saved mix carries its save date and ranks on it. A generated one has no
// date and files below everything dated until it is played or pinned.
LibraryIndex::Entry LibraryIndex::entryFor(const Mix &m) {
    Entry e;
    e.kind     = QLatin1String(kKindMix);
    e.id       = m.id;
    e.mixType  = m.mixType;
    e.title    = m.title;
    e.subtitle = m.subTitle;
    e.imageUrl = m.coverUrl(320);
    e.addedAt  = m.addedAt;
    finishEntry(e);
    return e;
}

LibraryIndex::Entry LibraryIndex::entryFor(const Track &t, qint64 albumId) {
    Entry e;
    e.kind     = QLatin1String(kKindTrack);
    e.id       = QString::number(t.id);
    e.title    = t.title;
    e.subtitle = t.artistNames();
    e.imageUrl = t.coverUrl(320);
    e.albumId  = albumId > 0 ? albumId : t.album.id;
    for (const Artist &artist : t.artists) e.artistIds.append(artist.id);
    finishEntry(e);
    return e;
}

void LibraryIndex::rebuild() {
    m_library.clear();
    m_library.reserve(m_playlists.size() + m_albums.size() + m_artists.size() + m_mixes.size());
    for (const Playlist &p : m_playlists) {
        m_library.append(entryFor(p));
        m_library.last().editable = p.editableBy(m_userId);
    }
    for (const Album &a : m_albums)       m_library.append(entryFor(a));
    for (const Artist &a : m_artists)     m_library.append(entryFor(a));
    for (const Mix &m : m_mixes)          m_library.append(entryFor(m));

    for (Entry &e : m_library) {
        e.pinIndex   = m_pins ? m_pins->indexOf(e.kind, e.id) : -1;
        e.lastPlayed = m_recents.value(e.key(), 0);
        // Playing and saving are one signal: the key is whichever was later.
        e.recency    = std::max(e.lastPlayed, e.addedAt);
    }

    // Two tiers: the pinned block, then everything else newest first.
    const auto tierOf = [](const Entry &e) { return e.pinIndex >= 0 ? 0 : 1; };

    // Collation breaks ties, so rows with no date come out by title in the
    // application locale and case decides nothing.
    QCollator collator{QLocale()};
    collator.setCaseSensitivity(Qt::CaseInsensitive);

    std::stable_sort(m_library.begin(), m_library.end(),
                     [&](const Entry &a, const Entry &b) {
        const int ta = tierOf(a);
        const int tb = tierOf(b);
        if (ta != tb) return ta < tb;
        if (ta == 0)  return a.pinIndex < b.pinIndex;
        if (a.recency != b.recency) return a.recency > b.recency;
        return collator.compare(a.sortKey, b.sortKey) < 0;
    });

    // A liked song gets a row only while its album is not saved, because
    // nothing else in the sidebar leads to it. Saving the album drops the
    // row and unsaving it brings the row back.
    QSet<qint64> savedAlbumIds;
    for (const Album &a : m_albums) savedAlbumIds.insert(a.id);

    // Pointers, so no track entry is copied into m_library: search() reads
    // both lists and would list such a song twice.
    QList<const Entry *> rows;
    rows.reserve(m_library.size());
    for (const Entry &e : m_library) rows.append(&e);
    for (const Entry &e : m_trackEntries) {
        if (!e.liked) continue;                             // only deliberate likes
        if (savedAlbumIds.contains(e.albumId)) continue;    // the album row leads to it
        rows.append(&e);
    }
    // Same tiers and collation. A song cannot be pinned and has no date
    // added, so its recency is 0 and it files at the end by title. A song
    // play writes songRecency only, so this list does not reorder.
    std::stable_sort(rows.begin(), rows.end(), [&](const Entry *a, const Entry *b) {
        const int ta = tierOf(*a);
        const int tb = tierOf(*b);
        if (ta != tb) return ta < tb;
        if (ta == 0)  return a->pinIndex < b->pinIndex;
        if (a->recency != b->recency) return a->recency > b->recency;
        return collator.compare(a->sortKey, b->sortKey) < 0;
    });

    m_entries.clear();
    m_entries.reserve(rows.size());
    for (const Entry *e : rows) m_entries.append(toRow(*e, 0));

    emit entriesChanged();
}

QVariantMap LibraryIndex::toRow(const Entry &e, int score) {
    QVariantMap m;
    m[QStringLiteral("kind")]       = e.kind;
    m[QStringLiteral("id")]         = e.id;
    m[QStringLiteral("title")]      = e.title;
    m[QStringLiteral("subtitle")]   = e.subtitle;
    m[QStringLiteral("imageUrl")]   = e.imageUrl;
    m[QStringLiteral("pinned")]     = e.pinIndex >= 0;
    m[QStringLiteral("lastPlayed")] = e.lastPlayed;
    // addedAt, recency and songRecency make the placement inspectable.
    m[QStringLiteral("addedAt")]    = e.addedAt;
    m[QStringLiteral("recency")]    = e.recency;
    m[QStringLiteral("trackCount")] = e.trackCount;
    // The types let PlaylistPage and MixPage decide what they are showing
    // before their own request lands.
    if (e.kind == QLatin1String(kKindPlaylist)) {
        m[QStringLiteral("type")] = e.playlistType;
        // Whether this account made it, and so may delete it.
        m[QStringLiteral("editable")] = e.editable;
    }
    if (e.kind == QLatin1String(kKindMix))
        m[QStringLiteral("mixType")] = e.mixType;
    if (e.kind == QLatin1String(kKindTrack))
        m[QStringLiteral("songRecency")] = e.songRecency;
    if (e.albumId > 0) m[QStringLiteral("albumId")] = e.albumId;
    if (!e.artistIds.isEmpty()) m[QStringLiteral("artistId")] = e.artistIds.first();
    m[QStringLiteral("score")] = score;
    return m;
}

// ── one row the user just saved or unsaved ──────────────────────────────────
// The payload is a freshly fetched item with no favourites row, so the date
// is stamped here as now. The next sign-in replaces it with the server's
// `created`.

void LibraryIndex::addAlbum(const Album &a) {
    m_refreshAgain = m_loading;
    if (a.id <= 0) return;
    for (const Album &x : m_albums)
        if (x.id == a.id) return;        // already saved; re-liking adds no row
    Album saved = a;
    saved.addedAt = stampNow();
    m_albums.append(saved);
    rebuild();
    // Until the tracklist is indexed no song on the album answers a search.
    indexOneAlbum(a.id);
}

void LibraryIndex::addArtist(const Artist &a) {
    m_refreshAgain = m_loading;
    if (a.id <= 0) return;
    for (const Artist &x : m_artists)
        if (x.id == a.id) return;
    Artist followed = a;
    followed.addedAt = stampNow();
    m_artists.append(followed);
    rebuild();
}

void LibraryIndex::addPlaylist(const Playlist &p) {
    m_refreshAgain = m_loading;
    if (p.uuid.isEmpty()) return;
    for (const Playlist &x : m_playlists)
        if (x.uuid == p.uuid) return;
    Playlist created = p;
    created.addedAt = stampNow();
    m_playlists.append(created);
    // Only saved albums have their tracklists indexed.
    rebuild();
}

void LibraryIndex::updatePlaylist(const Playlist &p) {
    if (p.uuid.isEmpty()) return;
    for (int i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].uuid != p.uuid) continue;
        if (m_playlists[i].title == p.title && m_playlists[i].description == p.description)
            return;   // nothing to redraw
        m_playlists[i].title       = p.title;
        m_playlists[i].description = p.description;
        // The title is part of the match key, so the entries are rebuilt.
        rebuild();
        return;
    }
    // An unknown playlist is not added: the payload has no artwork and no
    // track count. The next refresh brings the row in.
}

void LibraryIndex::refreshPlaylistMeta(const Playlist &p) {
    if (p.uuid.isEmpty()) return;
    for (int i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].uuid != p.uuid) continue;
        // Nothing changed means nothing to redraw, and rebuild() is costly.
        if (!mergePlaylistMeta(m_playlists[i], p)) return;
        // The row keeps its place: mergePlaylistMeta leaves addedAt alone.
        rebuild();
        return;
    }
    // An unknown playlist is not added, as in updatePlaylist().
}

void LibraryIndex::addTrack(const Track &t) {
    m_refreshAgain = m_loading;
    if (t.id <= 0) return;
    for (const Track &x : m_favoriteTracks)
        if (x.id == t.id) return;
    m_favoriteTracks.append(t);
    // Appended: the list is oldest first, so its end is the newest like.
    // Stamped too, in the map a song play writes to, because likeIndex is a
    // position and cannot be compared with a play time.
    m_recents.insert(QLatin1String(kKindTrack) + QLatin1Char(':') + QString::number(t.id),
                     stampNow());
    saveRecents();
    rebuildTrackEntries();
    // A liked song whose album is not saved takes a library row as well.
    rebuild();
}

void LibraryIndex::addMix(const Mix &m) {
    m_refreshAgain = m_loading;
    if (m.id.isEmpty()) return;
    for (const Mix &x : m_mixes)
        if (x.id == m.id) return;        // already listed; re-saving adds no row
    Mix saved = m;
    saved.addedAt = stampNow();
    m_mixes.append(saved);
    // A mix has no tracklist in the search index.
    rebuild();
}

void LibraryIndex::removeEntry(const QString &kind, const QString &id) {
    m_refreshAgain = m_loading;
    if (id.isEmpty()) return;

    if (kind == QLatin1String(kKindAlbum)) {
        const qint64 albumId = id.toLongLong();
        for (int i = 0; i < m_albums.size(); ++i) {
            if (m_albums[i].id != albumId) continue;
            m_albums.removeAt(i);
            // Its songs leave the index with it. The cache entry stays, so
            // re-saving the album needs no second round trip.
            rebuildTrackEntries();
            pruneSongPlays();
            rebuild();
            return;
        }
    } else if (kind == QLatin1String(kKindArtist)) {
        const qint64 artistId = id.toLongLong();
        for (int i = 0; i < m_artists.size(); ++i) {
            if (m_artists[i].id != artistId) continue;
            m_artists.removeAt(i);
            rebuild();
            return;
        }
    } else if (kind == QLatin1String(kKindPlaylist)) {
        for (int i = 0; i < m_playlists.size(); ++i) {
            if (m_playlists[i].uuid != id) continue;
            m_playlists.removeAt(i);
            rebuild();
            return;
        }
    } else if (kind == QLatin1String(kKindMix)) {
        // A mix id is a hex string: toLongLong() would turn it into 0.
        for (int i = 0; i < m_mixes.size(); ++i) {
            if (m_mixes[i].id != id) continue;
            m_mixes.removeAt(i);
            rebuild();
            return;
        }
    } else if (kind == QLatin1String(kKindTrack)) {
        const qint64 trackId = id.toLongLong();
        for (int i = 0; i < m_favoriteTracks.size(); ++i) {
            if (m_favoriteTracks[i].id != trackId) continue;
            m_favoriteTracks.removeAt(i);
            rebuildTrackEntries();
            // A song whose album is still saved stays in the index, so its
            // play time survives this.
            pruneSongPlays();
            // As in addTrack: the song may have held a library row.
            rebuild();
            return;
        }
    }
}

// ── recently played, kept locally ───────────────────────────────────────────
// Tidal exposes no cross-device play history, so only plays in this app count.

void LibraryIndex::markPlayed(const QString &kind, const QString &id) {
    // Only the four kinds the sidebar lists. A song play must not come
    // through here: this calls rebuild(), and the library list must not move
    // because a song played.
    if (id.isEmpty() || !PinStore::isValidKind(kind)) return;

    m_recents.insert(kind + QLatin1Char(':') + id, stampNow());
    saveRecents();
    rebuild();
}

// The song half. It does not rebuild() and sorts nothing: the one entry is
// patched in place, and the Tracks chip reads the order on its next query.
void LibraryIndex::markTrackPlayed(const QString &id) {
    if (id.isEmpty()) return;

    const qint64 trackId = id.toLongLong();
    if (trackId <= 0) return;
    // A song outside the song index is not recorded, which bounds the map by
    // the library. A song whose album is not indexed yet loses this one play.
    if (!m_trackIds.contains(trackId)) return;

    const qint64 stamp = stampNow();
    m_recents.insert(QLatin1String(kKindTrack) + QLatin1Char(':') + id, stamp);
    saveRecents();

    // One pass to patch the one row. rebuildTrackEntries() would re-fold
    // every title, and this runs once per song played.
    for (Entry &e : m_trackEntries) {
        if (e.id != id) continue;
        e.songRecency = stamp;
        return;
    }
}

// A timestamp strictly later than every play and every save already recorded.
// The clock alone can tie two actions inside one millisecond, and a tie falls
// back to the title. Linear in the recorded entries, once per user action.
qint64 LibraryIndex::stampNow() const {
    qint64 stamp = QDateTime::currentMSecsSinceEpoch();
    const auto after = [&stamp](qint64 t) { if (t >= stamp) stamp = t + 1; };
    for (auto it = m_recents.constBegin(); it != m_recents.constEnd(); ++it) after(it.value());
    for (const Album &a : m_albums)       after(a.addedAt);
    for (const Artist &a : m_artists)     after(a.addedAt);
    for (const Playlist &p : m_playlists) after(p.addedAt);
    return stamp;
}

void LibraryIndex::loadRecents() {
    m_recents.clear();
    if (m_userId <= 0) return;

    QSettings settings;
    const QJsonDocument doc =
        QJsonDocument::fromJson(settings.value(recentsKey(m_userId)).toString().toUtf8());
    if (doc.isObject()) {
        const QJsonObject o = doc.object();
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            m_recents.insert(it.key(), qint64(it.value().toDouble()));
    }

    // Playlist play times under the legacy key fill in where this map has none.
    const QVariantMap legacy = settings.value(legacyPlaylistRecentsKey(m_userId)).toMap();
    for (auto it = legacy.constBegin(); it != legacy.constEnd(); ++it) {
        const QString key = QLatin1String(kKindPlaylist) + QLatin1Char(':') + it.key();
        if (!m_recents.contains(key)) m_recents.insert(key, it.value().toLongLong());
    }
}

void LibraryIndex::saveRecents() const {
    if (m_userId <= 0) return;
    QJsonObject o;
    for (auto it = m_recents.constBegin(); it != m_recents.constEnd(); ++it)
        o.insert(it.key(), double(it.value()));
    QSettings settings;
    settings.setValue(recentsKey(m_userId),
                      QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
}

// Forgets the play time of a song that has left the library. Call it only
// once the library is settled: at sign-in rebuildTrackEntries() runs on the
// disk cache alone, and pruning there would drop every liked song's play time.
void LibraryIndex::pruneSongPlays() {
    if (m_userId <= 0) return;

    const QString prefix = QLatin1String(kKindTrack) + QLatin1Char(':');
    bool dropped = false;
    for (auto it = m_recents.begin(); it != m_recents.end(); ) {
        if (!it.key().startsWith(prefix)) { ++it; continue; }
        if (m_trackIds.contains(it.key().mid(prefix.size()).toLongLong())) { ++it; continue; }
        it = m_recents.erase(it);
        dropped = true;
    }
    if (dropped) saveRecents();
}

// ── the lazy album tracklist index ──────────────────────────────────────────

void LibraryIndex::rebuildTrackEntries() {
    m_trackEntries.clear();
    m_trackIds.clear();

    // Liked songs first, so a song that is also on a saved album keeps the
    // liked entry.
    for (qsizetype i = 0; i < m_favoriteTracks.size(); ++i) {
        const Track &t = m_favoriteTracks.at(i);
        if (m_trackIds.contains(t.id)) continue;
        m_trackIds.insert(t.id);
        Entry e = entryFor(t, 0);
        e.liked     = true;
        e.likeIndex = int(i);
        e.songRecency = m_recents.value(e.key(), 0);
        m_trackEntries.append(e);
    }

    QSet<qint64> stillSaved;
    for (const Album &a : m_albums) stillSaved.insert(a.id);

    for (auto it = m_albumTrackCache.constBegin(); it != m_albumTrackCache.constEnd(); ++it) {
        // An unsaved album's songs leave the index. With no album list yet,
        // as at sign-in when only the disk cache is loaded, nothing is
        // skipped.
        if (!stillSaved.isEmpty() && !stillSaved.contains(it.key())) continue;

        for (const Entry &e : it.value().tracks) {
            const qint64 trackId = e.id.toLongLong();
            if (m_trackIds.contains(trackId)) continue;
            m_trackIds.insert(trackId);
            Entry copy = e;
            copy.songRecency = m_recents.value(copy.key(), 0);
            m_trackEntries.append(copy);
        }
    }
}

int LibraryIndex::indexedAlbumCount() const {
    int n = 0;
    for (const Album &a : m_albums) {
        const auto it = m_albumTrackCache.constFind(a.id);
        if (it != m_albumTrackCache.constEnd() && it->numTracks == a.numTracks) ++n;
    }
    return n;
}

void LibraryIndex::startTrackIndex() {
    m_indexQueue.clear();
    for (const Album &a : m_albums) {
        const auto it = m_albumTrackCache.constFind(a.id);
        // A cached tracklist is good until the album's track count moves.
        if (it != m_albumTrackCache.constEnd() && it->numTracks == a.numTracks) continue;
        m_indexQueue.append(a.id);
    }

    ++m_indexGen;
    if (m_indexQueue.isEmpty()) {
        saveTrackCache();
        return;
    }
    setIndexing(true);
    stepTrackIndex(m_indexGen);
}

void LibraryIndex::indexOneAlbum(qint64 albumId) {
    if (albumId <= 0) return;

    int declared = 0;
    bool saved = false;
    for (const Album &a : m_albums)
        if (a.id == albumId) { declared = a.numTracks; saved = true; break; }
    if (!saved) return;

    // Already cached and current, by the test startTrackIndex() uses.
    const auto cached = m_albumTrackCache.constFind(albumId);
    if (cached != m_albumTrackCache.constEnd() && cached->numTracks == declared) {
        // The cached songs were filtered out while the album was unsaved,
        // so the entries are built again.
        const qsizetype was = m_trackEntries.size();
        rebuildTrackEntries();
        if (m_trackEntries.size() != was) emit entriesChanged();
        return;
    }

    // No ++m_indexGen here: a run in flight keeps its generation and queue.
    const int gen = m_indexGen;
    fetchAlbumTracklist(albumId, [this, gen, albumId](QList<Track> tracks, QString err) {
        if (gen != m_indexGen) return;
        if (!err.isEmpty()) return;
        const qsizetype was = m_trackEntries.size();
        indexAlbum(albumId, tracks);
        if (m_trackEntries.size() != was) emit entriesChanged();
    });
}

void LibraryIndex::stepTrackIndex(int gen) {
    if (gen != m_indexGen) return;      // cancelled, or a newer run took over

    if (m_indexQueue.isEmpty()) {
        // Every tracklist is current: drop tracks that no album lists.
        rebuildTrackEntries();
        saveTrackCache();
        setIndexing(false);
        return;
    }

    const qint64 albumId = m_indexQueue.takeFirst();
    fetchAlbumTracklist(albumId, [this, gen, albumId](QList<Track> tracks, QString err) {
        if (gen != m_indexGen) return;
        if (err.isEmpty()) indexAlbum(albumId, tracks);
        // One album per turn of the event loop: the parsing is synchronous
        // and must not add up to one long stall.
        QTimer::singleShot(0, this, [this, gen]() { stepTrackIndex(gen); });
    });
}

void LibraryIndex::indexAlbum(qint64 albumId, const QList<Track> &tracks) {
    int declared = int(tracks.size());
    for (const Album &a : m_albums)
        if (a.id == albumId) { declared = a.numTracks; break; }

    CachedAlbum cached;
    cached.numTracks = declared;
    cached.tracks.reserve(tracks.size());
    for (const Track &t : tracks) cached.tracks.append(entryFor(t, albumId));
    m_albumTrackCache.insert(albumId, cached);
    // Kept as it goes, so a run cut short does not fetch these again.
    scheduleTrackCacheSave();

    // Searchable right away, before the whole run is done.
    for (const Entry &e : cached.tracks) {
        const qint64 trackId = e.id.toLongLong();
        if (m_trackIds.contains(trackId)) continue;
        m_trackIds.insert(trackId);
        m_trackEntries.append(e);
    }
}

void LibraryIndex::cancelIndexing() {
    if (!m_indexing) return;
    ++m_indexGen;              // in-flight replies see a stale generation
    m_indexQueue.clear();
    setIndexing(false);
    // Keep what was indexed, so the next launch resumes.
    saveTrackCache();
}

void LibraryIndex::setLoadFailed(bool v) {
    if (m_loadFailed == v) return;
    m_loadFailed = v;
    emit loadFailedChanged();
}

void LibraryIndex::saveLibraryCache() const {
    if (m_userId <= 0) return;
    FavoritesCache::Lists lists;
    lists.tracks    = m_favoriteTracks;
    lists.albums    = m_albums;
    lists.artists   = m_artists;
    lists.playlists = m_playlists;
    lists.mixes     = m_mixes;
    FavoritesCache::save(FavoritesCache::path(QStringLiteral("sidebar"), m_userId),
                         m_userId, lists);
}

// A list that got nothing, offline say, takes the disk copy where there is
// one. One that already has rows keeps them.
void LibraryIndex::fillFromLibraryCache() {
    const FavoritesCache::Lists disk = FavoritesCache::load(
        FavoritesCache::path(QStringLiteral("sidebar"), m_userId), m_userId);
    bool missing = false;
    const auto fill = [&](int part, auto &list, const auto &cached) {
        if (!(m_failedParts & part) || !list.isEmpty()) return;
        list = cached;
        if (list.isEmpty()) missing = true;
    };
    fill(kPartPlaylists, m_playlists, disk.playlists);
    fill(kPartAlbums, m_albums, disk.albums);
    fill(kPartArtists, m_artists, disk.artists);
    fill(kPartTracks, m_favoriteTracks, disk.tracks);
    fill(kPartMixes, m_mixes, disk.mixes);
    setLoadFailed(missing);
}

QString LibraryIndex::trackCachePath() const {
    const QString root = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return root + QStringLiteral("/library/albumtracks-%1.json").arg(m_userId);
}

void LibraryIndex::loadTrackCache() {
    m_albumTrackCache.clear();
    if (m_userId <= 0) return;

    QFile f(trackCachePath());
    if (!f.open(QIODevice::ReadOnly)) return;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    if (!doc.isObject()) return;

    const QJsonObject root = doc.object();
    // Wrong version or another account's file: start over.
    if (root.value(QStringLiteral("version")).toInt() != kCacheVersion) return;
    if (qint64(root.value(QStringLiteral("userId")).toDouble()) != m_userId) return;

    for (const QJsonValue &av : root.value(QStringLiteral("albums")).toArray()) {
        const QJsonObject ao = av.toObject();
        const qint64 albumId = qint64(ao.value(QStringLiteral("id")).toDouble());
        if (albumId <= 0) continue;

        CachedAlbum cached;
        cached.numTracks = ao.value(QStringLiteral("n")).toInt();
        for (const QJsonValue &tv : ao.value(QStringLiteral("tracks")).toArray()) {
            const QJsonObject to = tv.toObject();
            Entry e;
            e.kind     = QLatin1String(kKindTrack);
            e.id       = QString::number(qint64(to.value(QStringLiteral("i")).toDouble()));
            e.title    = to.value(QStringLiteral("t")).toString();
            e.subtitle = to.value(QStringLiteral("s")).toString();
            e.imageUrl = to.value(QStringLiteral("c")).toString();
            e.albumId  = albumId;
            for (const QJsonValue &rv : to.value(QStringLiteral("r")).toArray())
                e.artistIds.append(qint64(rv.toDouble()));
            if (e.title.isEmpty()) continue;
            finishEntry(e);
            cached.tracks.append(e);
        }
        m_albumTrackCache.insert(albumId, cached);
    }
}

void LibraryIndex::saveTrackCache() {
    m_cacheDirty = false;
    m_cacheTimer->stop();
    if (m_userId <= 0) return;
    // Both copies share their data: nothing is serialised on this thread.
    TrackCacheStore::submit(m_cacheStore, TrackCacheStore::Snapshot{
        trackCachePath(), m_userId, m_albumTrackCache, m_albums });
}

void LibraryIndex::scheduleTrackCacheSave() {
    m_cacheDirty = true;
    if (!m_cacheTimer->isActive()) m_cacheTimer->start();
}

// ── search ──────────────────────────────────────────────────────────────────

QVariantList LibraryIndex::entriesForKinds(const QStringList &kinds) const {
    if (kinds.isEmpty()) return m_entries;

    const bool wantsTracks = kinds.contains(QLatin1String(kKindTrack));

    QList<const Entry *> picked;
    for (const Entry &e : m_library)
        if (kinds.contains(e.kind)) picked.append(&e);

    // Songs get a tier of their own below the library kinds. Within it:
    // songRecency (played or liked in this app), then likeIndex (the order of
    // likes, which also covers other devices), then title.
    if (wantsTracks)
        for (const Entry &e : m_trackEntries) picked.append(&e);

    const auto tierOf = [](const Entry &e) {
        if (e.kind == QLatin1String(kKindTrack)) return 2;
        return e.pinIndex >= 0 ? 0 : 1;
    };

    QCollator collator{QLocale()};
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::stable_sort(picked.begin(), picked.end(),
                     [&](const Entry *a, const Entry *b) {
        const int ta = tierOf(*a);
        const int tb = tierOf(*b);
        if (ta != tb) return ta < tb;
        if (ta == 0)  return a->pinIndex < b->pinIndex;
        if (ta == 2) {
            if (a->songRecency != b->songRecency) return a->songRecency > b->songRecency;
            if (a->likeIndex   != b->likeIndex)   return a->likeIndex   > b->likeIndex;
        } else if (a->recency != b->recency) {
            return a->recency > b->recency;
        }
        return collator.compare(a->sortKey, b->sortKey) < 0;
    });

    QVariantList out;
    out.reserve(picked.size());
    for (const Entry *e : picked) out.append(toRow(*e, 0));
    return out;
}

QVariantList LibraryIndex::search(const QString &query, const QStringList &kinds) const {
    const QString needle = fold(query.trimmed());
    if (needle.isEmpty()) return {};

    struct Hit {
        const Entry *entry = nullptr;
        int score = 0;
    };

    // Titles only, and only the thing whose title matched. An album is not
    // found through its artist's name, and an artist hit lists no albums.
    QList<Hit> hits;
    const auto consider = [&](const Entry &e) {
        if (!kinds.isEmpty() && !kinds.contains(e.kind)) return;
        const int where = matchScore(e.foldTitle, needle);
        if (where == kNoMatch) return;
        hits.append({&e, where
                         + coverageBonus(needle.size(), e.foldTitle.size())
                         + kindBonus(e.kind, e.liked)
                         + familiarityBonus(e.pinIndex, e.lastPlayed)});
    };
    for (const Entry &e : m_library)      consider(e);
    for (const Entry &e : m_trackEntries) consider(e);

    QCollator collator{QLocale()};
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::stable_sort(hits.begin(), hits.end(), [&](const Hit &a, const Hit &b) {
        if (a.score != b.score) return a.score > b.score;
        // Equal scores: the one played more recently first, then A-Z, so the
        // order never depends on fetch order.
        if (a.entry->lastPlayed != b.entry->lastPlayed)
            return a.entry->lastPlayed > b.entry->lastPlayed;
        return collator.compare(a.entry->sortKey, b.entry->sortKey) < 0;
    });

    const qsizetype shown = std::min<qsizetype>(hits.size(), kMaxResults);
    QVariantList out;
    out.reserve(shown);
    for (qsizetype i = 0; i < shown; ++i) out.append(toRow(*hits[i].entry, hits[i].score));
    return out;
}
