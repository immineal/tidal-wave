// SPDX-License-Identifier: GPL-3.0-or-later

#include "TidalClient.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QByteArray>
#include <QDebug>
#include <QHash>
#include <QSet>
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

// The favourites endpoints answer {"created": …, "item": {…}} per row. The
// row goes to fromJson() with the item, because only the row carries the save
// date the sidebar orders on.
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
        // The wrapping row carries the date this user added the playlist, so
        // it goes to Playlist::fromJson() with the item.
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
    for (const auto &row : root["rows"].toArray()) {
        for (const auto &module : row.toObject()["modules"].toArray()) {
            auto mod = module.toObject();
            if (mod["type"].toString() != "MIX_LIST") continue;
            for (const auto &item : mod["pagedList"].toObject()["items"].toArray()) {
                const Mix mix = Mix::fromJson(item.toObject());
                // The app cannot play a video mix: `pages/mix` answers one with
                // a VIDEO_LIST module and the tile would open empty. Dropped on
                // the generated list only; parseSavedMixes() keeps a saved one.
                if (mix.isVideoMix()) continue;
                mixes.append(mix);
            }
        }
    }
    return orderMixes(std::move(mixes));
}

Mix TidalClient::parseMixHeader(const QJsonObject &root) {
    for (const auto &row : root["rows"].toArray())
        for (const auto &module : row.toObject()["modules"].toArray()) {
            const QJsonObject mod = module.toObject();
            if (mod["type"].toString() != "MIX_HEADER") continue;
            const Mix mix = Mix::fromJson(mod["mix"].toObject());
            // An empty header is no answer: keep walking.
            if (!mix.id.isEmpty() || !mix.title.isEmpty()) return mix;
        }
    return {};
}

QList<Track> TidalClient::parseMixTracks(const QJsonObject &root) {
    QList<Track> tracks;
    for (const auto &row : root["rows"].toArray())
        for (const auto &module : row.toObject()["modules"].toArray()) {
            const QJsonObject mod = module.toObject();
            // TRACK_LIST only. A VIDEO_LIST holds items the app cannot play.
            if (mod["type"].toString() != "TRACK_LIST") continue;
            tracks.append(parseTracks(mod["pagedList"].toObject()));
        }
    return tracks;
}

QList<Mix> TidalClient::parseSavedMixes(const QJsonObject &root) {
    // A flat "items" array whose entries are the mixes, with no {"item": {…}}
    // wrapper and no "totalNumberOfItems". Nothing is filtered: a saved radio
    // station is a saved mix like any other.
    QList<Mix> mixes;
    for (const auto &v : root["items"].toArray()) {
        const QJsonObject obj = v.toObject();
        if (obj.contains("id")) mixes.append(Mix::fromJson(obj));
    }
    return mixes;
}

QString TidalClient::nextCursor(const QJsonObject &page, const QString &previous) {
    // Three things end a run: an empty page, a repeat of the cursor this page
    // was fetched with, and no cursor at all. The last page answers
    // `"cursor": null`, which reads back as "" and is what the caller stops on.
    const QString cursor = page["cursor"].toString();
    if (page["items"].toArray().isEmpty()) return {};
    if (cursor == previous) return {};
    return cursor;
}

QList<Mix> TidalClient::mergeMixLists(const QList<QList<Mix>> &lists) {
    // Keyed on the id, never the title: titles are localised and not unique
    // within one response. The first list fixes the position, so
    // fetchHomeMixes passes the generated list first to keep its run together.
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
    // Ranked on mixType, never on the title, which is localised. Stable, so
    // everything else keeps the order it came in.
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
    // The generated feed and the saved list, merged on the mix id. Neither is
    // a subset of the other.
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
        // One source failing must not empty the tab. The error is reported
        // only when neither yielded anything, so an empty list without an
        // error is a real answer.
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
        // Two independent walks, so a page missing one module still delivers
        // the other.
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
    // Newest saved first. Without an order the endpoint answers order=NAME.
    q.addQueryItem("order",  "DATE");
    q.addQueryItem("orderDirection", "DESC");

    // If the server rejects the ordering, retry unordered so the collection
    // still loads.
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
    // Newest followed first, with the same unordered retry as the albums.
    q.addQueryItem("order", "DATE");
    q.addQueryItem("orderDirection", "DESC");

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
    // Served without a favourites row, so there is no save date here.
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

// A release can answer to two filters at once, so the lists are deduplicated
// on the album id. The first list to carry an id wins, with its whole record.
QList<Album> TidalClient::mergeAlbumLists(const QList<QList<Album>> &lists) {
    QList<Album> out;
    QSet<qint64> seen;
    for (const QList<Album> &list : lists) {
        for (const Album &a : list) {
            // id 0 means no id: kept, so distinct releases are never merged
            // by a missing field.
            if (a.id != 0) {
                if (seen.contains(a.id)) continue;
                seen.insert(a.id);
            }
            out.append(a);
        }
    }
    return out;
}

void TidalClient::fetchArtistAlbumPage(qint64 artistId, const QString &filter,
                                       AlbumPages pages, AlbumsCallback cb,
                                       int offset, QList<Album> acc)
{
    QUrlQuery q;
    if (!filter.isEmpty()) q.addQueryItem("filter", filter);
    q.addQueryItem("limit", QString::number(kArtistAlbumsPageSize));
    q.addQueryItem("offset", QString::number(offset));
    m_api->get(QStringLiteral("artists/%1/albums").arg(artistId), q,
        [this, artistId, filter, pages, cb, offset, acc](QJsonObject root, QString err) mutable {
            if (!err.isEmpty()) {
                // The earlier pages are still delivered; only an empty run
                // is an error.
                cb(acc, acc.isEmpty() ? err : QString());
                return;
            }
            const QList<Album> page = parseAlbums(root);
            acc.append(page);
            const int total = root["totalNumberOfItems"].toInt(acc.size());
            if (pages == AlbumPages::First || page.isEmpty() || acc.size() >= total
                || acc.size() >= kMaxArtistAlbums) {
                cb(acc, {});
                return;
            }
            fetchArtistAlbumPage(artistId, filter, pages, cb, offset + int(page.size()), acc);
        });
}

void TidalClient::fetchArtistAlbums(qint64 artistId, AlbumsCallback cb) {
    // Three requests: see kFilterEpsAndSingles and kFilterAppearsOn. Merged
    // here so that ArtistPage gets one reply behind its one `loading` flag.
    struct Pending {
        QList<Album> albums;
        QList<Album> epsAndSingles;
        QList<Album> appearsOn;
        int          outstanding = 3;
        QString      err;
    };
    const auto pending = std::make_shared<Pending>();

    const auto finish = [cb, pending]() {
        if (--pending->outstanding > 0) return;
        // The three responses carry the same fields, so the guest appearances
        // are marked while their list is still apart from the other two.
        for (Album &a : pending->appearsOn) a.featured = true;
        // The artist's own lists go first: a record of theirs that the
        // appears-on filter also answers keeps its place and stays unmarked.
        const QList<Album> all = mergeAlbumLists(
            {pending->albums, pending->epsAndSingles, pending->appearsOn});
        // One filter failing must not empty the page. The error is reported
        // only when none of the three yielded anything.
        if (all.isEmpty() && !pending->err.isEmpty()) { cb({}, pending->err); return; }
        cb(all, {});
    };

    const auto collect = [pending, finish](QList<Album> *into) {
        return [pending, finish, into](QList<Album> albums, QString err) {
            if (err.isEmpty()) *into = albums;
            else if (pending->err.isEmpty()) pending->err = err;
            finish();
        };
    };

    // Each request fills a slot of its own, so the order the replies land in
    // changes nothing.
    fetchArtistAlbumPage(artistId, QString(), AlbumPages::All, collect(&pending->albums));
    fetchArtistAlbumPage(artistId, QString::fromLatin1(kFilterEpsAndSingles), AlbumPages::All,
                         collect(&pending->epsAndSingles));
    // A long career answers the appears-on filter with hundreds of
    // various-artists compilations. The row takes the first page of them.
    fetchArtistAlbumPage(artistId, QString::fromLatin1(kFilterAppearsOn), AlbumPages::First,
                         collect(&pending->appearsOn));
}

void TidalClient::fetchArtistTopTracks(qint64 artistId, TracksCallback cb) {
    QUrlQuery q;
    q.addQueryItem("limit", "10");
    m_api->get(QStringLiteral("artists/%1/toptracks").arg(artistId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseTracks(root) : QList<Track>{}, err); });
}

// ─── Search ────────────────────────────────────────

QList<Mix> TidalClient::parseSearchMixes(const QJsonObject &node) {
    QList<Mix> out;
    for (const auto &v : node["items"].toArray()) {
        QJsonObject item = v.toObject();
        // Search does not wrap its items. Unwrapping anyway guards against a
        // wrapped shape yielding blank mixes.
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

// A favourite that is gone already is what its removal asked for, so a 404
// to the DELETE counts as removed.
static TidalApi::StatusCallback removedOrGone(std::function<void(bool)> cb) {
    return [cb = std::move(cb)](QJsonObject, QString err, int httpStatus) {
        cb(err.isEmpty() || httpStatus == 404);
    };
}

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
    m_api->deleteApiWithStatus(
        QStringLiteral("users/%1/favorites/tracks/%2").arg(m_userId).arg(trackId), params,
        removedOrGone(std::move(cb)));
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
    m_api->deleteApiWithStatus(
        QStringLiteral("users/%1/favorites/albums/%2").arg(m_userId).arg(albumId), params,
        removedOrGone(std::move(cb)));
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
    m_api->deleteApiWithStatus(
        QStringLiteral("users/%1/favorites/artists/%2").arg(m_userId).arg(artistId), params,
        removedOrGone(std::move(cb)));
}

// ─── Favourite mixes (v2) ──────────────────────────

QString TidalClient::mixFavoriteEndpoint(bool adding) {
    return adding ? QStringLiteral("favorites/mixes/add")
                  : QStringLiteral("favorites/mixes/remove");
}

QUrlQuery TidalClient::mixFavoriteQuery(const QStringList &mixIds) {
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("mixIds"), mixIds.join(QLatin1Char(',')));
    q.addQueryItem(QStringLiteral("onArtifactNotFound"), QStringLiteral("FAIL"));
    return q;
}

bool TidalClient::mixFavoriteAccepted(const QJsonObject &reply, const QString &mixId,
                                      bool adding)
{
    if (mixId.isEmpty()) return false;
    const QJsonArray items = reply.value(adding ? QLatin1String("addedItems")
                                               : QLatin1String("deletedItems")).toArray();
    for (const auto &v : items)
        if (v.toString() == mixId) return true;
    return false;
}

void TidalClient::fetchFavoriteMixes(MixesCallback cb) {
    // The saved list alone. The merged list also holds generated mixes,
    // which were never saved and cannot be unsaved.
    fetchSavedMixes(std::move(cb));
}

void TidalClient::addMixFavorite(const QString &mixId, std::function<void(bool)> cb) {
    if (mixId.isEmpty()) { cb(false); return; }
    m_api->putV2(mixFavoriteEndpoint(true), mixFavoriteQuery({mixId}),
        [cb, mixId](QJsonObject reply, QString err) {
            // An error is a refusal, and so is a 200 whose addedItems does
            // not name the mix.
            cb(err.isEmpty() && mixFavoriteAccepted(reply, mixId, true));
        });
}

void TidalClient::removeMixFavorite(const QString &mixId, std::function<void(bool)> cb) {
    if (mixId.isEmpty()) { cb(false); return; }
    m_api->putV2(mixFavoriteEndpoint(false), mixFavoriteQuery({mixId}),
        [cb, mixId](QJsonObject reply, QString err) {
            cb(err.isEmpty() && mixFavoriteAccepted(reply, mixId, false));
        });
}

// ─── Streaming ─────────────────────────────────────

void TidalClient::fetchStreamManifest(qint64 trackId, StreamCb cb) {
    fetchStreamManifest(trackId, m_quality, std::move(cb));
}

// Maps the manifest's delivery format to the tier strings that
// Player::audioQuality() and Downloader::srcTier compare
// StreamManifest::codec against.
static QString tierForFormat(const QString &format) {
    if (format == QStringLiteral("FLAC_HIRES")) return QStringLiteral("HI_RES_LOSSLESS");
    if (format == QStringLiteral("FLAC"))       return QStringLiteral("LOSSLESS");
    if (format == QStringLiteral("AACLC"))      return QStringLiteral("HIGH");
    if (format == QStringLiteral("HEAACV1"))    return QStringLiteral("LOW");
    return format;
}

bool TidalClient::usesTrackManifests(AudioQuality q) {
    return q == AudioQuality::Lossless || q == AudioQuality::HiResLossless;
}

QStringList TidalClient::manifestFormats(AudioQuality q) {
    switch (q) {
        case AudioQuality::Low96k:  return {QStringLiteral("HEAACV1")};
        case AudioQuality::Low320k: return {QStringLiteral("AACLC")};
        // FLAC alone: the endpoint returns the best format offered, so adding
        // FLAC_HIRES would give the 16-bit setting a 24-bit stream.
        case AudioQuality::Lossless: return {QStringLiteral("FLAC")};
        // Both: FLAC_HIRES alone falls back to AAC on a track with no hi-res
        // master.
        case AudioQuality::HiResLossless:
            return {QStringLiteral("FLAC"), QStringLiteral("FLAC_HIRES")};
    }
    return {QStringLiteral("FLAC")};
}

StreamManifest TidalClient::parseTrackManifests(const QJsonObject &root, QString *err) {
    // Cleared up front, so a reused QString cannot carry a stale message.
    if (err) err->clear();

    const QJsonObject attrs = root["data"].toObject()["attributes"].toObject();

    // This endpoint has no assetpresentation parameter. The body says what it
    // gave, so a preview is refused here.
    const QString presentation = attrs["trackPresentation"].toString();
    if (presentation == QStringLiteral("PREVIEW")) {
        if (err) *err = tr("Tidal returned only a preview of this track, not the whole track.");
        // The track exists and this account does not get the whole of it.
        StreamManifest preview;
        preview.reason = StreamManifest::NotForAccount;
        return preview;
    }
    if (presentation != QStringLiteral("FULL")) {
        if (err) *err = tr("Tidal did not return a playable manifest for this track.");
        return {};
    }

    // uriScheme=DATA, so the manifest arrives inline as data:<mime>;base64,<...>
    const QString uri   = attrs["uri"].toString();
    const int     comma = uri.indexOf(QLatin1Char(','));
    const QString mime  = uri.startsWith(QLatin1String("data:")) && comma > 5
                        ? uri.mid(5, comma - 5).section(QLatin1Char(';'), 0, 0)
                        : QString();
    const QByteArray body = mime.isEmpty() ? QByteArray()
                                           : QByteArray::fromBase64(uri.mid(comma + 1).toUtf8());
    if (mime != QStringLiteral("application/dash+xml") || !body.contains("<MPD")) {
        if (err) *err = tr("Tidal did not return a playable manifest for this track.");
        return {};
    }

    StreamManifest m;
    m.type     = StreamManifest::MPD;
    m.mimeType = QStringLiteral("application/dash+xml");
    m.url      = QString::fromUtf8(body);
    m.replayGainTrack = attrs["trackAudioNormalizationData"].toObject()["replayGain"].toDouble();
    m.replayGainAlbum = attrs["albumAudioNormalizationData"].toObject()["replayGain"].toDouble();

    // Format, sample rate and bit depth live only in the Representation id:
    // "FLAC,44100,16", or a bare "AACLC" with neither number.
    // attributes.formats names the format too and is the fallback.
    QString format;
    const QJsonArray formats = attrs["formats"].toArray();
    if (!formats.isEmpty()) format = formats.first().toString();

    const QLatin1String marker("<Representation id=\"");
    const qsizetype at = m.url.indexOf(marker);
    if (at >= 0) {
        const qsizetype from = at + marker.size();
        const qsizetype end  = m.url.indexOf(QLatin1Char('"'), from);
        if (end > from) {
            const QStringList bits = m.url.mid(from, end - from).split(QLatin1Char(','));
            if (!bits.first().isEmpty()) format = bits.first();
            // Left at the CD defaults when the id has no usable numbers:
            // Downloader picks its PCM width off bitDepth.
            if (bits.size() >= 3) {
                bool ok = false;
                const int rate = bits[1].toInt(&ok);
                if (ok && rate > 0) m.sampleRate = rate;
                const int depth = bits[2].toInt(&ok);
                if (ok && depth > 0) m.bitDepth = depth;
            }
        }
    }
    m.codec = tierForFormat(format);
    return m;
}

StreamManifest::Reason TidalClient::refusalReason(bool openApi, int httpStatus,
                                                  const QJsonObject &body) {
    if (httpStatus == 404 || httpStatus == 410) return StreamManifest::Gone;
    if (openApi) {
        // JSON:API: {errors: [{code}]}.
        if (httpStatus != 403) return StreamManifest::Unknown;
        const QJsonArray errors = body["errors"].toArray();
        for (const QJsonValue &e : errors)
            if (e.toObject()["code"].toString() == QLatin1String("GEO_RESTRICTED"))
                return StreamManifest::NotForAccount;
        return StreamManifest::Unknown;
    }
    // "Asset is not ready for playback", the v1 answer for a track that
    // tracks/<id> answers with 404. Any other 401 is about the session.
    if (httpStatus == 401 && body["subStatus"].toInt() == 4005) return StreamManifest::Gone;
    return StreamManifest::Unknown;
}

// What goes with the error of a refused stream request.
static StreamManifest refusedManifest(StreamManifest::Reason reason) {
    StreamManifest m;
    m.reason = reason;
    return m;
}

void TidalClient::fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb) {
    // tracks/<id>/playbackinfopostpaywall answers a LOSSLESS request with
    // 320 kbps AAC for this client id, so the FLAC tiers go to
    // v2/trackManifests. The lossy tiers stay: they come as one BTS file.
    if (usesTrackManifests(quality)) {
        QUrlQuery q;
        for (const QString &format : manifestFormats(quality))
            q.addQueryItem("formats", format);
        q.addQueryItem("manifestType", "MPEG_DASH");
        q.addQueryItem("uriScheme",    "DATA");
        // One Representation: DashFetcher ignores any after the first.
        q.addQueryItem("adaptive",     "false");
        q.addQueryItem("usage",        "PLAYBACK");

        m_api->getOpenApiWithStatus(QStringLiteral("trackManifests/%1").arg(trackId), q,
            [cb](QJsonObject root, QString err, int httpStatus) {
                if (!err.isEmpty()) {
                    cb(refusedManifest(refusalReason(true, httpStatus, root)), err);
                    return;
                }
                QString parseErr;
                const StreamManifest m = parseTrackManifests(root, &parseErr);
                // With an error the manifest holds the reason and nothing else.
                cb(m, parseErr);
            });
        return;
    }

    QUrlQuery q;
    q.addQueryItem("playbackmode",      "STREAM");
    q.addQueryItem("assetpresentation", "FULL");
    q.addQueryItem("audioquality",      qualityString(quality));
    q.addQueryItem("prefetch",          "false");

    m_api->getWithStatus(QStringLiteral("tracks/%1/playbackinfopostpaywall").arg(trackId), q,
        [cb](QJsonObject root, QString err, int httpStatus) {
            if (!err.isEmpty()) {
                cb(refusedManifest(refusalReason(false, httpStatus, root)), err);
                return;
            }

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
                // BTS: JSON with a URL array.
                auto bts = QJsonDocument::fromJson(manifestData).object();
                auto urls = bts["urls"].toArray();
                if (!urls.isEmpty()) {
                    m.type     = StreamManifest::BTS;
                    m.url      = urls[0].toString();
                    m.mimeType = bts["mimeType"].toString();
                }
            } else {
                // MPD: the MPEG-DASH manifest XML itself.
                m.type    = StreamManifest::MPD;
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
            // The dialog shows this string, so it is Tidal's own sentence or
            // empty: the network layer's holds the request URL. The playlist
            // without a uuid is what says it failed.
            if (!err.isEmpty()) { cb({}, root["userMessage"].toString()); return; }
            cb(Playlist::fromJson(root), {});
        });
}

void TidalClient::editPlaylist(const QString &uuid, const QString &title,
    const QString &description, std::function<void(bool)> cb)
{
    // Both fields go every time: the endpoint replaces what it is sent, so
    // posting only the title would clear the description.
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
    // The contributor list first: only its failure fails the call. The two
    // requests chained behind it add to the result, so their errors are
    // swallowed and their fields stay empty.
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
                    // streamStartDate is when the catalogue got the track, so
                    // it is not read. The release date is the album's.
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
