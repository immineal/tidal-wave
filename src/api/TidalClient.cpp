#include "TidalClient.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QByteArray>
#include <QDebug>

TidalClient::TidalClient(TidalApi *api, QObject *parent)
    : QObject(parent), m_api(api) {}

QString TidalClient::qualityString() const {
    switch (m_quality) {
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

QList<Album> TidalClient::parseAlbums(const QJsonObject &root) {
    QList<Album> out;
    for (const auto &v : root["items"].toArray()) {
        auto obj = v.toObject();
        if (obj.contains("item")) obj = obj["item"].toObject();
        if (obj.contains("id"))   out.append(Album::fromJson(obj));
    }
    return out;
}

QList<Artist> TidalClient::parseArtists(const QJsonObject &root) {
    QList<Artist> out;
    for (const auto &v : root["items"].toArray()) {
        auto obj = v.toObject();
        if (obj.contains("item")) obj = obj["item"].toObject();
        if (obj.contains("id"))   out.append(Artist::fromJson(obj));
    }
    return out;
}

QList<Playlist> TidalClient::parsePlaylists(const QJsonObject &root) {
    QList<Playlist> out;
    for (const auto &v : root["items"].toArray()) {
        auto obj = v.toObject();
        if (obj.contains("playlist")) obj = obj["playlist"].toObject();
        else if (obj.contains("item")) obj = obj["item"].toObject();
        if (obj.contains("uuid") || obj.contains("id"))
            out.append(Playlist::fromJson(obj));
    }
    return out;
}

// ─── Mixes / Home ──────────────────────────────────

void TidalClient::fetchHomeMixes(MixesCallback cb) {
    QUrlQuery q;
    q.addQueryItem("deviceType", "BROWSER");
    m_api->get(QStringLiteral("pages/my_collection_my_mixes"), q,
        [cb](QJsonObject root, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            QList<Mix> mixes;
            // Navigate the nested page structure
            for (const auto &row : root["rows"].toArray()) {
                for (const auto &module : row.toObject()["modules"].toArray()) {
                    auto mod = module.toObject();
                    if (mod["type"].toString() != "MIX_LIST") continue;
                    for (const auto &item : mod["pagedList"].toObject()["items"].toArray())
                        mixes.append(Mix::fromJson(item.toObject()));
                }
            }
            cb(mixes, {});
        });
}

void TidalClient::fetchMixTracks(const QString &mixId, TracksCallback cb) {
    QUrlQuery q;
    q.addQueryItem("mixId", mixId);
    q.addQueryItem("deviceType", "BROWSER");
    m_api->get(QStringLiteral("pages/mix"), q, [this, cb](QJsonObject root, QString err) {
        if (!err.isEmpty()) { cb({}, err); return; }
        QList<Track> tracks;
        for (const auto &row : root["rows"].toArray())
            for (const auto &module : row.toObject()["modules"].toArray()) {
                auto mod = module.toObject();
                if (mod["type"].toString() != "TRACK_LIST") continue;
                tracks.append(parseTracks(mod["pagedList"].toObject()));
            }
        cb(tracks, {});
    });
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
    m_api->get(QStringLiteral("users/%1/favorites/albums").arg(m_userId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseAlbums(root) : QList<Album>{}, err); });
}

void TidalClient::fetchFavoriteArtists(ArtistsCallback cb, int limit, int offset) {
    QUrlQuery q;
    q.addQueryItem("limit", QString::number(limit));
    q.addQueryItem("offset", QString::number(offset));
    m_api->get(QStringLiteral("users/%1/favorites/artists").arg(m_userId), q,
        [this, cb](QJsonObject root, QString err) {
            cb(err.isEmpty() ? parseArtists(root) : QList<Artist>{}, err); });
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

void TidalClient::search(const QString &query, SearchCb cb, int limit) {
    QUrlQuery q;
    q.addQueryItem("query", query);
    q.addQueryItem("limit", QString::number(limit));
    q.addQueryItem("types", "TRACKS,ALBUMS,ARTISTS,PLAYLISTS");
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
    Q_UNUSED(albumId); Q_UNUSED(cb);
}

void TidalClient::addArtistFavorite(qint64 artistId, std::function<void(bool)> cb) {
    Q_UNUSED(artistId); Q_UNUSED(cb);
}

// ─── Streaming ─────────────────────────────────────

void TidalClient::fetchStreamManifest(qint64 trackId, StreamCb cb) {
    QUrlQuery q;
    q.addQueryItem("playbackmode",      "STREAM");
    q.addQueryItem("assetpresentation", "FULL");
    q.addQueryItem("audioquality",      qualityString());
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
    Q_UNUSED(title); Q_UNUSED(cb);
}

void TidalClient::addTrackToPlaylist(const QString &uuid, qint64 trackId,
    std::function<void(bool)> cb)
{
    Q_UNUSED(uuid); Q_UNUSED(trackId); Q_UNUSED(cb);
}
