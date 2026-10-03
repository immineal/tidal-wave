#pragma once
#include <QObject>
#include <QHash>
#include <QList>
#include <QQmlEngine>
#include <QSet>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

#include "Models.h"

class TidalClient;
class TidalBridge;
class PinStore;

// The sidebar's model: every playlist, album, artist and mix the user saved, in
// one flat list, plus the local search index over them.
//
// Ordering is the pinned block, in pin order, and then one list - no divider, no
// groups, no A-Z tier - sorted newest first on the most recent of (last played,
// date added). The user asked for exactly that: "it makes more sense to just
// sort everything by when it was added. Instead of A to Z", and "playing from
// something and (re)saving it should both just put it at the top with the same
// priority". So the two are one signal on one timestamp: re-saving an old album
// lifts it exactly as playing it would, and nothing resets on a restart.
//
// Play times are tracked locally for all four kinds, because Tidal exposes no
// cross-device play history (users/{id}/history is 404 and users/{id}/activity
// only reports favourites added), so phone plays cannot contribute. The date
// added comes from the favourites rows on every sign-in, which is what makes the
// order reproducible across launches rather than only for this session.
//
// A mix the user saved carries its own date (v2/favorites/mixes reports
// `dateAdded` per item) and ranks with everything else. One that Tidal merely
// generated has no date - nobody added it, and Tidal regenerates the set - so it
// files at the end of the list, by title, until it is played or pinned.
//
// Search covers songs as well as the four library kinds. Liked songs come down
// with the rest of the library, so they answer at once; the tracklists of saved
// albums are pulled in one album at a time in the background and cached to
// disk, and a search run while that is half finished answers from whatever is
// indexed so far. Artist top tracks are deliberately not indexed.
//
// A result is always something whose own title the user typed. Spec S7 had an
// artist hit also listing that artist's albums and songs, and a song hit also
// listing its album; the user could not tell those rows from real hits and
// withdrew the whole idea. Do not put it back without asking.
//
// Everything this class fetches goes through the protected virtuals below, so
// the tests can drive it with no network and no Tidal session.
class LibraryIndex : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the library context property")
    Q_PROPERTY(QVariantList entries READ entries NOTIFY entriesChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool indexing READ indexing NOTIFY indexingChanged)
public:
    explicit LibraryIndex(TidalClient *client, PinStore *pins, QObject *parent = nullptr);
    ~LibraryIndex() override;

    // Tidal caps a favourites response at 100 items whatever `limit` asks for;
    // 50 keeps each round trip small enough that the first page paints fast.
    static constexpr int pageSize = 50;
    // A hard stop on paging. Short pages and repeated pages already end a run;
    // this is the backstop for an API that does neither.
    static constexpr int maxPages = 100;

    QVariantList entries() const;
    bool loading() const;
    bool indexing() const;

    void setUserId(qint64 uid);
    qint64 userId() const { return m_userId; }

    // Pages the whole library in, then starts the background tracklist index.
    // Calling it again supersedes a run already in flight.
    Q_INVOKABLE void refresh();

    // Records a play so the entry floats to the top of the library list.
    Q_INVOKABLE void markPlayed(const QString &kind, const QString &id);

    // Records that a song was played. Deliberately a second door rather than a
    // kind markPlayed() accepts: a song play must reach the Tracks chip and
    // nothing else. See markPlayed() and entriesForKinds() in the .cpp.
    //
    // Ignored for a song that is not in the library. The chip lists the
    // library's songs, not a play history, so a song played once from somebody
    // else's playlist has nothing to float to the top of - and not recording it
    // is what keeps the stored play times bounded by the library.
    Q_INVOKABLE void markTrackPlayed(const QString &id);

    // One row the user just added to, or removed from, their library.
    //
    // The sidebar is a *second* copy of the account's favourites - TidalBridge
    // keeps the first, and the two page the same four endpoints independently -
    // so liking an album only ever reached the bridge: the album page's Save
    // button flipped to "Saved" and the sidebar went on showing the list it had
    // fetched at sign-in. These are how the one row gets across.
    //
    // Applied to the local lists rather than by re-paging the endpoint, for the
    // same reason TidalBridge appends rather than re-reading: the row is already
    // in hand, and a re-page would both cost a round trip and have to trust the
    // favourites list to already reflect a POST that has only just been
    // acknowledged.
    // Saving an album also pulls its tracklist into the search index, one
    // album, without disturbing a background index run already going.
    void addAlbum (const Tidal::Album  &a);
    void addArtist(const Tidal::Artist &a);
    void addTrack (const Tidal::Track  &t);
    // A playlist the user just created. Creating is the only way a playlist
    // enters the account from here - there is no favourite action for
    // playlists anywhere in the interface - and TidalBridge::createPlaylist
    // reached neither its own list nor this one, so a new playlist would have
    // been missing from the sidebar until the next launch.
    void addPlaylist(const Tidal::Playlist &p);
    // `kind` is album/artist/track; mixes and playlists cannot be unfavourited
    // from anywhere in the interface.
    void removeEntry(const QString &kind, const QString &id);

    // The library list filtered by kind, with nothing typed. `kinds` empty gives
    // the same thing the `entries` property does.
    //
    // This exists because `entries` holds the four *browsable* kinds and songs
    // are kept out of it on purpose - a library has thousands of them and they
    // would bury everything else. The finder's Tracks chip was therefore
    // filtering a list that has no tracks in it and showing "Nothing saved yet",
    // while the same chip worked the moment anything was typed, because search()
    // does visit the track entries. Asking for a kind explicitly is a different
    // request from browsing, so this answers it and the property stays as it is.
    Q_INVOKABLE QVariantList entriesForKinds(const QStringList &kinds) const;

    // Filters the library by title. `kinds` is an empty list for everything,
    // otherwise a subset of album/playlist/artist/mix/track. Rows come back
    // best match first; the ranking is described above `matchScore` in the
    // .cpp, and each row carries the `score` it was ordered by.
    Q_INVOKABLE QVariantList search(const QString &query, const QStringList &kinds) const;

    // Stops the background tracklist index where it stands and keeps what it
    // already has, on disk as well, so the next run resumes rather than starts
    // over. Signing out or switching account should call it.
    Q_INVOKABLE void cancelIndexing();

    // Saved albums whose tracklist is in the search index, from the disk cache
    // or from this session. The sidebar does not show it; the tests use it to
    // see how far the lazy index has got.
    Q_INVOKABLE int indexedAlbumCount() const;

signals:
    void entriesChanged();
    void loadingChanged();
    void indexingChanged();

protected:
    using TracksCb    = std::function<void(QList<Tidal::Track>,    QString)>;
    using AlbumsCb    = std::function<void(QList<Tidal::Album>,    QString)>;
    using ArtistsCb   = std::function<void(QList<Tidal::Artist>,   QString)>;
    using PlaylistsCb = std::function<void(QList<Tidal::Playlist>, QString)>;
    using MixesCb     = std::function<void(QList<Tidal::Mix>,      QString)>;

    // The only six places this class reaches the network. They forward to
    // TidalClient; a test subclass overrides them and serves its own pages,
    // which is the only way to exercise paging that has to terminate on a
    // server that keeps repeating itself.
    virtual void fetchPlaylistPage(int offset, int limit, PlaylistsCb cb);
    virtual void fetchAlbumPage   (int offset, int limit, AlbumsCb    cb);
    virtual void fetchArtistPage  (int offset, int limit, ArtistsCb   cb);
    virtual void fetchTrackPage   (int offset, int limit, TracksCb    cb);
    // Mixes come from a page feed that has no offset, so there is nothing to
    // page through.
    virtual void fetchMixList     (MixesCb cb);
    virtual void fetchAlbumTracklist(qint64 albumId, TracksCb cb);

private:
    // One row of the sidebar, or one song in the search index. The folded and
    // collated forms are computed once here rather than on every keystroke.
    struct Entry {
        QString kind;
        QString id;
        QString title;
        QString subtitle;
        QString imageUrl;
        QString playlistType;        // playlists: USER / EDITORIAL, see toRow
        qint64  albumId = 0;         // tracks: the saved album holding them
        int     trackCount = 0;      // albums and playlists; QML formats it,
                                     // so the count retranslates live
        QList<qint64> artistIds;     // albums and tracks: the artist page to open
        QString sortKey;             // title without a leading article
        QString foldTitle;           // case- and accent-folded, for matching
        int     pinIndex   = -1;
        qint64  lastPlayed = 0;
        // When this user added the thing to their library, in ms since epoch,
        // from the `created` on the favourites row it arrived in, or a saved
        // mix's own `dateAdded`. 0 for a generated mix (nobody added it) and for
        // a song (the favourites row is not carried that far - see likeIndex
        // below, which is the record songs do have).
        qint64  addedAt    = 0;
        // max(lastPlayed, addedAt): the whole of the sidebar's ordering below
        // the pinned block. Computed once per rebuild() rather than inside the
        // comparator, because a library runs to a thousand rows and rebuild()
        // runs on every pin, play and like.
        qint64  recency    = 0;
        // Tracks only: the user liked this one, rather than it turning up in
        // the tracklist of a saved album. Liking is a deliberate act, so it
        // counts for more when the results are ranked.
        bool    liked      = false;
        // Liked tracks only, -1 otherwise: where this song sits in the
        // favourites list. The endpoint answers order=DATE oldest first and the
        // pager keeps that order, so a higher number is a more recent like.
        // That is the only record of when a song was liked that reaches this
        // far, and it covers likes made on another device - which is why it is
        // still the Tracks chip's order for every song this app has not seen
        // happen to, under songRecency below.
        int     likeIndex  = -1;
        // Tracks only: the most recent of (played here, liked here), in ms
        // since epoch, 0 when this app has witnessed neither. The Tracks chip's
        // first sort key; see entriesForKinds().
        //
        // Deliberately not `recency`, and deliberately not `lastPlayed`. Those
        // two order the library list, which must not move because a song
        // played: rebuild() sorts a thousand rows and runs on every pin, play
        // and like. `lastPlayed` is also what search() reads for its
        // familiarity bonus, and a song play is not meant to re-rank search
        // results either. So this is a third field rather than a reuse, and the
        // separation is the point.
        //
        // The two halves are not the same kind of fact and cannot be. A play
        // happened at a known instant, because this app watched it; a like has
        // only an order, because Tidal exposes no date per favourite that
        // reaches here - which is why a like made in this app is stamped where
        // it happens (addTrack) and a like made on the phone falls back to
        // likeIndex.
        qint64  songRecency = 0;

        QString key() const { return kind + QLatin1Char(':') + id; }
    };

    struct CachedAlbum {
        int numTracks = 0;           // as the album declared it when indexed
        QList<Entry> tracks;
    };

    void rebuild();
    void rebuildTrackEntries();
    void setLoading(bool v);
    void setIndexing(bool v);
    void partFinished(int gen);

    void startTrackIndex();
    void stepTrackIndex(int gen);
    // One album's tracklist, fetched on its own rather than through the queue.
    // startTrackIndex() is the wrong tool for a single album: it bumps
    // m_indexGen and rebuilds the queue, which abandons every reply a run
    // already has in flight and asks for those albums again. This rides the
    // generation that is current instead, so a sign-out, an account switch or a
    // fresh refresh still discards the reply, and a run in progress is left
    // exactly as it was.
    void indexOneAlbum(qint64 albumId);
    void indexAlbum(qint64 albumId, const QList<Tidal::Track> &tracks);

    // "Now", but never equal to or behind anything already recorded. See the
    // definition: a play and a save inside one millisecond would otherwise tie.
    qint64 stampNow() const;

    void loadRecents();
    void saveRecents() const;
    // Drops the play times of songs that have left the library. See the .cpp:
    // this is the bound on how much a song play can ever store.
    void pruneSongPlays();
    void loadTrackCache();
    void saveTrackCache() const;
    QString trackCachePath() const;

    static Entry entryFor(const Tidal::Playlist &p);
    static Entry entryFor(const Tidal::Album &a);
    static Entry entryFor(const Tidal::Artist &a);
    static Entry entryFor(const Tidal::Mix &m);
    static Entry entryFor(const Tidal::Track &t, qint64 albumId);
    static void  finishEntry(Entry &e);
    // One row as QML reads it. `score` is only meaningful in a search result;
    // the plain library list leaves it at zero.
    static QVariantMap toRow(const Entry &e, int score);

    TidalClient *m_client = nullptr;
    PinStore    *m_pins   = nullptr;
    qint64       m_userId = 0;

    QList<Tidal::Playlist> m_playlists;
    QList<Tidal::Album>    m_albums;
    QList<Tidal::Artist>   m_artists;
    QList<Tidal::Mix>      m_mixes;
    QList<Tidal::Track>    m_favoriteTracks;

    QList<Entry>  m_library;        // the four kinds, already in sidebar order
    QVariantList  m_entries;        // m_library as QML sees it
    QList<Entry>  m_trackEntries;   // songs, search only
    QSet<qint64>  m_trackIds;       // what is already in m_trackEntries

    QHash<QString, qint64> m_recents;            // "kind:id" to ms since epoch
    QHash<qint64, CachedAlbum> m_albumTrackCache;

    QList<qint64> m_indexQueue;
    bool m_loading   = false;
    bool m_indexing  = false;
    // Bumped on every refresh and every cancel. A reply from a superseded run
    // compares against it and bails, so two overlapping runs cannot both write
    // into the index.
    int  m_loadGen   = 0;
    int  m_indexGen  = 0;
    int  m_pending   = 0;
};
