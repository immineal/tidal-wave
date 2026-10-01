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
// Ordering is pinned first, then most recently played, then A-Z for everything
// never played. "Recently played" is tracked locally for all four kinds; Tidal
// exposes no cross-device play history (users/{id}/history is 404 and
// users/{id}/activity only reports favourites added), so phone plays cannot
// contribute.
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
        // Tracks only: the user liked this one, rather than it turning up in
        // the tracklist of a saved album. Liking is a deliberate act, so it
        // counts for more when the results are ranked.
        bool    liked      = false;

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
    void indexAlbum(qint64 albumId, const QList<Tidal::Track> &tracks);

    void loadRecents();
    void saveRecents() const;
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
