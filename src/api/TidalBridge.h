#pragma once
#include <QObject>
#include <QJSValue>
#include <QQmlEngine>
#include <QList>
#include <QSet>
#include <QVariantMap>
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

    Q_INVOKABLE void fetchFavoriteTracks  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteAlbums  (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchFavoriteArtists (QJSValue cb, int limit = 50, int offset = 0);
    Q_INVOKABLE void fetchUserPlaylists   (QJSValue cb, int limit = 50, int offset = 0);

    Q_INVOKABLE void fetchAlbumTracks     (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchPlaylistTracks  (const QString &uuid,    QJSValue cb);
    Q_INVOKABLE void fetchAlbum           (qlonglong albumId,      QJSValue cb);
    Q_INVOKABLE void fetchArtistDetail    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistAlbums    (qlonglong artistId,     QJSValue cb);
    Q_INVOKABLE void fetchArtistTopTracks (qlonglong artistId,     QJSValue cb);

    Q_INVOKABLE void search              (const QString &q,        QJSValue cb, int limit = 20);
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
    // `kind` is "album", "artist" or "track", spelled the way LibraryIndex
    // spells it.
    void favoriteRemoved(const QString &kind, const QString &id);

private:
    void call(QJSValue &cb, const QJSValueList &args);
    void sortPlaylists(QList<Playlist> &playlists) const;
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

    QList<Track>    m_favoriteTracks;
    QList<Album>    m_favoriteAlbums;
    QList<Artist>   m_favoriteArtists;
    QList<Playlist> m_favoritePlaylists;
};
