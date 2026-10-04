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

// ── how a search result is ranked (S5) ──────────────────────────────────────
//
// Four terms, added up. The first is where in the title the query landed and
// it dominates: the tiers are 100 apart and the other three together can never
// reach 95, so a weaker match can be reordered among its equals but can never
// climb over a better-placed one. Someone who pinned a playlist still does not
// want it above the album they just spelled out in full.
//
// The three that follow are the difference between a substring filter and a
// ranking, and each answers a question the bare position cannot:
//
//   coverage      how much of the title the query accounts for. "Dub" is all
//                 of "Dub" and a sixth of "Dubstep Essentials Volume Four".
//   kind          what sort of thing matched. The four library kinds were
//                 saved on purpose, so they beat a song; a liked song beats a
//                 song the background indexer merely found sitting on a saved
//                 album, which is the weakest evidence in the whole index.
//   familiarity   pinned, or played recently. The library list itself is
//                 ordered that way (S2), so the search agrees with it.

constexpr int kNoMatch        = 0;
constexpr int kMatchMidWord   = 100;   // buried inside a word
constexpr int kMatchWordStart = 200;   // a later word starts with it
constexpr int kMatchPrefix    = 300;   // the title starts with it
constexpr int kMatchExact     = 400;   // the title is the query

// Ceilings for the three adjustments. 40 + 25 + 30 < 100, which is what keeps
// a tier sealed.
constexpr int kCoverageMax    = 40;
constexpr int kKindMax        = 25;
constexpr int kFamiliarityMax = 30;

// kNoMatch for no match. Typing "love" finds "Lovely Days" before "Endless
// Love" before "Clover Field".
int matchScore(const QString &foldedHaystack, const QString &foldedNeedle) {
    const qsizetype at = foldedHaystack.indexOf(foldedNeedle);
    if (at < 0) return kNoMatch;
    if (at == 0)
        return foldedHaystack.size() == foldedNeedle.size() ? kMatchExact : kMatchPrefix;
    return foldedHaystack.at(at - 1).isLetterOrNumber() ? kMatchMidWord : kMatchWordStart;
}

// A short title matched in full is a far stronger signal than a long one that
// happens to contain the same letters. Plain integer arithmetic, so two titles
// of the same length always tie exactly.
int coverageBonus(qsizetype needleLen, qsizetype titleLen) {
    if (titleLen <= 0) return 0;
    return int(kCoverageMax * needleLen / titleLen);
}

// An artist is the widest door: their page leads to every album, every song
// and the rest of the catalogue, so when a name is both an artist and an album
// the artist is nearly always the one meant.
int kindBonus(const QString &kind, bool liked) {
    if (kind == QLatin1String(kKindArtist))   return kKindMax;        // 25
    if (kind == QLatin1String(kKindAlbum))    return 20;
    if (kind == QLatin1String(kKindPlaylist)) return 20;
    // A mix is a destination too, but Tidal picked it, not the user.
    if (kind == QLatin1String(kKindMix))      return 10;
    return liked ? 12 : 0;
}

// Pinned beats played beats neither. Deliberately coarse: how recently
// something was played breaks ties further down rather than scoring here, so
// a play five minutes ago cannot outweigh a better match.
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

// Careful: the order this returns is load-bearing, in two places. The endpoint
// is asked for order=DATE with no orderDirection, so it answers oldest like
// first, and the pager keeps that order; Entry::likeIndex is simply a song's
// position in it, and the Tracks chip is sorted by that descending to get
// "newest liked first". Adding orderDirection=DESC here - as
// TidalClient::fetchFavoriteAlbums does, so it is an easy symmetry to reach for
// - would silently invert the chip. TidalBridge keeps a second copy of the same
// list and reverses it once paging ends, which is the other reader.
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
    // The library has just finished loading, so this is the first moment in a
    // session where "no longer in the library" means anything - a song unliked
    // on the phone is only visible now.
    pruneSongPlays();
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

// A mix the user *saved* carries the date they saved it, from v2/favorites/mixes,
// and ranks with the saved albums and artists on it. One that only Tidal
// generated - "My Mix 1".."My Mix 8" - has no date, because nobody added it and
// Tidal regenerates the set; it files below everything dated until it is played
// or pinned.
LibraryIndex::Entry LibraryIndex::entryFor(const Mix &m) {
    Entry e;
    e.kind     = QLatin1String(kKindMix);
    e.id       = m.id;
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
    for (const Playlist &p : m_playlists) m_library.append(entryFor(p));
    for (const Album &a : m_albums)       m_library.append(entryFor(a));
    for (const Artist &a : m_artists)     m_library.append(entryFor(a));
    for (const Mix &m : m_mixes)          m_library.append(entryFor(m));

    for (Entry &e : m_library) {
        e.pinIndex   = m_pins ? m_pins->indexOf(e.kind, e.id) : -1;
        e.lastPlayed = m_recents.value(e.key(), 0);
        // Playing and saving are one signal, so the key is whichever happened
        // later. Computed here, once per row, and not inside the comparator: a
        // library of a thousand rows is sorted on every pin, play and like.
        e.recency    = std::max(e.lastPlayed, e.addedAt);
    }

    // Two tiers: the pinned block, then everything else newest first. A pinned
    // row is only ever in the first one, which is what keeps it out of the list
    // below it: there is one list, and an entry occupies one place in it.
    //
    // There used to be a third tier, A-Z for everything never played, and it is
    // what sent a just-saved album to alphabetical position 589 of 971 - which
    // the user could not tell from the album not being saved at all. It is gone
    // on their decision; `created` on the favourites row is what replaced it.
    const auto tierOf = [](const Entry &e) { return e.pinIndex >= 0 ? 0 : 1; };

    // Collation, not byte order, so "Ärzte" lands with the As and case does
    // not decide anything. QCollator follows the application locale. It is the
    // tie-break now rather than a tier of its own: rows with no date at all -
    // mixes, and liked songs whose album is not saved - would otherwise come out
    // in whatever order the library happened to be fetched in.
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

    // A liked song does not get a row of its own - a library holds thousands
    // and they would bury the albums and playlists - with one exception: a song
    // whose album the user has *not* saved is otherwise unreachable from the
    // sidebar at all. Nothing on screen leads to it. So that one earns a row,
    // and it loses it again the moment the album it sits on is saved, because
    // the album row then leads to it.
    //
    // Both directions matter and both are live: saving an album drops the rows
    // of its now-redundant liked songs, unsaving one brings them back.
    QSet<qint64> savedAlbumIds;
    for (const Album &a : m_albums) savedAlbumIds.insert(a.id);

    // Pointers, so the track entries are not copied into m_library: that list
    // is what entriesForKinds() and search() read, and a song appearing in both
    // it and m_trackEntries would be considered - and listed - twice.
    // Reserved for the library rows alone: the songs that get through the two
    // filters below are a handful, while m_trackEntries can hold tens of
    // thousands, and rebuild() runs on every pin, play and like.
    QList<const Entry *> rows;
    rows.reserve(m_library.size());
    for (const Entry &e : m_library) rows.append(&e);
    for (const Entry &e : m_trackEntries) {
        if (!e.liked) continue;                             // only deliberate likes
        if (savedAlbumIds.contains(e.albumId)) continue;    // the album row leads to it
        rows.append(&e);
    }
    // Same two tiers, same collation. A song cannot be pinned (PinStore rejects
    // the kind) and carries no date added - the favourites row a song arrives
    // in is not read this far - so its recency is 0 and it files at the end,
    // under its title. Playing a song does not change that either: a song play
    // writes Entry::songRecency, which only the Tracks chip reads, precisely so
    // that this list does not reorder. See markTrackPlayed() and
    // entriesForKinds().
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
    // The date added, and the ordering key the row was placed by, which is the
    // later of the two. Nothing in qml/ reads them yet; they are what makes the
    // placement inspectable from outside rebuild().
    m[QStringLiteral("addedAt")]    = e.addedAt;
    m[QStringLiteral("recency")]    = e.recency;
    m[QStringLiteral("trackCount")] = e.trackCount;
    // Playlists carry their Tidal type. PlaylistPage needs it to tell an
    // editable user playlist from a read-only editorial one, and the row is
    // the only place it can learn that without another round trip.
    if (e.kind == QLatin1String(kKindPlaylist))
        m[QStringLiteral("type")] = e.playlistType;
    // Songs only, and for the same reason as addedAt/recency above: it is what
    // makes the Tracks chip's placement inspectable from outside the sort.
    if (e.kind == QLatin1String(kKindTrack))
        m[QStringLiteral("songRecency")] = e.songRecency;
    if (e.albumId > 0) m[QStringLiteral("albumId")] = e.albumId;
    if (!e.artistIds.isEmpty()) m[QStringLiteral("artistId")] = e.artistIds.first();
    m[QStringLiteral("score")] = score;
    return m;
}

// ── one row the user just saved or unsaved (see the header) ─────────────────
//
// Each of these is "is it already here, if not put it in the list refresh()
// would have put it in, then rebuild". rebuild() does the tiering, the
// collation and the signal, so none of that is repeated here.
//
// What arrives here is a freshly fetched album/artist/playlist - TidalBridge
// re-reads the item after the POST is acknowledged - so there is no favourites
// row on it and no `created`. The date is stamped here instead, and "now" is the
// right answer because the user has just saved it; the next sign-in replaces it
// with the server's own `created` for the same moment, so the order survives a
// restart. Un-saving and saving again is the only way to re-save something, and
// it arrives as removeEntry() then this, which re-stamps it - which is what puts
// a re-saved album at the top, level with having played it.

void LibraryIndex::addAlbum(const Album &a) {
    if (a.id <= 0) return;
    for (const Album &x : m_albums)
        if (x.id == a.id) return;        // already saved; re-liking adds no row
    Album saved = a;
    saved.addedAt = stampNow();
    m_albums.append(saved);
    rebuild();
    // The row is only half of it: until this album's tracklist is in the index,
    // every song on it answers no search. startTrackIndex() runs from
    // partFinished() alone, so without this the songs waited for the next
    // launch.
    indexOneAlbum(a.id);
}

void LibraryIndex::addArtist(const Artist &a) {
    if (a.id <= 0) return;
    for (const Artist &x : m_artists)
        if (x.id == a.id) return;
    Artist followed = a;
    followed.addedAt = stampNow();
    m_artists.append(followed);
    rebuild();
}

void LibraryIndex::addPlaylist(const Playlist &p) {
    if (p.uuid.isEmpty()) return;
    for (const Playlist &x : m_playlists)
        if (x.uuid == p.uuid) return;
    Playlist created = p;
    created.addedAt = stampNow();
    m_playlists.append(created);
    // No tracklist to index: only saved albums are indexed, deliberately, and a
    // playlist the user has just created is empty anyway.
    rebuild();
}

void LibraryIndex::updatePlaylist(const Playlist &p) {
    // Mirrors addPlaylist's first line, and like it this is belt and braces
    // rather than a live guard: the pager drops every row whose key is empty
    // (see the `k.isEmpty()` skip in the page accumulator above), and
    // addPlaylist refuses one too, so m_playlists cannot hold a uuid-less
    // playlist for an empty uuid to match. Deleting the line changes no
    // behaviour - a test written for it passed with it gone, which is why
    // there is no test for it. It stays because the two functions should not
    // have to be read differently.
    if (p.uuid.isEmpty()) return;
    for (int i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].uuid != p.uuid) continue;
        if (m_playlists[i].title == p.title && m_playlists[i].description == p.description)
            return;   // nothing to redraw
        m_playlists[i].title       = p.title;
        m_playlists[i].description = p.description;
        // rebuild() and not rebuildTrackEntries(): the row's label is what the
        // list and every search read, and the title is part of the match key.
        rebuild();
        return;
    }
    // Not here: a playlist the sidebar has never listed. Adding it would be
    // guessing - this signal carries no artwork and no track count - and the
    // next full page of the library will bring the row in with its new name
    // anyway.
}

void LibraryIndex::refreshPlaylistMeta(const Playlist &p) {
    if (p.uuid.isEmpty()) return;
    for (int i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].uuid != p.uuid) continue;
        // mergePlaylistMeta answers false when the reply said what this already
        // knew, and then there is nothing to redraw. rebuild() collates and
        // re-tiers every row in the library and runs on every pin, play and
        // like; it is not free enough to run for a confirmation.
        if (!mergePlaylistMeta(m_playlists[i], p)) return;
        // rebuild() and not rebuildTrackEntries(), for the same reason the
        // rename path gives: this writes the row the library list draws, and one
        // of the fields is the title the search matches on.
        //
        // The row must not *move*. rebuild() orders by max(last played,
        // addedAt), and mergePlaylistMeta refuses to touch addedAt precisely so
        // that it cannot - see the note on that function about the author's
        // creation date arriving on this payload.
        rebuild();
        return;
    }
    // Not here: a playlist this list has never carried. Same answer as the
    // rename path - inventing a row out of a header is guessing at the pin
    // state and the acquisition date, and the next full page brings it in.
}

void LibraryIndex::addTrack(const Track &t) {
    if (t.id <= 0) return;
    for (const Track &x : m_favoriteTracks)
        if (x.id == t.id) return;
    m_favoriteTracks.append(t);
    // Appended, not inserted: the favourites endpoint answers oldest first and
    // the pager keeps that order, so the end of this list is the most recent
    // like - which is the Tracks chip's fallback order.
    //
    // Stamped as well, in the same map a song play writes to, because the chip
    // orders by the most recent of played or liked and those two have to meet
    // on one axis. likeIndex cannot provide it: it is a position, not an
    // instant, so it cannot say whether this like is newer than a play from an
    // hour ago. A like made here can, and this is where it is witnessed.
    // rebuildTrackEntries() below reads the stamp back out.
    m_recents.insert(QLatin1String(kKindTrack) + QLatin1Char(':') + QString::number(t.id),
                     stampNow());
    saveRecents();
    rebuildTrackEntries();
    // rebuild() because a liked song whose album is not saved now takes a row
    // of the library list as well - see rebuild(). It emits entriesChanged, so
    // the Tracks chip and every search are told in the same breath.
    rebuild();
}

void LibraryIndex::removeEntry(const QString &kind, const QString &id) {
    if (id.isEmpty()) return;

    if (kind == QLatin1String(kKindAlbum)) {
        const qint64 albumId = id.toLongLong();
        for (int i = 0; i < m_albums.size(); ++i) {
            if (m_albums[i].id != albumId) continue;
            m_albums.removeAt(i);
            // Its songs go with it. rebuildTrackEntries() now skips a cached
            // tracklist whose album is no longer saved, so the cache entry is
            // left where it is - that is where the disk prune reads it from,
            // and re-saving the album needs no second round trip.
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
    } else if (kind == QLatin1String(kKindTrack)) {
        const qint64 trackId = id.toLongLong();
        for (int i = 0; i < m_favoriteTracks.size(); ++i) {
            if (m_favoriteTracks[i].id != trackId) continue;
            m_favoriteTracks.removeAt(i);
            rebuildTrackEntries();
            // Unliking a song whose album is still saved leaves it in the index
            // - the album's tracklist holds it - so this only forgets the play
            // time of a song that has actually gone.
            pruneSongPlays();
            // rebuild() as in addTrack: unliking a song whose album is not
            // saved also takes its row out of the library list.
            rebuild();
            return;
        }
    }
}

// ── recently played, kept locally (S4) ──────────────────────────────────────

void LibraryIndex::markPlayed(const QString &kind, const QString &id) {
    // Only the four things the sidebar lists. A song play does not come
    // through here, and must not: this calls rebuild(), which re-sorts the
    // whole library - a thousand rows - and the library list is not allowed to
    // move because a song played. Song plays go to markTrackPlayed() instead,
    // and reach the Tracks chip alone.
    if (id.isEmpty() || !PinStore::isValidKind(kind)) return;

    m_recents.insert(kind + QLatin1Char(':') + id, stampNow());
    saveRecents();
    rebuild();
}

// The song half of the same idea, kept apart from it on purpose - see the two
// comments above, and Entry::songRecency in the header.
//
// Three things it deliberately does not do. It does not rebuild(): that is the
// hot path this separation exists to protect, and the Tracks chip reads its
// order when it is next asked for it, which is the next time the sidebar
// rebuilds its rows (every pin, like and save, and the markPlayed() of the
// album or playlist the song was started from). It does not sort anything: the
// one entry is patched in place. And it does not record a song that is not in
// the library.
void LibraryIndex::markTrackPlayed(const QString &id) {
    if (id.isEmpty()) return;

    const qint64 trackId = id.toLongLong();
    if (trackId <= 0) return;
    // Not in the library, so nothing to reorder and nothing worth keeping. The
    // user asked for this in so many words: a song played once from somebody
    // else's playlist does not appear under the chip, which is a library view
    // and not a play history. Refusing it here rather than storing it and
    // pruning it later is also what keeps the map from growing with every
    // stranger's playlist the user passes through.
    //
    // "In the library" means "in the song index", which during the first
    // background index run after a cache has been thrown away is a little
    // behind the truth: a song on a saved album whose tracklist has not been
    // pulled in yet loses that one play. It corrects itself on the next one,
    // and the alternative - storing it and deciding later - is the unbounded
    // version of this map.
    if (!m_trackIds.contains(trackId)) return;

    const qint64 stamp = stampNow();
    m_recents.insert(QLatin1String(kKindTrack) + QLatin1Char(':') + id, stamp);
    saveRecents();

    // One pass over the song index to patch the one row, rather than calling
    // rebuildTrackEntries(): that re-folds and re-collates every title in the
    // library, and this runs once per song played.
    for (Entry &e : m_trackEntries) {
        if (e.id != id) continue;
        e.songRecency = stamp;
        return;
    }
}

// A timestamp for something the user has just done - played it, saved it or
// followed it - guaranteed to be strictly later than every play and every save
// already recorded.
//
// The clock on its own is not enough. Two actions inside the same millisecond
// would tie, the tie-break below a pin is the title, and so playing a track and
// then saving an album could leave the album second - the exact failure the
// ordering exists to prevent. markPlayed() has always nudged past the play times
// for this reason; it has to clear the save dates too, now that the two are one
// axis, which is also what makes "(re)saving puts it at the top with the same
// priority as playing" true rather than true most of the time.
//
// Linear in the number of things recorded. That used to be the library alone, a
// thousand or so; song plays share the map now, so it is that plus the songs
// this account has played - still bounded by the library (pruneSongPlays), and
// still a hash walk per user action, which is microseconds. The alternative, a
// stored high-water mark, would be a second thing to keep correct for no
// measurable gain.
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

// The bound on what a song play can store. A song's play time is read by one
// thing, the Tracks chip, and the chip lists the library's songs - so there is
// no reason to remember one for a song that is no longer in the library. With
// markTrackPlayed() refusing songs that were never in it, that makes the map
// grow with the library rather than with how much the user listens, which is
// the same size the song index is already carrying.
//
// Called only where "in the library" is settled: when a load finishes, and when
// the user unlikes a song or unsaves an album. Not from rebuildTrackEntries(),
// which also runs at sign-in with the disk cache alone and no favourites yet,
// and would take every liked song's play time with it.
//
// The four library kinds are left alone. That list is a thousand rows at most,
// it has never needed a bound, and an album unsaved on the phone is something
// the user may well save again - its place in the order is worth keeping.
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

// ── the lazy album tracklist index (S6) ─────────────────────────────────────

void LibraryIndex::rebuildTrackEntries() {
    m_trackEntries.clear();
    m_trackIds.clear();

    // Liked songs first: they are already cached, so they are what answers a
    // search during the very first seconds, and they are the better record of
    // a song (the favourite carries its own album).
    for (qsizetype i = 0; i < m_favoriteTracks.size(); ++i) {
        const Track &t = m_favoriteTracks.at(i);
        if (m_trackIds.contains(t.id)) continue;
        m_trackIds.insert(t.id);
        Entry e = entryFor(t, 0);
        e.liked     = true;
        e.likeIndex = int(i);
        // Computed here, once per song, and not in entriesForKinds's
        // comparator: the chip sorts tens of thousands of rows, and this is the
        // same reason rebuild() precomputes Entry::recency.
        e.songRecency = m_recents.value(e.key(), 0);
        m_trackEntries.append(e);
    }

    QSet<qint64> stillSaved;
    for (const Album &a : m_albums) stillSaved.insert(a.id);

    for (auto it = m_albumTrackCache.constBegin(); it != m_albumTrackCache.constEnd(); ++it) {
        // Unsaving an album takes its songs out of the index with it. This used
        // to walk the whole cache whatever m_albums said, and the cache itself
        // was pruned only when a full index run finished, so an album the user
        // had just removed went on answering searches for the rest of the
        // session.
        //
        // The emptiness guard is saveTrackCache()'s, for the same reason: the
        // cache is read off disk at sign-in, before the album list has been
        // paged in, and with no album list yet nothing is "no longer saved".
        // Pruning there would leave the index empty on every launch and make
        // the disk cache worthless.
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

void LibraryIndex::indexOneAlbum(qint64 albumId) {
    if (albumId <= 0) return;

    int declared = 0;
    bool saved = false;
    for (const Album &a : m_albums)
        if (a.id == albumId) { declared = a.numTracks; saved = true; break; }
    if (!saved) return;

    // Already current, from the disk cache or from an earlier save this
    // session. Same staleness test startTrackIndex() uses: the album's own
    // track count moving is the cheapest signal the cached list is wrong.
    const auto cached = m_albumTrackCache.constFind(albumId);
    if (cached != m_albumTrackCache.constEnd() && cached->numTracks == declared) {
        // It was in the cache but filtered out of the index while the album was
        // unsaved, so the entries have to be built again before it is findable.
        const qsizetype was = m_trackEntries.size();
        rebuildTrackEntries();
        if (m_trackEntries.size() != was) emit entriesChanged();
        return;
    }

    // Deliberately not ++m_indexGen: see the header. A run already in flight
    // keeps its generation and its queue, and this reply is thrown away by
    // exactly the events that should throw it away.
    const int gen = m_indexGen;
    fetchAlbumTracklist(albumId, [this, gen, albumId](QList<Track> tracks, QString err) {
        if (gen != m_indexGen) return;
        if (!err.isEmpty()) return;
        const qsizetype was = m_trackEntries.size();
        indexAlbum(albumId, tracks);
        // Written out now rather than at the end of the next run, so the
        // tracklist is not re-fetched on the next launch. A run in progress
        // will write again when it finishes; the file is replaced atomically.
        saveTrackCache();
        // Only when the index actually grew. An album whose songs were all
        // liked already, or that has no tracklist to speak of, is no news for
        // the sidebar, and addAlbum's own emit has already gone out.
        if (m_trackEntries.size() != was) emit entriesChanged();
    });
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

// ── search (S5, S6) ─────────────────────────────────────────────────────────

QVariantList LibraryIndex::entriesForKinds(const QStringList &kinds) const {
    if (kinds.isEmpty()) return m_entries;

    const bool wantsTracks = kinds.contains(QLatin1String(kKindTrack));

    QList<const Entry *> picked;
    for (const Entry &e : m_library)
        if (kinds.contains(e.kind)) picked.append(&e);

    // Songs get a tier to themselves, below the two the library kinds use.
    // They carry neither a pin index nor a date added - nothing pins a song,
    // and the favourites row a song arrives in is not read this far - so they
    // have no business among the dated rows, and thousands of them mixed in
    // would push the albums and playlists that *do* have an ordering out of
    // sight. That part has not changed.
    //
    // The order *within* their tier is the rule the rest of the sidebar
    // follows: the most recent of played or liked, newest first. It was A-Z
    // once, and then liked-first; "isn't the sidebar with song filter pill
    // selected supposed to show all the latest played songs?" is what moved it
    // here. Same songs, same tier, one more signal.
    //
    // The two signals do not arrive in the same form, and that is a constraint,
    // not an oversight. Tidal exposes no cross-device play history at all, so a
    // play is only ever something this app watched, with a real instant on it
    // (Entry::songRecency). A like has no date that reaches here; the
    // favourites endpoint gives an order, and likeIndex is a song's position in
    // it. So a like made in this app is stamped like a play - see addTrack -
    // and everything else falls back to likeIndex.
    //
    // What that costs: a song liked on the phone and never played here ranks
    // below a song played here long ago, because the phone like has no instant
    // to beat it with. Nothing in the API can fix that. What it buys is that
    // the chip answers "what have I been listening to" from the first play,
    // and that an account's whole backlog of likes keeps exactly the order it
    // had before, since none of it carries a stamp.
    //
    // A song found on a saved album's tracklist, never played and never liked,
    // has neither signal (likeIndex -1) and goes after the liked ones, by
    // title, which is also the order it was in before.
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
    // found through its artist's name and an artist does not drag their work
    // in behind them: that was S7, and the user withdrew it after seeing the
    // rows it produced. docs/SPEC-0.4.0.md says so under S7.
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
        // Two results the ranking cannot separate: the one played more
        // recently first, then A-Z, so the order never depends on the order
        // the library happened to be fetched in.
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
