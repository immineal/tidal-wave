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

// The union of several album lists, in the order the lists were given, one row
// per album id. Unlike a mix a release has nothing to merge *into* the kept
// record - the three filtered responses carry the same fields - so the first
// one to carry an id simply wins, which is what keeps the albums at the front
// of the list and the compilations behind them.
//
// The dedup is not theoretical: a release can answer to two filters at once
// (an EP that the unfiltered request also lists, a compilation that is also
// filed as "other"), and without this the discography would show it twice.
QList<Album> TidalClient::mergeAlbumLists(const QList<QList<Album>> &lists) {
    QList<Album> out;
    QSet<qint64> seen;
    for (const QList<Album> &list : lists) {
        for (const Album &a : list) {
            // id 0 is "the response carried no id", which parseAlbums already
            // drops; kept rather than collapsed so a future caller cannot have
            // several distinct releases merged into one by a missing field.
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
                                       AlbumsCallback cb, int offset, QList<Album> acc)
{
    QUrlQuery q;
    if (!filter.isEmpty()) q.addQueryItem("filter", filter);
    q.addQueryItem("limit", QString::number(kArtistAlbumsPageSize));
    q.addQueryItem("offset", QString::number(offset));
    m_api->get(QStringLiteral("artists/%1/albums").arg(artistId), q,
        [this, artistId, filter, cb, offset, acc](QJsonObject root, QString err) mutable {
            if (!err.isEmpty()) {
                // Whatever the earlier pages of *this* filter delivered is
                // still worth having; the error is only news when nothing is.
                cb(acc, acc.isEmpty() ? err : QString());
                return;
            }
            const QList<Album> page = parseAlbums(root);
            acc.append(page);
            const int total = root["totalNumberOfItems"].toInt(acc.size());
            if (page.isEmpty() || acc.size() >= total || acc.size() >= kMaxArtistAlbums) {
                cb(acc, {});
                return;
            }
            fetchArtistAlbumPage(artistId, filter, cb, offset + int(page.size()), acc);
        });
}

void TidalClient::fetchArtistAlbums(qint64 artistId, AlbumsCallback cb) {
    // One discography, three requests. See kFilterEpsAndSingles: the unfiltered
    // request answers the albums and nothing else, which is why the Singles &
    // EPs section of ArtistPage had been empty - and therefore invisible -
    // since it was written. The page's own sectioning is unchanged; it was
    // never given anything to section.
    //
    // Merged here and not in QML on purpose: ArtistPage opens this beside
    // fetchArtistDetail() and fetchArtistTopTracks() behind one `loading` flag
    // and one superseded-request guard, so three replies arriving separately
    // would each have had to avoid clearing `loading` early and avoid blanking
    // the other two. One reply out of here keeps that page exactly as correct
    // as it already was. Same Pending/finish shape as fetchHomeMixes().
    struct Pending {
        QList<Album> albums;
        QList<Album> epsAndSingles;
        QList<Album> compilations;
        int          outstanding = 3;
        QString      err;
    };
    const auto pending = std::make_shared<Pending>();

    const auto finish = [cb, pending]() {
        if (--pending->outstanding > 0) return;
        const QList<Album> all = mergeAlbumLists(
            {pending->albums, pending->epsAndSingles, pending->compilations});
        // One filter failing must not empty the page: an artist whose albums
        // came back and whose compilations did not still has a discography,
        // and ArtistPage's loadFailed only fires when nothing at all arrived.
        // The error is reported only when none of the three yielded anything.
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

    // Albums first, so mergeAlbumLists() leaves a release that answers to two
    // filters where the album list put it.
    fetchArtistAlbumPage(artistId, QString(), collect(&pending->albums));
    fetchArtistAlbumPage(artistId, QString::fromLatin1(kFilterEpsAndSingles),
                         collect(&pending->epsAndSingles));
    fetchArtistAlbumPage(artistId, QString::fromLatin1(kFilterCompilations),
                         collect(&pending->compilations));
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
    // The saved half of fetchHomeMixes() on its own. The merged list cannot
    // serve here: it folds the generated feed in, and a generated mix is not
    // something the user saved and cannot be unsaved - so answering "is this
    // mix a favourite" off the merge would offer an Unsave on all eight of
    // "My Mix 1".."My Mix 8".
    fetchSavedMixes(std::move(cb));
}

void TidalClient::addMixFavorite(const QString &mixId, std::function<void(bool)> cb) {
    if (mixId.isEmpty()) { cb(false); return; }
    m_api->putV2(mixFavoriteEndpoint(true), mixFavoriteQuery({mixId}),
        [cb, mixId](QJsonObject reply, QString err) {
            // Both halves. An error is a refusal, and so is a 200 whose
            // addedItems does not name the mix.
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

// The delivery format Tidal names in a manifest, in the tier vocabulary the rest
// of the app speaks: Player::audioQuality() and Downloader::srcTier both compare
// StreamManifest::codec against these exact strings.
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
        // FLAC alone, deliberately: the endpoint hands back the best format it is
        // offered that the track has, so adding FLAC_HIRES here would give a
        // 24-bit stream to the setting labelled "Lossless (16-bit)".
        case AudioQuality::Lossless: return {QStringLiteral("FLAC")};
        // Both, equally deliberately: FLAC_HIRES on its own falls back to AAC on
        // a track with no hi-res master, and most tracks have none.
        case AudioQuality::HiResLossless:
            return {QStringLiteral("FLAC"), QStringLiteral("FLAC_HIRES")};
    }
    return {QStringLiteral("FLAC")};
}

StreamManifest TidalClient::parseTrackManifests(const QJsonObject &root, QString *err) {
    // Cleared up front, so a caller reusing a QString cannot read a stale
    // message as this call's failure.
    if (err) err->clear();

    const QJsonObject attrs = root["data"].toObject()["attributes"].toObject();

    // There is no assetpresentation parameter on this endpoint - the old one had
    // it, and errored rather than answer with a clip. Here the body says what it
    // gave, so refusing a preview is this function's job.
    const QString presentation = attrs["trackPresentation"].toString();
    if (presentation != QStringLiteral("FULL")) {
        if (err) *err = tr("Tidal returned only a preview of this track, not the whole track.");
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

    // The delivered format, sample rate and bit depth live in the Representation
    // id - "FLAC,44100,16", "FLAC_HIRES,96000,24", or a bare "AACLC" with neither
    // number. Nowhere else in this response carries them; the old endpoint had
    // them as top-level fields. attributes.formats names the format too, and is
    // the fallback, but only the id has the numbers.
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
            // Left at the CD defaults when the id carries no numbers, or carries
            // ones that do not parse: 0 would read as "not hi-res" only by
            // accident, and Downloader picks its PCM width off bitDepth.
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

void TidalClient::fetchStreamManifest(qint64 trackId, AudioQuality quality, StreamCb cb) {
    // The FLAC tiers do not come from tracks/<id>/playbackinfopostpaywall any
    // more. Measured against the live API on 2026-10-04, on this client id and a
    // current session, that endpoint answers an audioquality=LOSSLESS request
    // with audioQuality HIGH and a 320 kbps AAC manifest on 27 of 27 catalogue
    // tracks - including tracks whose mediaMetadata.tags say LOSSLESS, and with
    // the identical manifestHash it returns for audioquality=HIGH, so the two
    // settings were fetching one identical file. It is not the account (the same
    // token is served 24/192 FLAC), the region, or the tracks, and no parameter
    // changes it; a misspelt audioquality 404s, so the server reads the value and
    // downgrades it deliberately. v2/trackManifests serves the same 27 tracks as
    // FLAC on the same token. See tests/tst_stream_manifest.cpp.
    //
    // The lossy tiers stay here: the old endpoint still serves those honestly,
    // and serves them as a single BTS file rather than DASH segments that have to
    // be joined before the first note.
    if (usesTrackManifests(quality)) {
        QUrlQuery q;
        for (const QString &format : manifestFormats(quality))
            q.addQueryItem("formats", format);
        q.addQueryItem("manifestType", "MPEG_DASH");
        q.addQueryItem("uriScheme",    "DATA");
        // adaptive=false keeps it to one Representation. There is nothing to
        // adapt to here - DashFetcher pulls every segment before a note plays and
        // ignores any Representation after the first.
        q.addQueryItem("adaptive",     "false");
        q.addQueryItem("usage",        "PLAYBACK");

        m_api->getOpenApi(QStringLiteral("trackManifests/%1").arg(trackId), q,
            [cb](QJsonObject root, QString err) {
                if (!err.isEmpty()) { cb({}, err); return; }
                QString parseErr;
                const StreamManifest m = parseTrackManifests(root, &parseErr);
                if (!parseErr.isEmpty()) { cb({}, parseErr); return; }
                cb(m, {});
            });
        return;
    }

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
