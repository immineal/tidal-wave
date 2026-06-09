#pragma once
#include <QObject>
#include <QAbstractListModel>
#include "TidalApi.h"
#include "Models.h"

using namespace Tidal;

// ──────────── Generic list model ────────────
template<typename T>
class ListModel : public QAbstractListModel {
public:
    enum { ItemRole = Qt::UserRole + 1 };

    explicit ListModel(QObject *parent = nullptr)
        : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &) const override { return m_items.count(); }

    QVariant data(const QModelIndex &idx, int role) const override {
        if (!idx.isValid() || idx.row() >= m_items.count()) return {};
        if (role == ItemRole) return QVariant::fromValue(m_items[idx.row()]);
        return {};
    }

    QHash<int, QByteArray> roleNames() const override {
        return {{ItemRole, "item"}};
    }

    void setItems(const QList<T> &items) {
        beginResetModel();
        m_items = items;
        endResetModel();
    }

    void append(const T &item) {
        beginInsertRows({}, m_items.size(), m_items.size());
        m_items.append(item);
        endInsertRows();
    }

    void appendList(const QList<T> &items) {
        if (items.isEmpty()) return;
        beginInsertRows({}, m_items.size(), m_items.size() + items.size() - 1);
        m_items.append(items);
        endInsertRows();
    }

    const QList<T> &items() const { return m_items; }
    T item(int i) const { return m_items[i]; }
    int count() const { return m_items.count(); }
    void clear() { setItems({}); }

private:
    QList<T> m_items;
};

// ──────────── High-level API client ────────────
class TidalClient : public QObject {
    Q_OBJECT
public:
    using TracksCallback   = std::function<void(QList<Track>,   QString)>;
    using AlbumsCallback   = std::function<void(QList<Album>,   QString)>;
    using ArtistsCallback  = std::function<void(QList<Artist>,  QString)>;
    using PlaylistsCallback= std::function<void(QList<Playlist>,QString)>;
    using MixesCallback    = std::function<void(QList<Mix>,     QString)>;
    using SearchCb         = std::function<void(SearchResults,  QString)>;
    using StreamCb         = std::function<void(StreamManifest, QString)>;

    explicit TidalClient(TidalApi *api, QObject *parent = nullptr);

    void setUserId(qint64 uid)        { if (m_userId != uid) { m_userId = uid; emit userIdChanged(uid); } }
    qint64 userId() const             { return m_userId; }
    void setAudioQuality(AudioQuality q) { m_quality = q; }
    AudioQuality audioQuality() const { return m_quality; }

    // Home page feeds
    void fetchHomeMixes   (MixesCallback cb);
    void fetchMixTracks   (const QString &mixId, TracksCallback cb);

    // My collection
    void fetchFavoriteTracks  (TracksCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteAlbums  (AlbumsCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteArtists (ArtistsCallback   cb, int limit=50, int offset=0);
    void fetchUserPlaylists   (PlaylistsCallback cb, int limit=50, int offset=0);

    // Content
    void fetchAlbumTracks  (qint64 albumId,        TracksCallback    cb);
    void fetchPlaylistTracks(const QString &uuid,  TracksCallback    cb);
    void fetchArtistDetail (qint64 artistId,       std::function<void(ArtistDetail,QString)> cb);
    void fetchArtistAlbums (qint64 artistId,       AlbumsCallback    cb);
    void fetchArtistTopTracks(qint64 artistId,     TracksCallback    cb);
    void fetchAlbum        (qint64 albumId,        std::function<void(Album,QString)>  cb);
    void fetchTrack        (qint64 trackId,        std::function<void(Track,QString)>  cb);

    // Search
    void search(const QString &query, SearchCb cb, int limit = 20);

    // Favorites management
    void addTrackFavorite   (qint64 trackId,    std::function<void(bool)> cb);
    void removeTrackFavorite(qint64 trackId,    std::function<void(bool)> cb);
    void addAlbumFavorite    (qint64 albumId,    std::function<void(bool)> cb);
    void removeAlbumFavorite (qint64 albumId,    std::function<void(bool)> cb);
    void addArtistFavorite   (qint64 artistId,   std::function<void(bool)> cb);
    void removeArtistFavorite(qint64 artistId,   std::function<void(bool)> cb);

    // Streaming
    void fetchStreamManifest(qint64 trackId, StreamCb cb);
    QNetworkReply* fetchRaw(const QUrl &url, std::function<void(QByteArray, QString)> cb);

    // Playlist management
    void createPlaylist          (const QString &title, std::function<void(Playlist,QString)> cb);
    void addTrackToPlaylist      (const QString &uuid,  qint64 trackId, std::function<void(bool)> cb);
    void removeTrackFromPlaylist (const QString &uuid,  int itemIndex,  std::function<void(bool)> cb);

    // Track features
    void fetchTrackRadio(qint64 trackId, TracksCallback cb);
    void fetchLyrics    (qint64 trackId, std::function<void(QString, bool, QString)> cb);

    // Recently played
    void fetchRecentlyPlayed(TracksCallback cb);

signals:
    void error(const QString &msg);
    void userIdChanged(qint64 uid);

private:
    // Pages through `endpoint` 100 items at a time until totalNumberOfItems
    // is reached, then delivers the full accumulated list in one callback —
    // the Tidal API caps each response at 100 items regardless of `limit`.
    void fetchAllTracks(const QString &endpoint, TracksCallback cb,
                        int offset = 0, QList<Track> acc = {});

    QList<Track>    parseTracks   (const QJsonObject &root);
    QList<Album>    parseAlbums   (const QJsonObject &root);
    QList<Artist>   parseArtists  (const QJsonObject &root);
    QList<Playlist> parsePlaylists(const QJsonObject &root);

    QString qualityString() const;

    TidalApi     *m_api;
    qint64        m_userId  = 0;
    AudioQuality  m_quality = AudioQuality::Lossless;
};
