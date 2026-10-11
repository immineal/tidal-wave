// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QAbstractListModel>
#include <QStringList>
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
    // One whole `pages/mix` response: the mix the page is about, then its tracks.
    using MixPageCallback  = std::function<void(Mix, QList<Track>, QString)>;
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
    // The same request as fetchMixTracks(), delivering the MIX_HEADER beside
    // the tracks. The virtuals in this class are test seams: a fake client
    // answers them and nothing in the app overrides one.
    virtual void fetchMixPage(const QString &mixId, MixPageCallback cb);

    // My collection
    void fetchFavoriteTracks  (TracksCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteAlbums  (AlbumsCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteArtists (ArtistsCallback   cb, int limit=50, int offset=0);
    void fetchUserPlaylists   (PlaylistsCallback cb, int limit=50, int offset=0);

    // Content
    void fetchAlbumTracks  (qint64 albumId,        TracksCallback    cb);
    void fetchPlaylistTracks(const QString &uuid,  TracksCallback    cb);
    // The playlist itself: title, artwork, description, duration and type.
    // `playlists/<uuid>/tracks` answers tracks and nothing else.
    virtual void fetchPlaylist(const QString &uuid,  std::function<void(Playlist,QString)> cb);
    void fetchArtistDetail (qint64 artistId,       std::function<void(ArtistDetail,QString)> cb);
    void fetchArtistAlbums (qint64 artistId,       AlbumsCallback    cb);
    void fetchArtistTopTracks(qint64 artistId,     TracksCallback    cb);
    void fetchAlbum        (qint64 albumId,        std::function<void(Album,QString)>  cb);
    virtual void fetchTrack(qint64 trackId,        std::function<void(Track,QString)>  cb);

    // Search
    // `offset` is the row to start at, per kind.
    void search(const QString &query, SearchCb cb, int limit = 20, int offset = 0);

    // Favorites management
    void addTrackFavorite   (qint64 trackId,    std::function<void(bool)> cb);
    void removeTrackFavorite(qint64 trackId,    std::function<void(bool)> cb);
    void addAlbumFavorite    (qint64 albumId,    std::function<void(bool)> cb);
    void removeAlbumFavorite (qint64 albumId,    std::function<void(bool)> cb);
    void addArtistFavorite   (qint64 artistId,   std::function<void(bool)> cb);
    void removeArtistFavorite(qint64 artistId,   std::function<void(bool)> cb);

    // ── a mix the user saved ────────────────────────────────────────────
    // v2 PUTs with their arguments in the query string. The reply says what
    // it did, so success is checked with mixFavoriteAccepted().
    virtual void fetchFavoriteMixes(MixesCallback cb);
    virtual void addMixFavorite    (const QString &mixId, std::function<void(bool)> cb);
    virtual void removeMixFavorite (const QString &mixId, std::function<void(bool)> cb);

    // Streaming
    virtual void fetchStreamManifest(qint64 trackId, StreamCb cb);
    // Request a specific quality (e.g. HiResLossless for downloads) without
    // touching the persisted playback preference m_quality.
    void fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb);
    QNetworkReply* fetchRaw(const QUrl &url, std::function<void(QByteArray, QString)> cb);

    // Playlist management
    virtual void createPlaylist  (const QString &title, std::function<void(Playlist,QString)> cb);
    // Renames a playlist and rewrites its description in one POST. The
    // endpoint rejects a write without the etag of the version last read. The
    // success reply has no body, hence the bool.
    void editPlaylist            (const QString &uuid,  const QString &title,
                                  const QString &description, std::function<void(bool)> cb);
    virtual void addTrackToPlaylist     (const QString &uuid,  qint64 trackId, std::function<void(bool)> cb);
    virtual void removeTrackFromPlaylist (const QString &uuid,  int itemIndex,  std::function<void(bool)> cb);

    // Track features
    void fetchTrackRadio(qint64 trackId, TracksCallback cb);
    void fetchLyrics    (qint64 trackId, std::function<void(QString, bool, QString)> cb);
    // Three GETs behind one call. See TrackCredits in Models.h.
    void fetchTrackCredits(qint64 trackId,
                           std::function<void(TrackCredits, QString /*error*/)> cb);

    // Recently played
    void fetchRecentlyPlayed(TracksCallback cb);

    // The parsers and merges below are public and static so tests can reach
    // them. They touch no member state.

    // Walks one `pages/*` feed for MIX_LIST modules. Video mixes are dropped
    // and the two personalised mixes lead.
    static QList<Mix> parseMixPage(const QJsonObject &root);

    // The mix one `pages/mix` response is about, from its MIX_HEADER module.
    // Not filtered on mixType: it labels a page that is already open.
    static Mix parseMixHeader(const QJsonObject &root);

    // Every TRACK_LIST module of one `pages/mix` response, in page order. A
    // video mix answers VIDEO_LIST and comes back empty.
    static QList<Track> parseMixTracks(const QJsonObject &root);

    // One page of v2/favorites/mixes: flat items, each with its `dateAdded`.
    // Nothing is filtered out.
    static QList<Mix> parseSavedMixes(const QJsonObject &root);

    // The `mixes` node of a search response. Video mixes are dropped by
    // `mixType`, never by title, which is localised. The rest keep the
    // server's relevance order.
    static QList<Mix> parseSearchMixes(const QJsonObject &node);

    // The cursor for the next page of v2/favorites/mixes, or "" when the run
    // is over. `previous` is the cursor this page was fetched with. The
    // endpoint reports no total, so this alone ends a run.
    static QString nextCursor(const QJsonObject &page, const QString &previous);

    // The union of several mix lists, deduplicated on the mix id. The first
    // list to carry an id fixes the position; `dateAdded` comes from whichever
    // record has one.
    static QList<Mix> mergeMixLists(const QList<QList<Mix>> &lists);

    // The union of several album lists, deduplicated on the album id. The
    // first list to carry an id fixes that release's position and supplies the
    // whole record, Album::featured included.
    static QList<Album> mergeAlbumLists(const QList<QList<Album>> &lists);

    // The `filter` values artists/<id>/albums takes. With no filter it
    // answers the albums only; EPs with singles need a request of their own.
    static constexpr auto kFilterEpsAndSingles = "EPSANDSINGLES";
    // The wire value says COMPILATIONS. The endpoint answers it with records
    // by other artists that this one appears on, and the constant is named
    // for that.
    static constexpr auto kFilterAppearsOn     = "COMPILATIONS";

    // The two sources fetchHomeMixes merges: the generated feed
    // (pages/my_collection_my_mixes) and the saved list (v2/favorites/mixes,
    // cursor-paged).
    void fetchGeneratedMixes(MixesCallback cb);
    void fetchSavedMixes    (MixesCallback cb, const QString &cursor = QString(),
                             QList<Mix> acc = {}, int page = 0);

    // ── the two favourite-mix writes, as data ───────────────────────────

    // "favorites/mixes/add" or "favorites/mixes/remove", under the v2 base.
    static QString mixFavoriteEndpoint(bool adding);

    // `mixIds=<a>,<b>&onArtifactNotFound=FAIL`. FAIL so that a mix that no
    // longer exists comes back as an error and no silent no-op.
    static QUrlQuery mixFavoriteQuery(const QStringList &mixIds);

    // Whether the reply lists `mixId` in `addedItems` or `deletedItems`.
    // Strict: a reply without the array reads as a refusal, because a refusal
    // reported as success is the worse of the two errors.
    static bool mixFavoriteAccepted(const QJsonObject &reply, const QString &mixId,
                                    bool adding);

    // The server's maximum for v2/favorites/mixes; limit=100 answers 400.
    static constexpr int kSavedMixesPageSize = 50;
    // A backstop on the cursor loop for a server that neither repeats a
    // cursor nor sends an empty page.
    static constexpr int kMaxSavedMixesPages = 50;

    // The favourites endpoints wrap each item in a row carrying the date this
    // user added it. These keep that date.
    static QList<Playlist> parsePlaylists(const QJsonObject &root);
    static QList<Album>    parseAlbums   (const QJsonObject &root);
    static QList<Artist>   parseArtists  (const QJsonObject &root);

signals:
    void error(const QString &msg);
    void userIdChanged(qint64 uid);

private:
    // Pages through `endpoint` until totalNumberOfItems is reached and
    // delivers the whole list in one callback. The API caps a response at 100
    // items whatever `limit` says.
    void fetchAllTracks(const QString &endpoint, TracksCallback cb,
                        int offset = 0, QList<Track> acc = {});

    // How far one of fetchArtistAlbums()'s requests runs: to the end of its
    // list, or one request whatever that page holds.
    enum class AlbumPages { All, First };

    // One of fetchArtistAlbums()'s three requests. An empty `filter` asks for
    // the albums. A failed page delivers what came before it and reports the
    // error only when nothing did.
    void fetchArtistAlbumPage(qint64 artistId, const QString &filter,
                              AlbumPages pages, AlbumsCallback cb,
                              int offset = 0, QList<Album> acc = {});

    // The server's page size for artists/<id>/albums.
    static constexpr int kArtistAlbumsPageSize = 50;
    // A backstop on the offset loop, per filter, for a server that claims a
    // total it never reaches.
    static constexpr int kMaxArtistAlbums = 500;

    // Daily Discovery, then New Arrivals, then the order they came in.
    static QList<Mix> orderMixes(QList<Mix> mixes);

    static QList<Track> parseTracks(const QJsonObject &root);

    static QString qualityString(AudioQuality q);

public:
    // ── which endpoint a tier's manifest comes from ──────────────────────────
    // Public and static for tst_stream_manifest.

    // True for the tiers that go to v2/trackManifests, because
    // tracks/<id>/playbackinfopostpaywall does not serve them FLAC.
    static bool usesTrackManifests(AudioQuality q);

    // The `formats` to ask the track-manifest endpoint for, one query item
    // each. The server picks the best one the track has.
    static QStringList manifestFormats(AudioQuality q);

    // Reads a v2/trackManifests body into a StreamManifest. Anything that is
    // no full-track DASH manifest (a preview, an HLS playlist) sets *err and
    // returns {}.
    static StreamManifest parseTrackManifests(const QJsonObject &root, QString *err);

private:

    TidalApi     *m_api;
    qint64        m_userId  = 0;
    AudioQuality  m_quality = AudioQuality::Lossless;
};
