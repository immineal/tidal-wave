#pragma once
#include <QObject>
#include <QJSValue>
#include <QQmlEngine>
#include <QList>
#include <QSet>
#include <QVariantMap>
#include <QStringList>
#include "TidalClient.h"

// Orders playlists by how recently the user last had anything to do with them:
// the key is max(local last-played time, Playlist::addedAt), descending. One key
// for every playlist, no tiers. Before this the key was the play time alone, so
// a playlist the user had just created sorted behind every playlist they had
// ever played; counting the date it entered their account puts a new or
// newly-saved playlist at the front exactly as playing one does.
//
// `playtimes` maps playlist uuid to ms since epoch, the shape TidalBridge keeps
// in QSettings under user_<id>/playlists/lastPlayed. The sort is stable, so
// playlists with equal keys — typically the ones with no date at all, which sort
// last — keep the order the API returned.
//
// Free function rather than a TidalBridge member because the member needs a
// Tidal session and QSettings to find the playtimes; this takes them as an
// argument and so can be tested on its own (tests/tst_playlist_order.cpp).
void sortPlaylistsByRecency(QList<Playlist> &playlists, const QVariantMap &playtimes);

// How many past queries the search page's empty state keeps.
//
// Eight. The empty state is a centred column in the page body, and eight rows
// of a row height plus the heading and the clear-all still fit a window small
// enough to have caused the complaint this whole pass came out of - a list that
// needs scrolling to read is no longer an empty state. It is also past the
// point where a list helps: the queries a person actually repeats are the last
// two or three, and everything below that is a record of what they searched
// for, which is not a thing to keep more of than is useful.
inline constexpr int kRecentSearchCap = 8;

// `recents` with `query` moved to the front, capped at `cap`. Pure, so the same
// rule is testable without a Tidal session or QSettings - and so the test stub
// can call *this* rather than carry a second copy that could drift.
//
// Two things beyond "prepend and truncate":
//
//   * matching is case-insensitive, so retyping a query in another case moves
//     the existing row up instead of adding a near-duplicate beside it.
//   * a query that *extends* the entry in front of it replaces it. Typing one
//     word with pauses in it dispatches a search per pause - "ken", "kend",
//     "kendri", "kendrick" - and without this the list would be four rows of
//     the same search. Only against the newest entry, so an earlier short
//     query someone really does repeat is left alone.
//
// An empty or whitespace-only query changes nothing.
QStringList withRecentSearch(QStringList recents, const QString &query,
                             int cap = kRecentSearchCap);

// QML-facing wrapper around TidalClient.
// All methods take QJSValue callbacks: function(data, errorString)
class TidalBridge : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the bridge context property")
    Q_PROPERTY(QString preferredQuality READ preferredQuality WRITE setPreferredQuality NOTIFY preferredQualityChanged)
public:
    explicit TidalBridge(TidalClient *client, QObject *parent = nullptr);

    void setQmlEngine(QQmlEngine *engine) { m_engine = engine; }

    // One of "LOW", "HIGH", "LOSSLESS", "HI_RES_LOSSLESS" — persisted across launches.
    QString preferredQuality() const;
    void    setPreferredQuality(const QString &q);

    Q_INVOKABLE void fetchHomeMixes     (QJSValue cb);
    Q_INVOKABLE void fetchMixTracks     (const QString &mixId, QJSValue cb);
    // function(mix, tracks, error): the mix's own title, subtitle and artwork
    // alongside its tracks, both out of the one `pages/mix` response. MixPage
    // uses it instead of fetchMixTracks because it can be opened with nothing
    // but an id.
    Q_INVOKABLE void fetchMixPage       (const QString &mixId, QJSValue cb);

    Q_INVOKABLE void fetchFavoriteTracks  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteAlbums  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteArtists (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchUserPlaylists   (QJSValue cb, int limit = 50, int offset = 0);

    Q_INVOKABLE void fetchAlbumTracks     (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchPlaylistTracks  (const QString &uuid,    QJSValue cb);
    // The playlist itself: {uuid, title, description, numTracks, duration,
    // coverUrl, type}. Its tracks come from fetchPlaylistTracks above, which
    // carries none of this.
    Q_INVOKABLE void fetchPlaylist        (const QString &uuid,    QJSValue cb);
    Q_INVOKABLE void fetchAlbum           (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchArtistDetail    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistAlbums    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistTopTracks (qlonglong artistId,     QJSValue cb);

    // `offset` is the row to start at, per kind; the reply carries the four
    // totals beside the four lists so the caller can tell a short page from
    // the last one. See SearchPage, which pages on it.
    Q_INVOKABLE void search              (const QString &q,        QJSValue cb,
                                          int limit = 20, int offset = 0);

    // ── the queries this account has run, newest first ──────────────────
    //
    // The search field's empty state. Local to this machine and to this
    // account: nothing is sent anywhere, and no query is ever logged.
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

    Q_INVOKABLE bool isArtistFavorite    (qlonglong artistId) const;
    Q_INVOKABLE void addArtistFavorite   (qlonglong artistId, QJSValue cb);
    Q_INVOKABLE void removeArtistFavorite(qlonglong artistId, QJSValue cb);

    // Playlist management
    Q_INVOKABLE void createPlaylist         (const QString &title, QJSValue cb);
    Q_INVOKABLE void addTracksToPlaylist    (const QString &uuid, qlonglong trackId, QJSValue cb);
    Q_INVOKABLE void removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb);
    Q_INVOKABLE QVariantList getUserPlaylists() const;
    Q_INVOKABLE void markPlaylistPlayed     (const QString &uuid);

    // Track features
    Q_INVOKABLE void fetchTrackRadio(qlonglong trackId, QJSValue cb);
    Q_INVOKABLE void fetchLyrics    (qlonglong trackId, QJSValue cb);
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
    void recentSearchesChanged();

    // One favourite the user deliberately added or removed, carrying the row
    // itself. LibraryIndex - the sidebar's own, separate copy of the library -
    // is connected to these in Application, so that liking an album puts it in
    // the sidebar straight away instead of at the next sign-in.
    //
    // The four signals above cannot serve that purpose: they say only "the
    // album list moved" and they also fire once per page while the whole
    // account is being read in at startup, so the sidebar could not tell a
    // deliberate like from the bulk load, nor which row it was about.
    void favoriteAlbumAdded (const Album  &album);
    void favoriteArtistAdded(const Artist &artist);
    void favoriteTrackAdded (const Track  &track);
    // A playlist the user just created, which is the only way a playlist can
    // enter the account from in here: nothing in the interface favourites or
    // unfavourites one. Nothing in qml/ calls createPlaylist yet either, so
    // this carries the row to the sidebar for when that button lands rather
    // than fixing something a user can reach today.
    void playlistCreated(const Playlist &playlist);
    // `kind` is "album", "artist" or "track", spelled the way LibraryIndex
    // spells it.
    void favoriteRemoved(const QString &kind, const QString &id);

private:
    void call(QJSValue &cb, const QJSValueList &args);
    void sortPlaylists(QList<Playlist> &playlists) const;
    QString recentSearchesKey() const;
    void    saveRecentSearches(const QStringList &queries);
    void loadFavoriteTrackIds();
    void loadNextFavoriteTracksPage(int offset);
    void loadNextFavoriteAlbumsPage(int offset);
    void loadNextFavoriteArtistsPage(int offset);
    void loadNextUserPlaylistsPage(int offset);

    static QVariantMap  trackToMap  (const Track &t);
    static QVariantMap  albumToMap  (const Album &a);
    static QVariantMap  artistToMap (const Artist &a);
    static QVariantMap  playlistToMap(const Playlist &p);
    static QVariantMap  mixToMap    (const Mix &m);

    QVariantList tracksToList  (const QList<Track>    &v) const;
    QVariantList albumsToList  (const QList<Album>    &v) const;
    QVariantList artistsToList (const QList<Artist>   &v) const;
    QVariantList playlistsList (const QList<Playlist> &v) const;
    QVariantList mixesList     (const QList<Mix>      &v) const;

    TidalClient  *m_client;
    QQmlEngine   *m_engine = nullptr;
    QSet<qlonglong> m_favoriteTrackIds;
    // Bumped each time loadFavoriteTrackIds() restarts paging; in-flight
    // callbacks from a superseded load compare against it and bail, so two
    // overlapping load chains can't both re-append page 0 (was duplicating the
    // top liked song).
    int             m_favTracksLoadGen = 0;
    // Whether m_favoriteTracks is in its final, newest-first order. It is built
    // in the endpoint's order, which is oldest first, and turned round when the
    // last page lands - so which end a newly liked song belongs at depends on
    // this. See addTrackFavorite.
    bool            m_favTracksSettled = false;

    QList<Track>    m_favoriteTracks;
    QList<Album>    m_favoriteAlbums;
    QList<Artist>   m_favoriteArtists;
    QList<Playlist> m_favoritePlaylists;
};
