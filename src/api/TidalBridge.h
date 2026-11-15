// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QJSValue>
#include <QQmlEngine>
#include <QList>
#include <QSet>
#include <QVariantMap>
#include <QStringList>
#include "TidalClient.h"

class LyricsFinder;
namespace lyricsync { class AutoSync; }

// Sorts by max(local last-played time, Playlist::addedAt), descending.
// `playtimes` maps playlist uuid to ms since epoch. Stable, so playlists with
// equal keys keep the order the API returned.
void sortPlaylistsByRecency(QList<Playlist> &playlists, const QVariantMap &playtimes);

// How many past queries the search page's empty state keeps. The list has to
// fit a small window without scrolling.
inline constexpr int kRecentSearchCap = 8;

// `recents` with `query` moved to the front, capped at `cap`. Matching is
// case-insensitive, and a query that extends the newest entry replaces it. An
// empty or whitespace-only query changes nothing.
QStringList withRecentSearch(QStringList recents, const QString &query,
                             int cap = kRecentSearchCap);

// QML-facing wrapper around TidalClient.
// All methods take QJSValue callbacks: function(data, errorString)
class TidalBridge : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the bridge context property")
    Q_PROPERTY(QString preferredQuality READ preferredQuality WRITE setPreferredQuality NOTIFY preferredQualityChanged)
    // True until the newest liked songs have arrived after a sign-in.
    Q_PROPERTY(bool favoritesLoading READ favoritesLoading NOTIFY favoriteTracksChanged)
    // The other three sign-in lists, each true until its own reply is in, the
    // playlists until their last page. An empty list before then is not empty.
    Q_PROPERTY(bool albumsLoading    READ albumsLoading    NOTIFY favoriteAlbumsChanged)
    Q_PROPERTY(bool artistsLoading   READ artistsLoading   NOTIFY favoriteArtistsChanged)
    Q_PROPERTY(bool playlistsLoading READ playlistsLoading NOTIFY favoritePlaylistsChanged)
public:
    explicit TidalBridge(TidalClient *client, QObject *parent = nullptr);

    void setQmlEngine(QQmlEngine *engine) { m_engine = engine; }

    // One of "LOW", "HIGH", "LOSSLESS", "HI_RES_LOSSLESS". Persisted across launches.
    QString preferredQuality() const;
    void    setPreferredQuality(const QString &q);

    Q_INVOKABLE void fetchHomeMixes     (QJSValue cb);
    Q_INVOKABLE void fetchMixTracks     (const QString &mixId, QJSValue cb);
    // function(mix, tracks, error): the mix's header beside its tracks, for a
    // page opened with nothing but an id.
    Q_INVOKABLE void fetchMixPage      (const QString &mixId, QJSValue cb);

    bool favoritesLoading() const { return m_favoritesLoading; }
    bool albumsLoading()    const { return m_albumsLoading; }
    bool artistsLoading()   const { return m_artistsLoading; }
    bool playlistsLoading() const { return m_playlistsLoading; }

    // Tidal tells a client nothing about changes made on another device. This
    // asks one small request per list and reloads the lists that moved.
    void syncFavorites();

    Q_INVOKABLE void fetchFavoriteTracks  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteAlbums  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteArtists (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchUserPlaylists   (QJSValue cb, int limit = 50, int offset = 0);

    Q_INVOKABLE void fetchAlbumTracks     (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchPlaylistTracks  (const QString &uuid,    QJSValue cb);
    // The playlist itself: {uuid, title, description, numTracks, duration,
    // coverUrl, type}.
    Q_INVOKABLE void fetchPlaylist       (const QString &uuid,    QJSValue cb);
    Q_INVOKABLE void fetchAlbum           (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchArtistDetail    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistAlbums    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistTopTracks (qlonglong artistId,     QJSValue cb);
    // function(albums, error): the other versions of the album's record, as
    // album maps. An empty list where Tidal names none.
    Q_INVOKABLE void fetchAlbumOtherVersions(qlonglong albumId,    QJSValue cb);

    // `offset` is the row to start at, per kind. The reply carries a total
    // beside each list, so the caller can tell a short page from the last one.
    Q_INVOKABLE void search              (const QString &q,        QJSValue cb,
                                          int limit = 20, int offset = 0);

    // ── the queries this account has run, newest first ──────────────────
    // Kept in local settings per account. Nothing is sent or logged.
    Q_INVOKABLE QStringList recentSearches() const;
    Q_INVOKABLE void addRecentSearch   (const QString &q);
    Q_INVOKABLE void removeRecentSearch(const QString &q);
    Q_INVOKABLE void clearRecentSearches();
    Q_INVOKABLE void copyToClipboard     (const QString &text);

    Q_INVOKABLE bool isTrackFavorite     (qlonglong trackId)  const;
    Q_INVOKABLE void addTrackFavorite    (qlonglong trackId,  QJSValue cb);
    Q_INVOKABLE void removeTrackFavorite (qlonglong trackId,  QJSValue cb);

    Q_INVOKABLE bool isAlbumFavorite     (qlonglong albumId)  const;
    Q_INVOKABLE void addAlbumFavorite    (qlonglong albumId,  QJSValue cb);
    Q_INVOKABLE void removeAlbumFavorite (qlonglong albumId,  QJSValue cb);
    // The saved album by id, or an empty map. For a delisted edition
    // `albums/<id>` answers 404 while favourites still list it, so this cache
    // is the only source of its title.
    Q_INVOKABLE QVariantMap favoriteAlbumById(qlonglong albumId) const;

    Q_INVOKABLE bool isArtistFavorite    (qlonglong artistId) const;
    Q_INVOKABLE void addArtistFavorite   (qlonglong artistId, QJSValue cb);
    Q_INVOKABLE void removeArtistFavorite(qlonglong artistId, QJSValue cb);

    // ── a mix, saved and unsaved ────────────────────────────────────────
    // A mix id is a hex string. isMixFavorite() answers from the saved list
    // only: a generated mix is not saved and has no Unsave to offer.
    Q_INVOKABLE bool isMixFavorite   (const QString &mixId) const;
    Q_INVOKABLE void addMixFavorite   (const QString &mixId, QJSValue cb);
    Q_INVOKABLE void removeMixFavorite(const QString &mixId, QJSValue cb);

    // Playlist management
    Q_INVOKABLE void createPlaylist         (const QString &title, QJSValue cb);
    // Renames a playlist and rewrites its description. function(ok): the
    // reply has no body to hand back.
    Q_INVOKABLE void editPlaylist           (const QString &uuid, const QString &title,
                                             const QString &description, QJSValue cb);
    // function(ok). On success both re-read the playlist's header and merge it
    // into both caches: see refreshPlaylistMeta.
    Q_INVOKABLE void addTracksToPlaylist   (const QString &uuid, qlonglong trackId, QJSValue cb);
    // function(ok, stale, index). Removals of one playlist go out one at a
    // time, and `itemIndex` is the row as the page showed it when asked:
    // `index` is the row to take out once earlier removals have landed, -1
    // when there is none. `stale` means the playlist changed elsewhere.
    Q_INVOKABLE void removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb);
    Q_INVOKABLE QVariantList getUserPlaylists() const;
    Q_INVOKABLE void markPlaylistPlayed     (const QString &uuid);

    // Track features
    Q_INVOKABLE void fetchTrackRadio(qlonglong trackId, QJSValue cb);
    // Which mix this track's radio is: function(mixId, error), mixId "" when
    // Tidal did not name one. For a row whose listing carried no `mixes`;
    // `tracks/<id>` is the one endpoint known to carry it.
    Q_INVOKABLE void fetchTrackMix (qlonglong trackId, QJSValue cb);
    Q_INVOKABLE void fetchLyrics    (qlonglong trackId, QJSValue cb);
    // Lyrics from other sites for a track map, when the switch for it is on:
    // function({text, timed, source, url}, error), error "off" when it is off.
    Q_INVOKABLE void findLyrics     (const QVariantMap &track, QJSValue cb);
    void setLyricsFinder(LyricsFinder *f) { m_lyricsFinder = f; }
    // Times plain lyrics against the track's audio, here on this machine:
    // function({ok, kept, confidence, lrc}, error), error "off" when the
    // switch is off. A newer call drops the older one's answer.
    Q_INVOKABLE void autoSyncLyrics (qlonglong trackId, const QString &text, QJSValue cb);
    // Whether the next track's audio is analysed ahead, while lyrics are on screen.
    // Drops the auto-sync asked for, and stops its analysis unless the next track needs it.
    Q_INVOKABLE void cancelAutoSync();
    Q_INVOKABLE void setLyricsLookAhead(bool on);
    void setAutoSync(lyricsync::AutoSync *a) { m_autoSync = a; }
    // Answers { groups: [{type, contributors:[{id, name}]}], copyright, isrc,
    //           releaseDate, upc } and an error string.
    Q_INVOKABLE void fetchTrackCredits(qlonglong trackId, QJSValue cb);

    // Recently played
    Q_INVOKABLE void fetchRecentlyPlayed(QJSValue cb);

    Q_INVOKABLE QVariantList searchFavoriteTracks(const QString &query) const;
    Q_INVOKABLE QVariantList searchFavoriteAlbums(const QString &query) const;
    Q_INVOKABLE QVariantList searchFavoriteArtists(const QString &query) const;
    Q_INVOKABLE QVariantList searchFavoritePlaylists(const QString &query) const;

signals:
    void preferredQualityChanged();
    void favoriteTracksChanged();
    void favoriteAlbumsChanged();
    void favoriteArtistsChanged();
    void favoritePlaylistsChanged();
    // The saved-mix set moved, or was loaded for an account.
    void favoriteMixesChanged();
    void recentSearchesChanged();

    // One favourite the user added, carrying the row, for LibraryIndex. The
    // *Changed signals above carry no row and also fire once per page during
    // the sign-in load.
    void favoriteAlbumAdded (const Album  &album);
    void favoriteArtistAdded(const Artist &artist);
    void favoriteTrackAdded (const Track  &track);
    // A playlist the user just created, carrying the row for LibraryIndex.
    void playlistCreated(const Playlist &playlist);
    // A playlist the user just renamed. Read only `uuid`, `title` and
    // `description` off it: the receiver patches its row in place and must
    // not move or re-stamp it.
    void playlistUpdated(const Playlist &playlist);
    // A playlist whose contents just changed, carrying the header the server
    // answered with. Read only what mergePlaylistMeta() copies: `addedAt`
    // here is the author's creation date and must not be copied.
    void playlistStatsChanged(const Playlist &playlist);
    // The same event for QML, which cannot take a Tidal::Playlist.
    // favoritePlaylistsChanged is no substitute: it also fires during sign-in
    // paging and on every markPlaylistPlayed.
    void playlistStatsRefreshed(const QString &uuid);
    // A mix the user just saved, carrying the row for LibraryIndex.
    void favoriteMixAdded(const Mix &mix);
    // `kind` is "album", "artist", "track" or "mix", spelled the way
    // LibraryIndex spells it.
    void favoriteRemoved(const QString &kind, const QString &id);

    // syncFavorites() found a change made on another device. The bridge's own
    // caches and signals are already up to date.
    void favoritesChangedElsewhere();

private:
    void call(QJSValue &cb, const QJSValueList &args);
    // Re-reads one playlist's header and merges what a contents change moves
    // into both caches. `then` runs once the answer is in, whatever it was.
    void refreshPlaylistMeta(const QString &uuid, std::function<void()> then = {});
    // Sends the first removal queued for `uuid`.
    void nextRemoval(const QString &uuid);
    void sortPlaylists(QList<Playlist> &playlists) const;
    QString recentSearchesKey() const;
    void    saveRecentSearches(const QStringList &queries);
    void loadFavoriteTrackIds();
    void resetFavoriteSync();
    void favoriteChangedHere(TidalClient::FavoriteKind kind);
    void reloadFavorites(TidalClient::FavoriteKind kind, const FavoritesHead &head);
    // `paged` lists the same rows page by page, for when one page is refused.
    template <typename T, typename Fetch, typename Paged, typename KeyOf, typename Apply>
    void reloadInto(TidalClient::FavoriteKind kind, const FavoritesHead &head, int limit,
                    const QList<T> &cache, Fetch fetch, Paged paged, KeyOf keyOf,
                    Apply apply);
    // Loaded eagerly at sign-in, so MixPage knows the save state without a
    // round trip per page.
    void loadFavoriteMixIds();
    void loadFavoriteTracks();
    void loadFavoriteAlbums();
    void loadFavoriteArtists();
    void refreshLikedTrackIds();
    void applyLikedTrackIds();
    void reportPagedLikes();
    void loadNextUserPlaylistsPage(int offset);

public:
    // Public and static: the player makes a queue row out of a track, and a
    // test can reach both.
    static QVariantMap  trackToMap  (const Track &t);
    static QVariantMap  albumToMap (const Album &a);
private:
    static QVariantMap  artistToMap (const Artist &a);
    QVariantMap         playlistToMap(const Playlist &p) const;
    static QVariantMap  mixToMap    (const Mix &m);

    QVariantList tracksToList  (const QList<Track>    &v) const;
    QVariantList albumsToList  (const QList<Album>    &v) const;
    QVariantList artistsToList (const QList<Artist>   &v) const;
    QVariantList playlistsList (const QList<Playlist> &v) const;
    QVariantList mixesList     (const QList<Mix>      &v) const;

    TidalClient  *m_client;
    LyricsFinder *m_lyricsFinder = nullptr;
    lyricsync::AutoSync *m_autoSync = nullptr;
    QQmlEngine   *m_engine = nullptr;
    // The hearts: every listed song and every id favorites/ids answered.
    QSet<qlonglong> m_favoriteTrackIds;
    // The last favorites/ids answer for songs, kept in step with likes here.
    QSet<qlonglong> m_likedTrackIds;
    int             m_likedIdsGen = 0;
    bool            m_likedIdsInFlight = false;
    // The liked-songs listing on hand was paged because one page was refused.
    bool            m_tracksFellBack = false;
    // Bumped each time loadFavoriteTrackIds() restarts paging. Callbacks from
    // a superseded load compare against it and bail, so two overlapping
    // chains cannot both append page 0.
    int             m_favTracksLoadGen = 0;
    bool            m_favoritesLoading = false;
    bool            m_albumsLoading    = false;
    bool            m_artistsLoading   = false;
    bool            m_playlistsLoading = false;
    // The four sign-in paging chains still running.
    int             m_favLoadsPending = 0;

    // One per FavoriteKind. A reload lands whole or not at all, and a change
    // made here during one bumps `gen`, because its pages may predate that.
    struct FavoriteSync {
        int           gen = 0;
        bool          reloading = false;
        FavoritesHead head;     // what the list on hand was reloaded against
    };
    FavoriteSync    m_favSync[4];
    int             m_favMixesSyncGen = 0;

    // Removals not yet answered, per playlist, first one in flight. `index`
    // follows the rows earlier ones take out; `gone` is a row already taken.
    struct Removal { int index = -1; bool gone = false; QJSValue cb; };
    QHash<QString, QList<Removal>> m_removals;
    QSet<QString>   m_removing;   // a removal of it is out, or its header read

    QList<Track>    m_favoriteTracks;
    QList<Album>    m_favoriteAlbums;
    QList<Artist>   m_favoriteArtists;
    QList<Playlist> m_favoritePlaylists;
    // Ids only: all it answers is whether a mix is saved.
    QSet<QString>   m_favoriteMixIds;
    // Bumped each time loadFavoriteMixIds() starts, so a reply from a previous
    // account's load cannot fill the set after a switch.
    int             m_favMixesLoadGen = 0;
};
