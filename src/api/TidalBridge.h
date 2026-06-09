#pragma once
#include <QObject>
#include <QJSValue>
#include <QQmlEngine>
#include <QSet>
#include "TidalClient.h"

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

private:
    void call(QJSValue &cb, const QJSValueList &args);
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

    QList<Track>    m_favoriteTracks;
    QList<Album>    m_favoriteAlbums;
    QList<Artist>   m_favoriteArtists;
    QList<Playlist> m_favoritePlaylists;
};
