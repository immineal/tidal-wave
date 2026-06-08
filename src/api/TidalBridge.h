#pragma once
#include <QObject>
#include <QJSValue>
#include <QQmlEngine>
#include "TidalClient.h"

// QML-facing wrapper around TidalClient.
// All methods take QJSValue callbacks: function(data, errorString)
class TidalBridge : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the bridge context property")
public:
    explicit TidalBridge(TidalClient *client, QObject *parent = nullptr);

    void setQmlEngine(QQmlEngine *engine) { m_engine = engine; }

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

private:
    void call(QJSValue &cb, const QJSValueList &args);

    static QVariantMap  trackToMap  (const Track &t);
    static QVariantMap  albumToMap  (const Album &a);
    static QVariantMap  artistToMap (const Artist &a);
    static QVariantMap  playlistToMap(const Playlist &p);
    static QVariantMap  mixToMap    (const Mix &m);

    QVariantList tracksToList  (const QList<Track>    &v);
    QVariantList albumsToList  (const QList<Album>    &v);
    QVariantList artistsToList (const QList<Artist>   &v);
    QVariantList playlistsList (const QList<Playlist> &v);
    QVariantList mixesList     (const QList<Mix>      &v);

    TidalClient  *m_client;
    QQmlEngine   *m_engine = nullptr;
};
