// SPDX-License-Identifier: GPL-3.0-or-later

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

// The sidebar's model: every saved playlist, album, artist and mix in one flat
// list, plus the local search index over them and over songs. Order is the
// pinned block, then newest first on max(last played, date added).
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

    // Tidal caps a favourites response at 100 items whatever `limit` asks for.
    static constexpr int pageSize = 50;
    // A backstop on paging for an API that sends neither a short page nor a
    // repeated one.
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

    // Records a song play. It reaches the Tracks chip and nothing else, and
    // is ignored for a song outside the library, which keeps the stored play
    // times bounded by the library.
    Q_INVOKABLE void markTrackPlayed(const QString &id);

    // One row the user just added to their library, applied to the local
    // lists without re-paging. TidalBridge keeps a separate copy of the
    // favourites. Saving an album also indexes its tracklist.
    void addAlbum (const Tidal::Album  &a);
    void addArtist(const Tidal::Artist &a);
    void addTrack (const Tidal::Track  &t);
    // A mix the user just saved, stamped as of now. `Mix::addedAt` on the
    // payload is 0, because `pages/mix` carries no date.
    void addMix   (const Tidal::Mix    &m);
    // A playlist the user just created.
    void addPlaylist(const Tidal::Playlist &p);
    // A playlist the user just renamed. Only `uuid`, `title` and
    // `description` are read, and `addedAt` stays, so the row keeps its place.
    void updatePlaylist(const Tidal::Playlist &p);
    // A playlist that just gained or lost a track, carrying the header the
    // server answered with. Writes what mergePlaylistMeta() copies and
    // nothing else.
    void refreshPlaylistMeta(const Tidal::Playlist &p);
    // `kind` is album/artist/track/mix. Nothing in the interface unfavourites
    // a playlist.
    void removeEntry(const QString &kind, const QString &id);

    // The library list filtered by kind, with nothing typed. Empty `kinds`
    // gives what `entries` does. Songs are kept out of `entries`, so the
    // Tracks chip asks here.
    Q_INVOKABLE QVariantList entriesForKinds(const QStringList &kinds) const;

    // Filters the library by title, best match first. `kinds` is empty for
    // everything, otherwise a subset of album/playlist/artist/mix/track. A
    // row is always something whose own title matched, and carries its `score`.
    Q_INVOKABLE QVariantList search(const QString &query, const QStringList &kinds) const;

    // Stops the background tracklist index and keeps what it has, on disk as
    // well, so the next run resumes. Call it on sign-out or account switch.
    Q_INVOKABLE void cancelIndexing();

    // Saved albums whose tracklist is in the search index. Used by tests.
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
    // TidalClient; a test subclass overrides them and serves its own pages.
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
    // collated forms are computed once, here.
    struct Entry {
        QString kind;
        QString id;
        QString title;
        QString subtitle;
        QString imageUrl;
        QString playlistType;        // playlists: USER / EDITORIAL, see toRow
        QString mixType;             // mixes: DISCOVERY_MIX / TRACK_MIX / ..., see toRow
        qint64  albumId = 0;         // tracks: the saved album holding them
        int     trackCount = 0;      // albums and playlists; QML formats it,
                                     // so the count retranslates live
        QList<qint64> artistIds;     // albums and tracks: the artist page to open
        QString sortKey;             // title without a leading article
        QString foldTitle;           // case- and accent-folded, for matching
        int     pinIndex   = -1;
        qint64  lastPlayed = 0;
        // When this user added the thing, in ms since epoch. 0 for a generated
        // mix and for a song.
        qint64  addedAt    = 0;
        // max(lastPlayed, addedAt): the sidebar's ordering below the pinned
        // block. Computed once per rebuild(), outside the comparator.
        qint64  recency    = 0;
        // Tracks only: liked, as opposed to found in a saved album's
        // tracklist. Liked songs rank higher in search.
        bool    liked      = false;
        // Liked tracks only, -1 otherwise: the position in the favourites
        // list, which is oldest first, so a higher number is a newer like. It
        // covers likes made on another device.
        int     likeIndex  = -1;
        // Tracks only: the most recent of (played here, liked here), 0 when
        // this app saw neither. The Tracks chip's first sort key. Kept apart
        // from `recency` and `lastPlayed`, which a song play must not move.
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
    // One album's tracklist, fetched outside the queue. It rides the current
    // m_indexGen, so a run in progress is left alone; startTrackIndex() would
    // bump it and abandon every reply in flight.
    void indexOneAlbum(qint64 albumId);
    void indexAlbum(qint64 albumId, const QList<Tidal::Track> &tracks);

    // Now, but always later than anything already recorded, so a play and a
    // save inside one millisecond cannot tie.
    qint64 stampNow() const;

    void loadRecents();
    void saveRecents() const;
    // Drops the play times of songs that have left the library.
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
    // One row as QML reads it. `score` is zero outside a search result.
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
