#include "TidalClient.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QByteArray>
#include <QDebug>
#include <QHash>
#include <algorithm>
#include <memory>
#include <utility>

TidalClient::TidalClient(TidalApi *api, QObject *parent)
    : QObject(parent), m_api(api) {}

QString TidalClient::qualityString(AudioQuality q) {
    switch (q) {
        case AudioQuality::Low96k:       return "LOW";
        case AudioQuality::Low320k:      return "HIGH";
        case AudioQuality::Lossless:     return "LOSSLESS";
        case AudioQuality::HiResLossless:return "HI_RES_LOSSLESS";
    }
    return "LOSSLESS";
}

// ─── Parsing helpers ───────────────────────────────

QList<Track> TidalClient::parseTracks(const QJsonObject &root) {
    QList<Track> out;
    QJsonArray items = root.contains("items") ? root["items"].toArray()
                                              : root["data"].toArray();
    for (const auto &v : items) {
        auto obj = v.toObject();
        // Some endpoints wrap tracks in {item: {...}}
        if (obj.contains("item")) obj = obj["item"].toObject();
        if (obj.contains("id"))   out.append(Track::fromJson(obj));
    }
    return out;
}

// The favourites endpoints answer {"created": …, "item": {…}} per row, and the
// "created" is the date *this* user saved the item. The album and artist objects
// inside carry no date of their own (checked against a live response: neither
// has a "created" key), so the row has to reach fromJson() along with the item
// or the save date is gone - and the sidebar's ordering is built on it.
QList<Album> TidalClient::parseAlbums(const QJsonObject &root) {
    QList<Album> out;
    for (const auto &v : root["items"].toArray()) {
        const QJsonObject row = v.toObject();
        QJsonObject obj = row;
        QJsonObject wrapper;
        if (row.contains("item")) { obj = row["item"].toObject(); wrapper = row; }
        if (obj.contains("id"))   out.append(Album::fromJson(obj, wrapper));
    }
    return out;
}

QList<Artist> TidalClient::parseArtists(const QJsonObject &root) {
    QList<Artist> out;
    for (const auto &v : root["items"].toArray()) {
        const QJsonObject row = v.toObject();
        QJsonObject obj = row;
        QJsonObject wrapper;
        if (row.contains("item")) { obj = row["item"].toObject(); wrapper = row; }
        if (obj.contains("id"))   out.append(Artist::fromJson(obj, wrapper));
    }
    return out;
}

QList<Playlist> TidalClient::parsePlaylists(const QJsonObject &root) {
    QList<Playlist> out;
    for (const auto &v : root["items"].toArray()) {
        const QJsonObject row = v.toObject();
        // The favourites and playlistsAndFavoritePlaylists endpoints wrap each
        // playlist in a row that carries the date this user added it. That row
        // has to reach Playlist::fromJson(), which prefers it over the
        // playlist's own creation date; passing only the unwrapped playlist
        // threw the one date that says "the user touched this" away.
        QJsonObject item = row;
        QJsonObject wrapper;
        if (row.contains("playlist"))  { item = row["playlist"].toObject(); wrapper = row; }
        else if (row.contains("item")) { item = row["item"].toObject();     wrapper = row; }
        if (item.contains("uuid") || item.contains("id"))
            out.append(Playlist::fromJson(item, wrapper));
    }
    return out;
}

// ─── Mixes / Home ──────────────────────────────────

QList<Mix> TidalClient::parseMixPage(const QJsonObject &root) {
    QList<Mix> mixes;
    // Navigate the nested page structure
    for (const auto &row : root["rows"].toArray()) {
        for (const auto &module : row.toObject()["modules"].toArray()) {
            auto mod = module.toObject();
            if (mod["type"].toString() != "MIX_LIST") continue;
            for (const auto &item : mod["pagedList"].toObject()["items"].toArray()) {
                const Mix mix = Mix::fromJson(item.toObject());
                // The app cannot play a video mix. Nothing in src/ or qml/ touches
                // video at all, and `pages/mix` answers a VIDEO_DAILY_MIX with a
                // VIDEO_LIST module of 50 items of type "Music Video" where a
                // DAILY_MIX answers a TRACK_LIST - so fetchMixTracks(), which
                // reads TRACK_LIST modules, finds nothing and the tile opens an
                // empty mix. my_collection_my_mixes sends eight of seventeen, two
                // of them sharing the title "My Video Mix 7", so the duplicate
                // goes with them. Delete this `continue` to let them through.
                //
                // Only here, on the *generated* list. parseSavedMixes() keeps a
                // video mix, because the user put it there on purpose and
                // silently dropping something they saved is the worse failure.
                if (mix.isVideoMix()) continue;
                mixes.append(mix);
            }
        }
    }
    return orderMixes(std::move(mixes));
}

Mix TidalClient::parseMixHeader(const QJsonObject &root) {
    // The same rows-of-modules walk as parseMixPage(), looking for the one
    // module that describes the page rather than a list on it. The mix hangs
    // off `mix`, and carries the id, title, subTitle, mixType and images that
    // Mix::fromJson already knows how to read.
    for (const auto &row : root["rows"].toArray())
        for (const auto &module : row.toObject()["modules"].toArray()) {
            const QJsonObject mod = module.toObject();
            if (mod["type"].toString() != "MIX_HEADER") continue;
            const Mix mix = Mix::fromJson(mod["mix"].toObject());
            // A header with nothing under it is not an answer: keep walking
            // rather than handing back a blank mix that looks like one.
            if (!mix.id.isEmpty() || !mix.title.isEmpty()) return mix;
        }
    return {};
}

QList<Track> TidalClient::parseMixTracks(const QJsonObject &root) {
    QList<Track> tracks;
    for (const auto &row : root["rows"].toArray())
        for (const auto &module : row.toObject()["modules"].toArray()) {
            const QJsonObject mod = module.toObject();
            // TRACK_LIST and nothing else. A video mix's VIDEO_LIST holds
            // "Music Video" items this app has no way to play - see
            // parseMixPage() - and reading it would be worse than reading
            // nothing.
            if (mod["type"].toString() != "TRACK_LIST") continue;
            tracks.append(parseTracks(mod["pagedList"].toObject()));
        }
    return tracks;
}

QList<Mix> TidalClient::parseSavedMixes(const QJsonObject &root) {
    // v2/favorites/mixes. Nothing like the `pages/*` feeds: a flat "items" array
    // whose entries *are* the mixes - no {"item": {…}} wrapper, unlike the v1
    // favourites endpoints - and each carries the `dateAdded` the sidebar orders
    // on. No "totalNumberOfItems" either; see nextCursor() for how paging ends.
    //
    // Nothing is filtered. A TRACK_MIX or ARTIST_MIX here is a radio station the
    // user saved, which is a saved mix like any other and is the thing they
    // noticed was missing from the Collection.
    QList<Mix> mixes;
    for (const auto &v : root["items"].toArray()) {
        const QJsonObject obj = v.toObject();
        if (obj.contains("id")) mixes.append(Mix::fromJson(obj));
    }
    return mixes;
}

QString TidalClient::nextCursor(const QJsonObject &page, const QString &previous) {
    // This endpoint pages on an opaque cursor and reports no total, so there is no
    // arithmetic that says "done". Three things end a run:
    //
    //   * an empty page. Nothing more can come of asking again.
    //   * the cursor the page was just fetched with, which would fetch the same
    //     page for ever. (LibraryIndex has the same guard on the offset-paged
    //     endpoints, for the same reason.)
    //   * no cursor at all - the last page answers `"cursor": null`, which reads
    //     back as an empty string. That needs no branch of its own: an empty
    //     cursor returned is what the caller stops on. The temptation is to treat
    //     "no new cursor" as "ask again with the old one"; that is an endless run.
    const QString cursor = page["cursor"].toString();
    if (page["items"].toArray().isEmpty()) return {};
    if (cursor == previous) return {};
    return cursor;
}

QList<Mix> TidalClient::mergeMixLists(const QList<QList<Mix>> &lists) {
    // One row per mix id, never per title: titles arrive translated, and
    // my_collection_my_mixes proves they are not unique even inside one response
    // (two different mixes both called "My Video Mix 7").
    //
    // The first list to carry an id fixes that mix's position, which is why
    // fetchHomeMixes passes the generated list first: it is the one that holds
    // "My Mix 1".."My Mix 8" as a run, and taking the saved list first would
    // break the run apart wherever a mix happens to be saved. The saved record
    // still wins on one field - `dateAdded`, which only it has, and which the
    // sidebar's ordering needs. Everything else (title, subtitle, artwork) is the
    // same mix either way.
    QList<Mix> out;
    QHash<QString, qsizetype> seen;
    for (const QList<Mix> &list : lists) {
        for (const Mix &m : list) {
            if (m.id.isEmpty()) { out.append(m); continue; }
            const auto at = seen.constFind(m.id);
            if (at == seen.constEnd()) {
                seen.insert(m.id, out.size());
                out.append(m);
                continue;
            }
            Mix &kept = out[*at];
            if (kept.addedAt == 0 && m.addedAt > 0) kept.addedAt = m.addedAt;
        }
    }
    return orderMixes(std::move(out));
}

QList<Mix> TidalClient::orderMixes(QList<Mix> mixes) {
    // "My Daily Discovery" first, then "My New Arrivals", then the order the
    // lists were walked in.
    //
    // The ranking is on mixType, never on the title: every one of these titles
    // arrives translated, so matching "My Daily Discovery" would put the two
    // back behind the rest for every user not reading the app in English.
    // Stable, so everything else keeps the order it came in, which is what the
    // Collection grid shows on its default (unsorted) setting.
    const auto rank = [](const Mix &m) {
        if (m.isDailyDiscovery()) return 0;
        if (m.isNewArrivals())    return 1;
        return 2;
    };
    std::stable_sort(mixes.begin(), mixes.end(),
                     [&rank](const Mix &a, const Mix &b) { return rank(a) < rank(b); });
    return mixes;
}

void TidalClient::fetchGeneratedMixes(MixesCallback cb) {
    QUrlQuery q;
    q.addQueryItem("deviceType", "BROWSER");
    m_api->get(QStringLiteral("pages/my_collection_my_mixes"), q,
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(parseMixPage(root), {});
        });
}

void TidalClient::fetchSavedMixes(MixesCallback cb, const QString &cursor,
                                  QList<Mix> acc, int page)
{
    QUrlQuery q;
    // 50 is the server's maximum, not a preference: limit=100 answers 400
    // "getMixes.limit: must be less than or equal to 50".
    q.addQueryItem("limit", QString::number(kSavedMixesPageSize));
    if (!cursor.isEmpty()) q.addQueryItem("cursor", cursor);
    m_api->getV2(QStringLiteral("favorites/mixes"), q,
        [this, cb, cursor, acc, page](QJsonObject root, QString err) mutable {
            if (!err.isEmpty()) {
                // A later page failing still delivers the earlier ones; only an
                // empty run is an error.
                cb(acc, acc.isEmpty() ? err : QString());
                return;
            }
            acc.append(parseSavedMixes(root));
            const QString next = nextCursor(root, cursor);
            if (next.isEmpty() || page + 1 >= kMaxSavedMixesPages) { cb(acc, {}); return; }
            fetchSavedMixes(cb, next, acc, page + 1);
        });
}

void TidalClient::fetchHomeMixes(MixesCallback cb) {
    // Both lists, merged on the mix id. The generated feed has the eight "My Mix
    // N" that are not saved; v2/favorites/mixes has whatever the user saved,
    // including "My New Arrivals" - which is on no `pages/*` feed the app reads -
    // and any radio station they saved. Neither is a subset of the other.
    //
    // This is the one place that decides what the Collection's Mixes tab holds.
    // Dropping a source is deleting one of the two fetches below and the matching
    // argument to mergeMixLists(); nothing else has to change.
    struct Pending {
        QList<Mix> generated;
        QList<Mix> saved;
        int        outstanding = 2;
        QString    err;
    };
    const auto pending = std::make_shared<Pending>();

    const auto finish = [cb, pending]() {
        if (--pending->outstanding > 0) return;
        const QList<Mix> mixes = mergeMixLists({pending->generated, pending->saved});
        // One source failing must not empty the tab: whatever the other answered
        // is better than nothing, and PinStore spends its one seeding shot on an
        // empty list only when that was a real answer. The error is reported only
        // when neither source yielded anything.
        if (mixes.isEmpty() && !pending->err.isEmpty()) { cb({}, pending->err); return; }
        cb(mixes, {});
    };

    fetchGeneratedMixes([pending, finish](QList<Mix> mixes, QString err) {
        if (err.isEmpty()) pending->generated = mixes;
        else if (pending->err.isEmpty()) pending->err = err;
        finish();
    });
    fetchSavedMixes([pending, finish](QList<Mix> mixes, QString err) {
        if (err.isEmpty()) pending->saved = mixes;
        else if (pending->err.isEmpty()) pending->err = err;
        finish();
    });
}

void TidalClient::fetchMixPage(const QString &mixId, MixPageCallback cb) {
    QUrlQuery q;
    q.addQueryItem("mixId", mixId);
    q.addQueryItem("deviceType", "BROWSER");
    m_api->get(QStringLiteral("pages/mix"), q, [cb](QJsonObject root, QString err) {
        if (!err.isEmpty()) { cb({}, {}, err); return; }
        // Two independent walks of the same response, so that a page missing
        // one module still delivers the other: a video mix has a header and a
        // VIDEO_LIST this app cannot read, and that must still label the page
        // rather than answering nothing at all.
        cb(parseMixHeader(root), parseMixTracks(root), {});
    });
}

void TidalClient::fetchMixTracks(const QString &mixId, TracksCallback cb) {
    fetchMixPage(mixId, [cb](Mix, QList<Track> tracks, QString err) { cb(tracks, err); });
}

// ─── Favorites ─────────────────────────────────────

void TidalClient::fetchFavoriteTracks(TracksCallback cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("limit",  QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    q.addQueryItem("order",  "DATE");
    m_api->get(QStringLiteral("users/%1/favorites/tracks").arg(m_userId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseTracks(root) : QList<Track>{}, err); });
}

void TidalClient::fetchFavoriteAlbums(AlbumsCallback cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("limit",  QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    // Newest saved first. Without an order the endpoint answers order=NAME, so
    // the collection opened alphabetically and anything just saved landed in
    // the middle of it. The date lives on the favourites row, not on the album
    // the row wraps, and nothing here parses it, so this ordering has to come
    // from the server: a client-side sort has no timestamp to sort on.
    q.addQueryItem("order",  "DATE");
    q.addQueryItem("orderDirection", "DESC");

    // If the server will not take the ordering, fall back to an unordered
    // request rather than letting the collection come back empty. The order
    // params have not been exercised against a live account, and a rejected
    // parameter would otherwise turn a cosmetic preference into a library that
    // does not load at all.
    const QString path = QStringLiteral("users/%1/favorites/albums").arg(m_userId);
    QUrlQuery plain;
    plain.addQueryItem("limit",  QString::number(limit));
    plain.addQueryItem("offset", QString::number(offset));

    m_api->get(path, q, [this, cb, path, plain](QJsonObject root, QString err) mutable {
        if (err.isEmpty()) { cb(parseAlbums(root), err); return; }
        qWarning("TidalClient: favourites by date failed (%s); retrying unordered",
                 qPrintable(err));
        m_api->get(path, plain, [this, cb](QJsonObject root2, QString err2) {
            cb(err2.isEmpty() ? parseAlbums(root2) : QList<Album>{}, err2); });
    });
}

void TidalClient::fetchFavoriteArtists(ArtistsCallback cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("limit", QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    // Newest followed first, for the same reason as the albums above.
    q.addQueryItem("order", "DATE");
    q.addQueryItem("orderDirection", "DESC");

    // Same fallback as the albums above.
    const QString path = QStringLiteral("users/%1/favorites/artists").arg(m_userId);
    QUrlQuery plain;
    plain.addQueryItem("limit",  QString::number(limit));
    plain.addQueryItem("offset", QString::number(offset));

    m_api->get(path, q, [this, cb, path, plain](QJsonObject root, QString err) mutable {
        if (err.isEmpty()) { cb(parseArtists(root), err); return; }
        qWarning("TidalClient: followed artists by date failed (%s); retrying unordered",
                 qPrintable(err));
        m_api->get(path, plain, [this, cb](QJsonObject root2, QString err2) {
            cb(err2.isEmpty() ? parseArtists(root2) : QList<Artist>{}, err2); });
    });
}

void TidalClient::fetchUserPlaylists(PlaylistsCallback cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("limit", QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    m_api->get(QStringLiteral("users/%1/playlistsAndFavoritePlaylists").arg(m_userId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parsePlaylists(root) : QList<Playlist>{}, err); });
}

// ─── Content ───────────────────────────────────────

void TidalClient::fetchAlbumTracks(qint64 albumId, TracksCallback cb) {
    fetchAllTracks(QStringLiteral("albums/%1/tracks").arg(albumId), cb);
}

void TidalClient::fetchPlaylistTracks(const QString &uuid, TracksCallback cb) {
    fetchAllTracks(QStringLiteral("playlists/%1/tracks").arg(uuid), cb);
}

void TidalClient::fetchPlaylist(const QString &uuid,
    std::function<void(Playlist, QString)> cb)
{
    // The same object the favourites endpoints wrap, served on its own, so
    // there is no row to unwrap and no save date to recover: Playlist::fromJson
    // reads the playlist's own fields and leaves addedAt at 0.
    m_api->get(QStringLiteral("playlists/%1").arg(uuid), {},
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(Playlist::fromJson(root), {});
        });
}

void TidalClient::fetchAllTracks(const QString &endpoint, TracksCallback cb,
                                 int offset, QList<Track> acc)
{
    QUrlQuery q;
    q.addQueryItem("limit", "100");
    q.addQueryItem("offset", QString::number(offset));
    m_api->get(endpoint, q,
        [this, endpoint, cb, offset, acc](QJsonObject root, QString err) mutable {
            if (!err.isEmpty()) {
                cb(acc, acc.isEmpty() ? err : QString());
                return;
            }
            QList<Track> page = parseTracks(root);
            acc.append(page);
            int total = root["totalNumberOfItems"].toInt(acc.size());
            if (page.isEmpty() || acc.size() >= total)
                cb(acc, {});
            else
                fetchAllTracks(endpoint, cb, offset + page.size(), acc);
        });
}

void TidalClient::fetchAlbum(qint64 albumId, std::function<void(Album,QString)> cb) {
    m_api->get(QStringLiteral("albums/%1").arg(albumId), {},
        [cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? Album::fromJson(root) : Album{}, err); });
}

void TidalClient::fetchTrack(qint64 trackId, std::function<void(Track,QString)> cb) {
    m_api->get(QStringLiteral("tracks/%1").arg(trackId), {},
        [cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? Track::fromJson(root) : Track{}, err); });
}

void TidalClient::fetchArtistDetail(qint64 artistId,
    std::function<void(ArtistDetail, QString)> cb)
{
    m_api->get(QStringLiteral("artists/%1").arg(artistId), {},
        [this, artistId, cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            ArtistDetail d;
            d.id      = root["id"].toVariant().toLongLong();
            d.name    = root["name"].toString();
            d.picture = root["picture"].toString();
            // Bio comes from a separate endpoint
            m_api->get(QStringLiteral("artists/%1/bio").arg(artistId), {},
                [d, cb](QJsonObject bio, QString) mutable {
                    d.bio = bio["text"].toString();
                    cb(d, {});
                });
        });
}

void TidalClient::fetchArtistAlbums(qint64 artistId, AlbumsCallback cb) {
    QUrlQuery q;
    q.addQueryItem("limit", "50");
    m_api->get(QStringLiteral("artists/%1/albums").arg(artistId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseAlbums(root) : QList<Album>{}, err); });
}

void TidalClient::fetchArtistTopTracks(qint64 artistId, TracksCallback cb) {
    QUrlQuery q;
    q.addQueryItem("limit", "10");
    m_api->get(QStringLiteral("artists/%1/toptracks").arg(artistId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseTracks(root) : QList<Track>{}, err); });
}

// ─── Search ────────────────────────────────────────

// The `mixes` node of a search response. See the header for why the video
// filter is here and why nothing is reordered.
QList<Mix> TidalClient::parseSearchMixes(const QJsonObject &node) {
    QList<Mix> out;
    for (const auto &v : node["items"].toArray()) {
        QJsonObject item = v.toObject();
        // The favourites endpoints wrap each item in a row carrying a date;
        // search does not, but unwrapping costs one branch and parsePlaylists
        // already hedges the same way, so a wrapped shape cannot silently
        // yield a list of blank mixes.
        if (item.contains("item")) item = item["item"].toObject();
        const Mix mix = Mix::fromJson(item);
        if (mix.id.isEmpty()) continue;
        if (mix.isVideoMix()) continue;
        out.append(mix);
    }
    return out;
}

void TidalClient::search(const QString &query, SearchCb cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("query", query);
    q.addQueryItem("limit", QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    q.addQueryItem("types", "TRACKS,ALBUMS,ARTISTS,PLAYLISTS,MIXES");
    m_api->get("search", q, [this, cb](QJsonObject root, QString err) {
        if (!err.isEmpty()) { cb({}, err); return; }
        SearchResults r;
        if (root.contains("tracks")) {
            r.tracks       = parseTracks(root["tracks"].toObject());
            r.totalTracks  = root["tracks"].toObject()["totalNumberOfItems"].toInt();
        }
        if (root.contains("albums")) {
            r.albums       = parseAlbums(root["albums"].toObject());
            r.totalAlbums  = root["albums"].toObject()["totalNumberOfItems"].toInt();
        }
        if (root.contains("artists")) {
            r.artists      = parseArtists(root["artists"].toObject());
            r.totalArtists = root["artists"].toObject()["totalNumberOfItems"].toInt();
        }
        if (root.contains("playlists")) {
            r.playlists      = parsePlaylists(root["playlists"].toObject());
            r.totalPlaylists = root["playlists"].toObject()["totalNumberOfItems"].toInt();
        }
        if (root.contains("mixes")) {
            r.mixes      = parseSearchMixes(root["mixes"].toObject());
            r.totalMixes = root["mixes"].toObject()["totalNumberOfItems"].toInt();
        }
        cb(r, {});
    });
}

// ─── Favorites management ──────────────────────────

void TidalClient::addTrackFavorite(qint64 trackId, std::function<void(bool)> cb) {
    QUrlQuery form;
    form.addQueryItem("trackIds", QString::number(trackId));
    form.addQueryItem("countryCode", m_api->countryCode());
    m_api->postApiForm(QStringLiteral("users/%1/favorites/tracks").arg(m_userId), form,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

void TidalClient::removeTrackFavorite(qint64 trackId, std::function<void(bool)> cb) {
    QUrlQuery params;
    params.addQueryItem("countryCode", m_api->countryCode());
    m_api->deleteApi(QStringLiteral("users/%1/favorites/tracks/%2").arg(m_userId).arg(trackId), params,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

void TidalClient::addAlbumFavorite(qint64 albumId, std::function<void(bool)> cb) {
    QUrlQuery form;
    form.addQueryItem("albumIds", QString::number(albumId));
    form.addQueryItem("countryCode", m_api->countryCode());
    m_api->postApiForm(QStringLiteral("users/%1/favorites/albums").arg(m_userId), form,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

void TidalClient::removeAlbumFavorite(qint64 albumId, std::function<void(bool)> cb) {
    QUrlQuery params;
    params.addQueryItem("countryCode", m_api->countryCode());
    m_api->deleteApi(QStringLiteral("users/%1/favorites/albums/%2").arg(m_userId).arg(albumId), params,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

void TidalClient::addArtistFavorite(qint64 artistId, std::function<void(bool)> cb) {
    QUrlQuery form;
    form.addQueryItem("artistIds", QString::number(artistId));
    form.addQueryItem("countryCode", m_api->countryCode());
    m_api->postApiForm(QStringLiteral("users/%1/favorites/artists").arg(m_userId), form,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

void TidalClient::removeArtistFavorite(qint64 artistId, std::function<void(bool)> cb) {
    QUrlQuery params;
    params.addQueryItem("countryCode", m_api->countryCode());
    m_api->deleteApi(QStringLiteral("users/%1/favorites/artists/%2").arg(m_userId).arg(artistId), params,
        [cb](QJsonObject, QString err) { cb(err.isEmpty()); });
}

// ─── Streaming ─────────────────────────────────────

void TidalClient::fetchStreamManifest(qint64 trackId, StreamCb cb) {
    fetchStreamManifest(trackId, m_quality, std::move(cb));
}

void TidalClient::fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb) {
    QUrlQuery q;
    q.addQueryItem("playbackmode",      "STREAM");
    q.addQueryItem("assetpresentation", "FULL");
    q.addQueryItem("audioquality",      qualityString(quality));
    q.addQueryItem("prefetch",          "false");

    m_api->get(QStringLiteral("tracks/%1/playbackinfopostpaywall").arg(trackId), q,
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }

            StreamManifest m;
            m.codec      = root["audioQuality"].toString();
            m.sampleRate = root["sampleRate"].toInt(44100);
            m.bitDepth   = root["bitDepth"].toInt(16);
            m.replayGainTrack = root["trackReplayGain"].toDouble();
            m.replayGainAlbum = root["albumReplayGain"].toDouble();

            QString mimeType = root["manifestMimeType"].toString();
            QByteArray manifestB64 = root["manifest"].toString().toUtf8();
            QByteArray manifestData = QByteArray::fromBase64(manifestB64);

            if (mimeType == "application/vnd.tidal.bts") {
                // BTS format: JSON with URL array
                auto bts = QJsonDocument::fromJson(manifestData).object();
                auto urls = bts["urls"].toArray();
                if (!urls.isEmpty()) {
                    m.type     = StreamManifest::BTS;
                    m.url      = urls[0].toString();
                    m.mimeType = bts["mimeType"].toString();
                }
            } else {
                // MPD format: MPEG-DASH manifest XML
                m.type     = StreamManifest::MPD;
                m.url      = QString::fromUtf8(manifestData);
                m.mimeType = "application/dash+xml";
            }
            cb(m, {});
        });
}

QNetworkReply* TidalClient::fetchRaw(const QUrl &url, std::function<void(QByteArray, QString)> cb) {
    return m_api->getRaw(url, cb);
}

// ─── Playlist management ───────────────────────────

void TidalClient::createPlaylist(const QString &title,
    std::function<void(Playlist, QString)> cb)
{
    QUrlQuery form;
    form.addQueryItem("title",       title);
    form.addQueryItem("description", "");
    m_api->postApiForm(QStringLiteral("users/%1/playlists").arg(m_userId), form,
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(Playlist::fromJson(root), {});
        });
}

void TidalClient::editPlaylist(const QString &uuid, const QString &title,
    const QString &description, std::function<void(bool)> cb)
{
    // Both fields go every time, even the one the dialog did not touch. The
    // endpoint replaces what it is sent rather than merging it, so posting
    // only the title would clear the description.
    m_api->getEtag(QStringLiteral("playlists/%1").arg(uuid),
        [this, uuid, title, description, cb](QString etag, QString err) {
            if (!err.isEmpty()) { cb(false); return; }
            QUrlQuery form;
            form.addQueryItem("title",       title);
            form.addQueryItem("description", description);
            m_api->postApiFormEtag(QStringLiteral("playlists/%1").arg(uuid), form, etag,
                [cb](QJsonObject, QString e) { cb(e.isEmpty()); });
        });
}

void TidalClient::addTrackToPlaylist(const QString &uuid, qint64 trackId,
    std::function<void(bool)> cb)
{
    m_api->getEtag(QStringLiteral("playlists/%1").arg(uuid),
        [this, uuid, trackId, cb](QString etag, QString err) {
            if (!err.isEmpty()) { cb(false); return; }
            QUrlQuery form;
            form.addQueryItem("trackIds",           QString::number(trackId));
            form.addQueryItem("onArtifactNotFound", "FAIL");
            form.addQueryItem("onDuplicateFound",   "SKIP");
            m_api->postApiFormEtag(QStringLiteral("playlists/%1/items").arg(uuid), form, etag,
                [cb](QJsonObject, QString e) { cb(e.isEmpty()); });
        });
}

void TidalClient::removeTrackFromPlaylist(const QString &uuid, int itemIndex,
    std::function<void(bool)> cb)
{
    m_api->getEtag(QStringLiteral("playlists/%1").arg(uuid),
        [this, uuid, itemIndex, cb](QString etag, QString err) {
            if (!err.isEmpty()) { cb(false); return; }
            QUrlQuery params;
            params.addQueryItem("toIndex",   QString::number(itemIndex));
            params.addQueryItem("fromIndex", QString::number(itemIndex));
            params.addQueryItem("order",     "INDEX");
            m_api->deleteApiEtag(QStringLiteral("playlists/%1/items").arg(uuid), params, etag,
                [cb](QJsonObject, QString e) { cb(e.isEmpty()); });
        });
}

void TidalClient::fetchTrackRadio(qint64 trackId, TracksCallback cb) {
    QUrlQuery q;
    q.addQueryItem("limit", "50");
    m_api->get(QStringLiteral("tracks/%1/radio").arg(trackId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseTracks(root) : QList<Track>{}, err);
        });
}

void TidalClient::fetchLyrics(qint64 trackId, std::function<void(QString, bool, QString)> cb) {
    m_api->get(QStringLiteral("tracks/%1/lyrics").arg(trackId), {},
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, false, err); return; }
            QString text = root["subtitles"].toString();
            bool timed = !text.isEmpty();
            if (text.isEmpty()) text = root["text"].toString();
            cb(text, timed, {});
        });
}

void TidalClient::fetchTrackCredits(qint64 trackId,
    std::function<void(TrackCredits, QString)> cb)
{
    // The contributor list first, because it is the only one of the three whose
    // failure is worth refusing the panel over: it is what the user asked to
    // see, and if it did not arrive the network is not answering. The two
    // requests chained behind it are additions to a result that already exists,
    // so their errors are swallowed and their fields stay empty rather than
    // throwing away credits that did arrive.
    QUrlQuery q;
    q.addQueryItem("includeContributors", "true");
    m_api->getArray(QStringLiteral("tracks/%1/credits").arg(trackId), q,
        [this, trackId, cb](QJsonArray groups, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }

            auto out = std::make_shared<TrackCredits>();
            for (const auto &v : groups) {
                auto g = TrackCredits::groupFromJson(v.toObject());
                if (!g.type.isEmpty() && !g.contributors.isEmpty())
                    out->groups.append(g);
            }

            m_api->get(QStringLiteral("tracks/%1").arg(trackId), {},
                [this, out, cb](QJsonObject track, QString trackErr) {
                    qint64 albumId = 0;
                    if (trackErr.isEmpty()) {
                        out->copyright = track["copyright"].toString();
                        out->isrc      = track["isrc"].toString();
                        albumId = track["album"].toObject()["id"]
                                      .toVariant().toLongLong();
                    }
                    // streamStartDate is deliberately not read here. It is when
                    // this account's catalogue got the track, not when the
                    // record came out: probed against a 1975 album it answered
                    // 2026-07-01. The release date is the album's.
                    if (albumId <= 0) { cb(*out, {}); return; }

                    m_api->get(QStringLiteral("albums/%1").arg(albumId), {},
                        [out, cb](QJsonObject album, QString albumErr) {
                            if (albumErr.isEmpty()) {
                                out->releaseDate = album["releaseDate"].toString();
                                out->upc         = album["upc"].toString();
                                if (out->copyright.isEmpty())
                                    out->copyright = album["copyright"].toString();
                            }
                            cb(*out, {});
                        });
                });
        });
}

void TidalClient::fetchRecentlyPlayed(TracksCallback cb) {
    QUrlQuery q;
    q.addQueryItem("limit", "20");
    m_api->get(QStringLiteral("users/%1/history").arg(m_userId), q,
        [this, cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            QList<Track> tracks;
            for (const auto &v : root["items"].toArray()) {
                auto obj  = v.toObject();
                auto item = obj["item"].toObject();
                if (item.contains("id"))
                    tracks.append(Track::fromJson(item));
            }
            cb(tracks, {});
        });
}
