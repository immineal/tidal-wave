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
    // Request a specific quality (e.g. HiResLossless for downloads) without
    // touching the persisted playback preference m_quality.
    void fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb);
    QNetworkReply* fetchRaw(const QUrl &url, std::function<void(QByteArray, QString)> cb);

    // Playlist management
    void createPlaylist          (const QString &title, std::function<void(Playlist,QString)> cb);
    void addTrackToPlaylist      (const QString &uuid,  qint64 trackId, std::function<void(bool)> cb);
    void removeTrackFromPlaylist (const QString &uuid,  int itemIndex,  std::function<void(bool)> cb);

    // Track features
    void fetchTrackRadio(qint64 trackId, TracksCallback cb);
    void fetchLyrics    (qint64 trackId, std::function<void(QString, bool, QString)> cb);
    // Who made the recording, plus the rights line, the exact release date and
    // the two identifiers. Three GETs behind one call - see TrackCredits in
    // Models.h for which one carries what.
    void fetchTrackCredits(qint64 trackId,
                           std::function<void(TrackCredits, QString /*error*/)> cb);

    // Recently played
    void fetchRecentlyPlayed(TracksCallback cb);

    // Walks one `pages/*` feed for mixes: rows, each holding modules, a module
    // of type MIX_LIST carrying them in its pagedList. Video mixes are dropped
    // and the two personalised mixes lead - see the comments on the definitions.
    //
    // Public and static only so a test can reach them, as with parsePlaylists
    // below: which mixes each source yields, in what order, and how the two are
    // reconciled is the whole of what decides what the Collection's Mixes tab
    // holds. They touch no member state.
    static QList<Mix> parseMixPage(const QJsonObject &root);

    // One page of v2/favorites/mixes - the mixes this user *saved*. Flat items,
    // each carrying its own `dateAdded`, and nothing filtered out of them.
    static QList<Mix> parseSavedMixes(const QJsonObject &root);

    // The cursor to ask for the next page of v2/favorites/mixes with, or an empty
    // string when the run is over. `previous` is the cursor this page was fetched
    // with. See the definition: the endpoint reports no total, so this is the only
    // thing that ends a run.
    static QString nextCursor(const QJsonObject &page, const QString &previous);

    // The union of several mix lists, deduplicated on the mix id. The first list
    // to carry an id fixes the position; `dateAdded` is taken from whichever
    // record has one. See the definition.
    static QList<Mix> mergeMixLists(const QList<QList<Mix>> &lists);

    // The two sources fetchHomeMixes merges. Separate so that what the Collection
    // shows is one decision in one place rather than a shape spread over the
    // class: the generated feed (pages/my_collection_my_mixes) and the saved list
    // (v2/favorites/mixes, cursor-paged).
    void fetchGeneratedMixes(MixesCallback cb);
    void fetchSavedMixes    (MixesCallback cb, const QString &cursor = QString(),
                             QList<Mix> acc = {}, int page = 0);

    // The server's maximum for v2/favorites/mixes; limit=100 answers 400.
    static constexpr int kSavedMixesPageSize = 50;
    // A backstop on the cursor loop, as LibraryIndex::maxPages is on the
    // offset-paged endpoints. nextCursor() already stops on a repeat and on an
    // empty page; this is for a server that does neither.
    static constexpr int kMaxSavedMixesPages = 50;

    // Public and static only so a test can reach them. The favourites endpoints
    // wrap each item in a row carrying the date this user added it, and whether
    // that row survives unwrapping is what decides the order of the home playlist
    // row and of the whole sidebar, so it is worth a regression test. They touch
    // no member state.
    static QList<Playlist> parsePlaylists(const QJsonObject &root);
    static QList<Album>    parseAlbums   (const QJsonObject &root);
    static QList<Artist>   parseArtists  (const QJsonObject &root);

signals:
    void error(const QString &msg);
    void userIdChanged(qint64 uid);

private:
    // Pages through `endpoint` 100 items at a time until totalNumberOfItems
    // is reached, then delivers the full accumulated list in one callback —
    // the Tidal API caps each response at 100 items regardless of `limit`.
    void fetchAllTracks(const QString &endpoint, TracksCallback cb,
                        int offset = 0, QList<Track> acc = {});

    // Daily Discovery, then New Arrivals, then the order they came in.
    static QList<Mix> orderMixes(QList<Mix> mixes);

    QList<Track>    parseTracks   (const QJsonObject &root);

    static QString qualityString(AudioQuality q);

    TidalApi     *m_api;
    qint64        m_userId  = 0;
    AudioQuality  m_quality = AudioQuality::Lossless;
};
