#include "LibraryIndex.h"

#include "TidalClient.h"
#include "ui/PinStore.h"

#include <QCollator>
#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>

#include <algorithm>
#include <memory>

using namespace Tidal;

namespace {

constexpr auto kKindAlbum    = "album";
constexpr auto kKindPlaylist = "playlist";
constexpr auto kKindArtist   = "artist";
constexpr auto kKindMix      = "mix";
constexpr auto kKindTrack    = "track";

// Version of the on-disk tracklist cache. Bumping it discards every cache
// written by an older build rather than guessing at its shape.
constexpr int kCacheVersion = 1;

// Enough rows to fill the sidebar several times over. A query like "a" would
// otherwise build a QVariantMap for every song the user owns on every
// keystroke.
constexpr int kMaxResults = 200;

QString recentsKey(qint64 uid) { return QStringLiteral("user_%1/library/lastPlayed").arg(uid); }
// What TidalBridge::markPlaylistPlayed has been writing all along. Read once
// so an existing install keeps its playlist order on the first launch after
// the sidebar rebuild.
QString legacyPlaylistRecentsKey(qint64 uid) {
    return QStringLiteral("user_%1/playlists/lastPlayed").arg(uid);
}

// Case- and accent-insensitive form used for matching. Decomposing and then
// dropping the combining marks turns "Jóga" into "joga" and "Ärzte" into
// "arzte", which is what someone typing on an ASCII keyboard expects.
QString fold(const QString &s) {
    const QString decomposed = s.normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar c : decomposed) {
        switch (c.category()) {
        case QChar::Mark_NonSpacing:
        case QChar::Mark_SpacingCombining:
        case QChar::Mark_Enclosing:
            continue;
        default:
            out.append(c);
        }
    }
    // Case folding leaves the sharp s alone, so a search for "strasse" would
    // miss "Straße".
    return out.toCaseFolded().replace(QChar(0x00DF), QLatin1String("ss"));
}

// "The Cosmos" files under C, the way a record shop would shelve it.
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

// 0 for no match. A hit at the start of the title beats one at the start of a
// word, which beats one buried inside a word: typing "love" should find
// "Lovely Days" before "Clover Field".
int scoreOf(const QString &foldedHaystack, const QString &foldedNeedle) {
    const qsizetype at = foldedHaystack.indexOf(foldedNeedle);
    if (at < 0) return 0;
    if (at == 0) return foldedHaystack.size() == foldedNeedle.size() ? 100 : 90;
    return foldedHaystack.at(at - 1).isLetterOrNumber() ? 40 : 70;
}

QString artistPictureUrl(const QString &picture, int size = 320) {
    if (picture.isEmpty()) return {};
    QString u = picture;
    u.replace('-', '/');
    return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
}

// Pages a favourites endpoint until it runs out of new items, then hands the
// whole list over in one go.
//
// Three things end a run: a page shorter than the limit, a page that added
// nothing new (which is what a server that ignores `offset` looks like, and
// the shape that would otherwise spin forever), and a hard page cap. An error
// ends it too, keeping whatever arrived before it: a half library beats none.
template <typename T, typename Fetch, typename KeyOf, typename Done>
void pageEverything(Fetch fetch, KeyOf keyOf, Done done, int limit, int maxPages) {
    struct Run {
        QList<T>      acc;
        QSet<QString> seen;
        int offset = 0;
        int pages  = 0;
        std::function<void()> step;
    };

    auto run = std::make_shared<Run>();
    // The step holds a weak reference to its own state, so the only strong
    // references are the in-flight reply callbacks. The chain frees itself
    // when the last one has run.
    std::weak_ptr<Run> weak = run;
    run->step = [weak, fetch, keyOf, done, limit, maxPages]() {
        const auto self = weak.lock();
        if (!self) return;
        fetch(self->offset, limit, [self, keyOf, done, limit, maxPages](QList<T> items, QString err) {
            if (!err.isEmpty()) { done(self->acc); return; }
            int added = 0;
            for (const T &item : items) {
                const QString k = keyOf(item);
                if (k.isEmpty() || self->seen.contains(k)) continue;
                self->seen.insert(k);
                self->acc.append(item);
                ++added;
            }
            ++self->pages;
            if (items.size() < limit || added == 0 || self->pages >= maxPages) {
                done(self->acc);
                return;
            }
            self->offset += int(items.size());
            self->step();
        });
    };
    run->step();
}

} // namespace

LibraryIndex::LibraryIndex(TidalClient *client, PinStore *pins, QObject *parent)
    : QObject(parent), m_client(client), m_pins(pins) {
    if (m_pins)
        connect(m_pins, &PinStore::changed, this, &LibraryIndex::rebuild);
}

LibraryIndex::~LibraryIndex() = default;

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

    // Whatever the previous account had in flight must not land in the new
    // one's index, and what it had indexed is worth keeping on disk.
    if (m_indexing) cancelIndexing();
    ++m_indexGen;
    m_indexQueue.clear();

    m_userId = uid;
    m_playlists.clear();
    m_albums.clear();
    m_artists.clear();
    m_mixes.clear();
    m_favoriteTracks.clear();
    m_albumTrackCache.clear();
    m_recents.clear();

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

void LibraryIndex::fetchTrackPage(int offset, int limit, TracksCb cb) {
    if (!m_client) { cb({}, QStringLiteral("no client")); return; }
    m_client->fetchFavoriteTracks(std::move(cb), limit, offset);
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
    setLoading(true);

    pageEverything<Playlist>(
        [this](int offset, int limit, PlaylistsCb cb) { fetchPlaylistPage(offset, limit, std::move(cb)); },
        [](const Playlist &p) { return p.uuid; },
        [this, gen](const QList<Playlist> &all) {
            if (gen != m_loadGen) return;
            m_playlists = all;
            partFinished(gen);
        },
        pageSize, maxPages);

    pageEverything<Album>(
        [this](int offset, int limit, AlbumsCb cb) { fetchAlbumPage(offset, limit, std::move(cb)); },
        [](const Album &a) { return QString::number(a.id); },
        [this, gen](const QList<Album> &all) {
            if (gen != m_loadGen) return;
            m_albums = all;
            partFinished(gen);
        },
        pageSize, maxPages);

    pageEverything<Artist>(
        [this](int offset, int limit, ArtistsCb cb) { fetchArtistPage(offset, limit, std::move(cb)); },
        [](const Artist &a) { return QString::number(a.id); },
        [this, gen](const QList<Artist> &all) {
            if (gen != m_loadGen) return;
            m_artists = all;
            partFinished(gen);
        },
        pageSize, maxPages);

    pageEverything<Track>(
        [this](int offset, int limit, TracksCb cb) { fetchTrackPage(offset, limit, std::move(cb)); },
        [](const Track &t) { return QString::number(t.id); },
        [this, gen](const QList<Track> &all) {
            if (gen != m_loadGen) return;
            m_favoriteTracks = all;
            partFinished(gen);
        },
        pageSize, maxPages);

    fetchMixList([this, gen](QList<Mix> mixes, QString err) {
        if (gen != m_loadGen) return;
        if (err.isEmpty()) m_mixes = mixes;
        partFinished(gen);
    });
}

void LibraryIndex::partFinished(int gen) {
    if (gen != m_loadGen) return;
    if (--m_pending > 0) return;
    rebuildTrackEntries();
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
    e.kind       = QLatin1String(kKindPlaylist);
    e.id         = p.uuid;
    e.title      = p.title;
    e.imageUrl   = p.coverUrl(320);
    e.trackCount = p.numTracks;
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
    e.artistIds.append(a.id);
    finishEntry(e);
    return e;
}

LibraryIndex::Entry LibraryIndex::entryFor(const Mix &m) {
    Entry e;
    e.kind     = QLatin1String(kKindMix);
    e.id       = m.id;
    e.title    = m.title;
    e.subtitle = m.subTitle;
    e.imageUrl = m.coverUrl(320);
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
    for (const Playlist &p : m_playlists) m_library.append(entryFor(p));
    for (const Album &a : m_albums)       m_library.append(entryFor(a));
    for (const Artist &a : m_artists)     m_library.append(entryFor(a));
    for (const Mix &m : m_mixes)          m_library.append(entryFor(m));

    for (Entry &e : m_library) {
        e.pinIndex   = m_pins ? m_pins->indexOf(e.kind, e.id) : -1;
        e.lastPlayed = m_recents.value(e.key(), 0);
    }

    // Three tiers (S2). A pinned row is only ever in the first one, which is
    // what keeps it out of the list below it (P5): there is one list, and an
    // entry occupies one place in it.
    const auto tierOf = [](const Entry &e) {
        if (e.pinIndex >= 0) return 0;
        return e.lastPlayed > 0 ? 1 : 2;
    };

    // Collation, not byte order, so "Ärzte" lands with the As and case does
    // not decide anything. QCollator follows the application locale.
    QCollator collator{QLocale()};
    collator.setCaseSensitivity(Qt::CaseInsensitive);

    std::stable_sort(m_library.begin(), m_library.end(),
                     [&](const Entry &a, const Entry &b) {
        const int ta = tierOf(a);
        const int tb = tierOf(b);
        if (ta != tb) return ta < tb;
        if (ta == 0)  return a.pinIndex < b.pinIndex;
        if (ta == 1)  return a.lastPlayed > b.lastPlayed;
        return collator.compare(a.sortKey, b.sortKey) < 0;
    });

    m_entries.clear();
    m_entries.reserve(m_library.size());
    for (const Entry &e : m_library) m_entries.append(toRow(e, 0, false, QString()));

    emit entriesChanged();
}

QVariantMap LibraryIndex::toRow(const Entry &e, int score, bool expanded,
                                const QString &expandedFrom) {
    QVariantMap m;
    m[QStringLiteral("kind")]       = e.kind;
    m[QStringLiteral("id")]         = e.id;
    m[QStringLiteral("title")]      = e.title;
    m[QStringLiteral("subtitle")]   = e.subtitle;
    m[QStringLiteral("imageUrl")]   = e.imageUrl;
    m[QStringLiteral("pinned")]     = e.pinIndex >= 0;
    m[QStringLiteral("lastPlayed")] = e.lastPlayed;
    m[QStringLiteral("trackCount")] = e.trackCount;
    if (e.albumId > 0) m[QStringLiteral("albumId")] = e.albumId;
    if (!e.artistIds.isEmpty()) m[QStringLiteral("artistId")] = e.artistIds.first();
    m[QStringLiteral("score")]        = score;
    m[QStringLiteral("expanded")]     = expanded;
    m[QStringLiteral("expandedFrom")] = expandedFrom;
    return m;
}

// ── recently played, kept locally (S4) ──────────────────────────────────────

void LibraryIndex::markPlayed(const QString &kind, const QString &id) {
    // Only the four things the sidebar lists. A song play reorders nothing.
    if (id.isEmpty() || !PinStore::isValidKind(kind)) return;

    // Two plays inside the same millisecond would tie and the newer one would
    // not come first, so the clock is nudged forward instead.
    qint64 stamp = QDateTime::currentMSecsSinceEpoch();
    for (auto it = m_recents.constBegin(); it != m_recents.constEnd(); ++it)
        if (it.value() >= stamp) stamp = it.value() + 1;

    m_recents.insert(kind + QLatin1Char(':') + id, stamp);
    saveRecents();
    rebuild();
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

    // Carry over the playlist play times the old sidebar wrote, so nobody's
    // order resets on the first launch after the rebuild.
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

// ── the lazy album tracklist index (S6) ─────────────────────────────────────

void LibraryIndex::rebuildTrackEntries() {
    m_trackEntries.clear();
    m_trackIds.clear();

    // Liked songs first: they are already cached, so they are what answers a
    // search during the very first seconds, and they are the better record of
    // a song (the favourite carries its own album).
    for (const Track &t : m_favoriteTracks) {
        if (m_trackIds.contains(t.id)) continue;
        m_trackIds.insert(t.id);
        m_trackEntries.append(entryFor(t, 0));
    }

    for (auto it = m_albumTrackCache.constBegin(); it != m_albumTrackCache.constEnd(); ++it) {
        for (const Entry &e : it.value().tracks) {
            const qint64 trackId = e.id.toLongLong();
            if (m_trackIds.contains(trackId)) continue;
            m_trackIds.insert(trackId);
            m_trackEntries.append(e);
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
        // A cached tracklist is good until the album's own track count moves,
        // which is the cheapest signal that a saved album was re-released or
        // that the cache came from a different version of it.
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

void LibraryIndex::stepTrackIndex(int gen) {
    if (gen != m_indexGen) return;      // cancelled, or a newer run took over

    if (m_indexQueue.isEmpty()) {
        // Drop tracks whose album no longer lists them, now that every
        // tracklist is current.
        rebuildTrackEntries();
        saveTrackCache();
        setIndexing(false);
        return;
    }

    const qint64 albumId = m_indexQueue.takeFirst();
    fetchAlbumTracklist(albumId, [this, gen, albumId](QList<Track> tracks, QString err) {
        if (gen != m_indexGen) return;
        if (err.isEmpty()) indexAlbum(albumId, tracks);
        // One album per turn of the event loop. The replies are asynchronous
        // already, but the parsing is not, and a library of a few hundred
        // albums must not arrive as one long stall.
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

    // Searchable right away, rather than only once the whole run is done.
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
    // Keep what was indexed, so the next launch resumes instead of restarting.
    saveTrackCache();
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
    // Wrong shape or another account's file: start over rather than guess.
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

void LibraryIndex::saveTrackCache() const {
    if (m_userId <= 0) return;

    QSet<qint64> stillSaved;
    for (const Album &a : m_albums) stillSaved.insert(a.id);

    QJsonArray albums;
    for (auto it = m_albumTrackCache.constBegin(); it != m_albumTrackCache.constEnd(); ++it) {
        // Unsaving an album drops its tracklist with it, so the file does not
        // grow forever with music the user no longer has. With no album list
        // loaded (offline, say) nothing is pruned.
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
    root[QStringLiteral("userId")]  = double(m_userId);
    root[QStringLiteral("albums")]  = albums;

    const QString path = trackCachePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return;
    f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    f.commit();
}

// ── search (S5 to S7) ───────────────────────────────────────────────────────

QVariantList LibraryIndex::search(const QString &query, const QStringList &kinds) const {
    const QString needle = fold(query.trimmed());
    if (needle.isEmpty()) return {};

    struct Hit {
        const Entry *entry = nullptr;
        int     score = 0;
        bool    expanded = false;
        QString from;
    };

    // Only titles are matched. An album is deliberately not found through its
    // artist's name here: that relationship is what result expansion is for
    // (S7), and an expanded row is flagged so the sidebar can show it as a
    // consequence of the artist match rather than as a hit of its own.
    QList<Hit> direct;
    QSet<QString> taken;
    const auto consider = [&](const Entry &e) {
        const int score = scoreOf(e.foldTitle, needle);
        if (score == 0) return;
        direct.append({&e, score, false, {}});
        taken.insert(e.key());
    };
    for (const Entry &e : m_library)      consider(e);
    for (const Entry &e : m_trackEntries) consider(e);

    QHash<QString, const Entry *> byKey;
    byKey.reserve(int(m_library.size()));
    for (const Entry &e : m_library) byKey.insert(e.key(), &e);

    QList<Hit> expanded;
    const auto expand = [&](const Entry &e, const Hit &parent) {
        if (taken.contains(e.key())) return;
        taken.insert(e.key());
        expanded.append({&e, parent.score, true, parent.entry->key()});
    };

    for (const Hit &hit : direct) {
        if (hit.entry->kind == QLatin1String(kKindArtist)) {
            const qint64 artistId = hit.entry->id.toLongLong();
            for (const Entry &e : m_library)
                if (e.kind == QLatin1String(kKindAlbum) && e.artistIds.contains(artistId))
                    expand(e, hit);
            for (const Entry &e : m_trackEntries)
                if (e.artistIds.contains(artistId))
                    expand(e, hit);
        } else if (hit.entry->kind == QLatin1String(kKindTrack) && hit.entry->albumId > 0) {
            const auto it = byKey.constFind(QLatin1String(kKindAlbum) + QLatin1Char(':')
                                            + QString::number(hit.entry->albumId));
            if (it != byKey.constEnd()) expand(**it, hit);
        }
    }

    QCollator collator{QLocale()};
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    const auto byScoreThenTitle = [&](const Hit &a, const Hit &b) {
        if (a.score != b.score) return a.score > b.score;
        return collator.compare(a.entry->sortKey, b.entry->sortKey) < 0;
    };
    std::stable_sort(direct.begin(), direct.end(), byScoreThenTitle);
    std::stable_sort(expanded.begin(), expanded.end(), byScoreThenTitle);

    // Expansions always follow the direct hits, however well their parent
    // scored, so nothing the user actually typed gets pushed down the list.
    QVariantList out;
    const auto emitHits = [&](const QList<Hit> &hits) {
        for (const Hit &hit : hits) {
            if (out.size() >= kMaxResults) return;
            if (!kinds.isEmpty() && !kinds.contains(hit.entry->kind)) continue;
            out.append(toRow(*hit.entry, hit.expanded ? 0 : hit.score, hit.expanded, hit.from));
        }
    };
    emitHits(direct);
    emitHits(expanded);
    return out;
}
