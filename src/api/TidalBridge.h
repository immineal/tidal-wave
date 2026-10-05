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

    // ── a mix, saved and unsaved ────────────────────────────────────────
    //
    // The fourth kind, and the one the interface had no write for at all. A
    // track radio the user saved on another device arrived in the sidebar as a
    // mix, opened on MixPage, and could not be got rid of from anywhere in the
    // app; and "Start radio" could not put one there, because it opened a
    // second viewer with no mix identity to save.
    //
    // The id is a string, not a number: a mix id is 30 hex characters.
    //
    // isMixFavorite() answers out of m_favoriteMixIds, which holds the *saved*
    // list and not the merged one the Collection shows - a generated "My Mix 4"
    // is not saved and has no Unsave to offer. The set is loaded once per
    // sign-in, like m_favoriteTrackIds.
    Q_INVOKABLE bool isMixFavorite    (const QString &mixId) const;
    Q_INVOKABLE void addMixFavorite   (const QString &mixId, QJSValue cb);
    Q_INVOKABLE void removeMixFavorite(const QString &mixId, QJSValue cb);

    // Playlist management
    Q_INVOKABLE void createPlaylist         (const QString &title, QJSValue cb);
    // Rename a playlist and rewrite its description. function(ok) - there is
    // no body in the reply to hand back.
    //
    // PlaylistPage's Edit dialog had been writing the new title into its own
    // two properties and stopping there, so the rename was gone the moment the
    // page was left: the dialog accepted the edit, said nothing was wrong, and
    // the account never heard about it. This is what it calls instead.
    Q_INVOKABLE void editPlaylist           (const QString &uuid, const QString &title,
                                             const QString &description, QJSValue cb);
    // Put a track on a playlist, and bring the playlist's own numbers back into
    // line. function(ok).
    //
    // The second half is what was missing. Neither of these two touched a cache,
    // so a playlist the user had just filled went on reading "0 tracks"
    // everywhere the number is drawn off the cache - which the picker joined when
    // it stopped round-tripping on every open. Both now re-read the playlist's
    // header on a success and merge it into both caches; see refreshPlaylistMeta.
    Q_INVOKABLE void addTracksToPlaylist    (const QString &uuid, qlonglong trackId, QJSValue cb);
    Q_INVOKABLE void removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb);
    Q_INVOKABLE QVariantList getUserPlaylists() const;
    Q_INVOKABLE void markPlaylistPlayed     (const QString &uuid);

    // Track features
    Q_INVOKABLE void fetchTrackRadio(qlonglong trackId, QJSValue cb);
    // Which mix this track's radio is: function(mixId, error), mixId "" when
    // Tidal did not name one.
    //
    // `tracks/<id>` is the one endpoint known to carry the `mixes` object -
    // known from the reference client's recorded response, not from a call made
    // here. Whether an album's, a playlist's or a search's items carry it was
    // deliberately not found out, because finding out means reading the owner's
    // account; so a row that already has the id uses it and never calls this,
    // and a row that does not asks here before giving up on the mix viewer.
    //
    // That ordering is the whole point: without it the fix would quietly do
    // nothing for exactly the places a user presses "Start radio" from.
    Q_INVOKABLE void fetchTrackMix  (qlonglong trackId, QJSValue cb);
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
    // The saved-mix set moved: one was saved, one was unsaved, or the set was
    // (re)loaded for an account. MixPage reads its Save pill back off
    // isMixFavorite() on this, exactly as AlbumPage reads its own off
    // favoriteAlbumsChanged.
    void favoriteMixesChanged();
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
    // unfavourites one. Carries the row to the sidebar, which keeps a second
    // copy of the library that favoritePlaylistsChanged above does not reach.
    void playlistCreated(const Playlist &playlist);
    // The same hand-across for a playlist the user just renamed. Only `uuid`,
    // `title` and `description` are meant to be read off it: the far end
    // writes those two fields onto the row it already has rather than
    // replacing it, because an edit answers with no body and nothing here can
    // supply the artwork or the track count a replacement would blank out.
    //
    // A separate signal from playlistCreated, not a reuse of it, because the
    // two mean opposite things to a list: one appends a row and stamps it as
    // of now, the other must leave the row exactly where it is. A rename that
    // went through addPlaylist would be a no-op (the uuid is already there);
    // one that re-stamped would jump the playlist to the top of the sidebar
    // for having been given a new name.
    void playlistUpdated(const Playlist &playlist);
    // A playlist whose *contents* just changed, carrying the header the server
    // answered with. Raised after a track was added or removed, and consumed by
    // LibraryIndex::refreshPlaylistMeta at the far end.
    //
    // The third playlist signal rather than a reuse of playlistUpdated, because
    // that one means something narrower and would drop this on the floor: its
    // consumer writes `title` and `description` and returns early when both
    // already match, which on a track add they always do. The count would never
    // be written.
    //
    // Only the fields mergePlaylistMeta() copies are meant to be read off this -
    // in particular NOT `addedAt`, which on this payload is the playlist's own
    // creation date and not the day the user acquired it. Both ends go through
    // that one function so neither can get the exclusion wrong on its own.
    void playlistStatsChanged(const Playlist &playlist);
    // The same event, named for QML: *which* playlist's numbers just moved.
    //
    // playlistStatsChanged above cannot serve, because a QML handler cannot be
    // given a Tidal::Playlist. Nor can favoritePlaylistsChanged, and that one is
    // worth spelling out because using it would be a regression rather than
    // merely imprecise: it says only "the playlist list moved", and it also fires
    // on every page of the sign-in paging and on every markPlaylistPlayed - so a
    // page that took it as "my playlist changed" would, the moment the user
    // pressed Play, overwrite the header it had just fetched with whatever the
    // cache happened to hold. PlaylistPage reads its own length off this.
    void playlistStatsRefreshed(const QString &uuid);
    // A mix the user just saved, carrying the row, for the sidebar's own copy of
    // the library - the same hand-across favoriteAlbumAdded makes and for the
    // same reason: favoriteMixesChanged() says only "the set moved" and carries
    // no row, so LibraryIndex could not add one off it.
    void favoriteMixAdded(const Mix &mix);
    // `kind` is "album", "artist", "track" or "mix", spelled the way
    // LibraryIndex spells it.
    void favoriteRemoved(const QString &kind, const QString &id);

private:
    void call(QJSValue &cb, const QJSValueList &args);
    // Re-read one playlist's header and merge what a contents change moves into
    // both caches. See the .cpp for why this is a round trip and not arithmetic.
    void refreshPlaylistMeta(const QString &uuid);
    void sortPlaylists(QList<Playlist> &playlists) const;
    QString recentSearchesKey() const;
    void    saveRecentSearches(const QStringList &queries);
    void loadFavoriteTrackIds();
    // The saved-mix ids, in one request chain, at sign-in. Cheap enough to do
    // eagerly and necessary to do eagerly: MixPage's pill has to know the
    // state the moment the page opens, and the alternative - a fetch per page
    // open - would put a round trip in front of every mix the user looks at.
    void loadFavoriteMixIds();
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
    // Ids only: nothing in the app needs a saved mix's title out of here (the
    // Collection and the sidebar each fetch their own list), and the question
    // asked of it is only ever "is this one saved".
    QSet<QString>   m_favoriteMixIds;
    // Bumped each time loadFavoriteMixIds() starts, for the reason
    // m_favTracksLoadGen exists: a reply from a previous account's load must not
    // fill the set after a switch.
    int             m_favMixesLoadGen = 0;
};
