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
    // One whole `pages/mix` response: the mix the page is about, then its
    // tracks. Two results from one request, because that response carries both
    // and a page opened by id alone needs both - see fetchMixPage().
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
    // the tracks. fetchMixTracks() is this call with the header dropped, so a
    // caller that wants both does not pay for two round trips.
    //
    // `virtual` for the same test seam as the playlist calls below. TidalBridge
    // calls it on an accepted save, to get a row to hand the sidebar, so a test
    // of that hand-across has to be able to answer it.
    virtual void fetchMixPage(const QString &mixId, MixPageCallback cb);

    // My collection
    void fetchFavoriteTracks  (TracksCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteAlbums  (AlbumsCallback    cb, int limit=50, int offset=0);
    void fetchFavoriteArtists (ArtistsCallback   cb, int limit=50, int offset=0);
    void fetchUserPlaylists   (PlaylistsCallback cb, int limit=50, int offset=0);

    // Content
    void fetchAlbumTracks  (qint64 albumId,        TracksCallback    cb);
    void fetchPlaylistTracks(const QString &uuid,  TracksCallback    cb);
    // The playlist itself - title, artwork, description, duration and the
    // USER/EDITORIAL type. `playlists/<uuid>/tracks` answers tracks and nothing
    // else, so a page handed only a uuid has no other way to label itself.
    // Also the authoritative answer to "how long is this playlist now" after a
    // track went on or came off it; `virtual` for the test seam explained on
    // addTrackToPlaylist below.
    virtual void fetchPlaylist(const QString &uuid,  std::function<void(Playlist,QString)> cb);
    void fetchArtistDetail (qint64 artistId,       std::function<void(ArtistDetail,QString)> cb);
    void fetchArtistAlbums (qint64 artistId,       AlbumsCallback    cb);
    void fetchArtistTopTracks(qint64 artistId,     TracksCallback    cb);
    void fetchAlbum        (qint64 albumId,        std::function<void(Album,QString)>  cb);
    // `virtual` for the same test seam as fetchMixPage above: TidalBridge
    // answers "which mix is this track's radio" out of it, and that chain -
    // the one that decides which viewer "Start radio" opens - has to be
    // drivable without a network.
    virtual void fetchTrack(qint64 trackId,        std::function<void(Track,QString)>  cb);

    // Search
    // `offset` is the row to start at, per kind — the search endpoint takes one
    // and this never sent it, so the page could only ever see the first 20 of
    // each kind and "load more" had nothing to ask with.
    void search(const QString &query, SearchCb cb, int limit = 20, int offset = 0);

    // Favorites management
    void addTrackFavorite   (qint64 trackId,    std::function<void(bool)> cb);
    void removeTrackFavorite(qint64 trackId,    std::function<void(bool)> cb);
    void addAlbumFavorite    (qint64 albumId,    std::function<void(bool)> cb);
    void removeAlbumFavorite (qint64 albumId,    std::function<void(bool)> cb);
    void addArtistFavorite   (qint64 artistId,   std::function<void(bool)> cb);
    void removeArtistFavorite(qint64 artistId,   std::function<void(bool)> cb);

    // ── a mix the user saved ────────────────────────────────────────────
    //
    // The first write this app has ever made to a mix. Until now every mix call
    // was a fetch, which is why a saved track radio could reach the sidebar (it
    // comes in on v2/favorites/mixes, merged by fetchHomeMixes) and then never
    // be got rid of, and why there was no way to put a new one there at all.
    //
    // Nothing like the v1 favourites above. These are v2, they are PUTs, their
    // arguments ride in the query string, and crucially their reply *says what
    // it did* - so unlike the six above, success here is not "the request did
    // not fail". See mixFavoriteAccepted().
    //
    // `virtual` for the test seam tst_bridge_favorites.cpp uses, the same one
    // the four playlist calls carry: a FakeClient answers these, and the bridge
    // under test is a real TidalBridge.
    virtual void fetchFavoriteMixes(MixesCallback cb);
    virtual void addMixFavorite    (const QString &mixId, std::function<void(bool)> cb);
    virtual void removeMixFavorite (const QString &mixId, std::function<void(bool)> cb);

    // Streaming
    // `virtual` for the same test seam as createPlaylist and the three
    // below it: resolving a stream is the only way a temp media file ever
    // comes to exist, so it is how tests/tst_signals.cpp gets the real
    // Player to make a real one without an account or the network.
    virtual void fetchStreamManifest(qint64 trackId, StreamCb cb);
    // Request a specific quality (e.g. HiResLossless for downloads) without
    // touching the persisted playback preference m_quality.
    void fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb);
    QNetworkReply* fetchRaw(const QUrl &url, std::function<void(QByteArray, QString)> cb);

    // Playlist management
    // `virtual` for the same test seam as the three below: creating one is the
    // only way a playlist row enters TidalBridge's favourites cache without the
    // sign-in paging, so it is how a test gets a row in there to then add a
    // track to.
    virtual void createPlaylist  (const QString &title, std::function<void(Playlist,QString)> cb);
    // Rename a playlist and rewrite its description, in one POST back to
    // `playlists/<uuid>`. Behind the same etag dance the two item calls below
    // use: the endpoint rejects a write that is not made against the version
    // the caller last read, so the GET for the tag is not optional.
    //
    // Answers a plain bool, like the two below and unlike createPlaylist: the
    // success reply carries no body, so there is no Playlist to hand back and
    // the caller already knows what it asked for.
    void editPlaylist            (const QString &uuid,  const QString &title,
                                  const QString &description, std::function<void(bool)> cb);
    // ── the three calls TidalBridge's cache repair is built out of ───────────
    //
    // `virtual` for one reason: a test seam, the same one LibraryIndex has had
    // all along behind its six protected virtuals. Without it nothing could
    // reach the real TidalBridge at all - every one of its methods ends in a
    // client call and there was no way to answer one - so the bridge's own
    // caches were only ever tested through a QML stub that re-implemented them.
    // That is how a playlist could read "0 tracks" after two songs went into it
    // while the suite stayed green: the thing under test was the stub.
    //
    // These three, and not the whole class, because these are the three the
    // add/remove/re-read path uses. Overriding one costs a subclass in a test
    // and changes nothing about the shipping call, which is still the only
    // implementation.
    virtual void addTrackToPlaylist      (const QString &uuid,  qint64 trackId, std::function<void(bool)> cb);
    virtual void removeTrackFromPlaylist (const QString &uuid,  int itemIndex,  std::function<void(bool)> cb);

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

    // The hero of one `pages/mix` response: the mix that page is *about*, as
    // its MIX_HEADER module names it. A page opened by id alone - the "Playing
    // from" link in Now Playing navigates with nothing else - has no other
    // source for a title or a cover, and used to show neither.
    //
    // Deliberately not filtered on mixType the way parseMixPage() is. That
    // filter keeps video mixes out of a list of things the user can open; this
    // is the label on the one page they already opened, and a titled page over
    // an empty list says more than a blank one. Nothing here can put a video
    // mix into a list.
    static Mix parseMixHeader(const QJsonObject &root);

    // The tracks of one `pages/mix` response: every TRACK_LIST module, in page
    // order. A video mix answers VIDEO_LIST instead and so comes back empty -
    // which is exactly the case that must not cost the caller its header, so
    // this and parseMixHeader() are two walks and not one.
    static QList<Track> parseMixTracks(const QJsonObject &root);

    // One page of v2/favorites/mixes - the mixes this user *saved*. Flat items,
    // each carrying its own `dateAdded`, and nothing filtered out of them.
    static QList<Mix> parseSavedMixes(const QJsonObject &root);

    // The `mixes` node of a search response: {items, totalNumberOfItems}, the
    // same per-kind shape the other four come in. Video mixes are dropped here
    // for the reason parseMixPage() drops them — nothing in this app can play
    // one, so a tile for it opens an empty page — and identified by `mixType`,
    // never by the title, which arrives in the account's language.
    //
    // Unlike parseMixPage() the survivors are *not* reordered: a search result
    // is in the server's relevance order and pulling the personalised mixes to
    // the front of it would be answering a different question.
    static QList<Mix> parseSearchMixes(const QJsonObject &node);

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

    // ── the two favourite-mix writes, as data ───────────────────────────
    //
    // Public and static for the reason the parses above are: this is the whole
    // of what the two requests say, and it is worth a test that does not need a
    // network, a session or the owner's account. They touch no member state.

    // "favorites/mixes/add" or "favorites/mixes/remove", under the v2 base.
    static QString mixFavoriteEndpoint(bool adding);

    // `mixIds=<a>,<b>&onArtifactNotFound=FAIL`. Comma-joined for several ids,
    // which for one id is the id. FAIL and not the permissive alternative: a
    // mix that no longer exists must come back as an error the user is told
    // about, not as a silent no-op that leaves the pill reading "Save".
    static QUrlQuery mixFavoriteQuery(const QStringList &mixIds);

    // Whether the reply says `mixId` really went in, or really came out.
    //
    // This is the half the six v1 favourites cannot have. Those answer with no
    // body, so "the request did not fail" is all there is, and this app already
    // has a recorded history of a refused favourite looking like it succeeded.
    // v2 answers `addedItems` / `deletedItems`, so there is a fact to check, and
    // it is checked.
    //
    // Strict on purpose: the id has to be *in* the matching array. A reply that
    // carries no such array at all therefore reads as a refusal. That is a
    // deliberate choice of which way to be wrong - of the two possible lies, a
    // save that worked being reported as refused is visible and recoverable (the
    // next refresh shows the mix saved), while a refusal reported as a success
    // is the exact defect this rule exists to prevent. It is also what the
    // reference client's own validating path does
    // (tidalapi/user.py: `set(mix_ids).issubset(added_items)`).
    static bool mixFavoriteAccepted(const QJsonObject &reply, const QString &mixId,
                                    bool adding);

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

    // Static because it touches no member state and the mix-page statics above
    // are built on it.
    static QList<Track> parseTracks(const QJsonObject &root);

    static QString qualityString(AudioQuality q);

public:
    // ── which endpoint a tier's manifest comes from ──────────────────────────
    //
    // Public and static because they are the whole of the routing decision and
    // tst_stream_manifest pins them without a network.

    // True for the tiers that have to go to v2/trackManifests because
    // tracks/<id>/playbackinfopostpaywall will not serve them FLAC. See the long
    // note on fetchStreamManifest.
    static bool usesTrackManifests(AudioQuality q);

    // The `formats` the track-manifest endpoint is asked for. Repeated as a
    // query item per entry, and the server picks the best one it is offered that
    // the track actually has.
    static QStringList manifestFormats(AudioQuality q);

    // Reads a v2/trackManifests body into the same StreamManifest the old
    // endpoint produced, so nothing downstream has to know which one answered.
    // Pure. On anything that is not a full-track DASH manifest it sets *err and
    // returns {}, rather than handing a preview or an HLS playlist to the player.
    static StreamManifest parseTrackManifests(const QJsonObject &root, QString *err);

private:

    TidalApi     *m_api;
    qint64        m_userId  = 0;
    AudioQuality  m_quality = AudioQuality::Lossless;
};
