#include "TidalBridge.h"
#include <QJSEngine>

TidalBridge::TidalBridge(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client) {}

void TidalBridge::call(QJSValue &cb, const QJSValueList &args) {
    if (cb.isCallable()) cb.call(args);
}

// ─── Converters ────────────────────────────────────

QVariantMap TidalBridge::trackToMap(const Track &t) {
    QVariantMap m;
    m["id"]          = t.id;
    m["title"]       = t.title;
    m["artists"]     = t.artistNames();
    m["artistId"]    = t.artists.isEmpty() ? 0LL : t.artists[0].id;
    m["albumTitle"]  = t.album.title;
    m["albumId"]     = t.album.id;
    m["albumCover"]  = t.album.cover;
    m["coverUrl"]    = t.coverUrl(320);
    m["coverUrl80"]  = t.coverUrl(80);
    m["duration"]    = t.duration;
    m["trackNumber"] = t.trackNumber;
    m["explicit_"]   = t.explicit_;
    m["quality"]     = t.audioQuality;
    // pre-computed display
    int s = t.duration % 60, mm = t.duration / 60;
    m["durationStr"] = QString("%1:%2").arg(mm).arg(s, 2, 10, QChar('0'));
    return m;
}

QVariantMap TidalBridge::albumToMap(const Album &a) {
    QVariantMap m;
    m["id"]          = a.id;
    m["title"]       = a.title;
    m["artists"]     = a.artistNames();
    m["artistId"]    = a.artists.isEmpty() ? 0LL : a.artists[0].id;
    m["coverUrl"]    = a.coverUrl(320);
    m["coverUrl640"] = a.coverUrl(640);
    m["releaseDate"] = a.releaseDate;
    m["numTracks"]   = a.numTracks;
    m["quality"]     = a.audioQuality;
    m["year"]        = a.releaseDate.left(4);
    return m;
}

QVariantMap TidalBridge::artistToMap(const Artist &a) {
    QVariantMap m;
    m["id"]   = a.id;
    m["name"] = a.name;
    if (!a.picture.isEmpty()) {
        QString u = a.picture; u.replace('-', '/');
        m["coverUrl"] = QStringLiteral("https://resources.tidal.com/images/%1/320x320.jpg").arg(u);
        m["coverUrl480"] = QStringLiteral("https://resources.tidal.com/images/%1/480x480.jpg").arg(u);
    }
    return m;
}

QVariantMap TidalBridge::playlistToMap(const Playlist &p) {
    QVariantMap m;
    m["uuid"]      = p.uuid;
    m["title"]     = p.title;
    m["numTracks"] = p.numTracks;
    m["coverUrl"]  = p.coverUrl(320);
    return m;
}

QVariantMap TidalBridge::mixToMap(const Mix &m_) {
    QVariantMap m;
    m["id"]       = m_.id;
    m["title"]    = m_.title;
    m["subtitle"] = m_.subTitle;
    m["coverUrl"] = m_.coverUrl(320);
    return m;
}

QVariantList TidalBridge::tracksToList(const QList<Track> &v) {
    QVariantList r; for (const auto &t : v) r << trackToMap(t); return r;
}
QVariantList TidalBridge::albumsToList(const QList<Album> &v) {
    QVariantList r; for (const auto &a : v) r << albumToMap(a); return r;
}
QVariantList TidalBridge::artistsToList(const QList<Artist> &v) {
    QVariantList r; for (const auto &a : v) r << artistToMap(a); return r;
}
QVariantList TidalBridge::playlistsList(const QList<Playlist> &v) {
    QVariantList r; for (const auto &p : v) r << playlistToMap(p); return r;
}
QVariantList TidalBridge::mixesList(const QList<Mix> &v) {
    QVariantList r; for (const auto &m : v) r << mixToMap(m); return r;
}

// ─── Public Q_INVOKABLE methods ────────────────────

void TidalBridge::fetchHomeMixes(QJSValue cb) {
    m_client->fetchHomeMixes([this, cb](QList<Mix> mixes, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(mixesList(mixes)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchMixTracks(const QString &mixId, QJSValue cb) {
    m_client->fetchMixTracks(mixId, [this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchFavoriteTracks(QJSValue cb, int limit, int offset) {
    m_client->fetchFavoriteTracks([this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

void TidalBridge::fetchFavoriteAlbums(QJSValue cb, int limit, int offset) {
    m_client->fetchFavoriteAlbums([this, cb](QList<Album> albums, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(albumsToList(albums)),
                   qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

void TidalBridge::fetchFavoriteArtists(QJSValue cb, int limit, int offset) {
    m_client->fetchFavoriteArtists([this, cb](QList<Artist> artists, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(artistsToList(artists)),
                   qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

void TidalBridge::fetchUserPlaylists(QJSValue cb, int limit, int offset) {
    m_client->fetchUserPlaylists([this, cb](QList<Playlist> playlists, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(playlistsList(playlists)),
                   qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

void TidalBridge::fetchAlbumTracks(qlonglong albumId, QJSValue cb) {
    m_client->fetchAlbumTracks(albumId, [this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchPlaylistTracks(const QString &uuid, QJSValue cb) {
    m_client->fetchPlaylistTracks(uuid, [this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchAlbum(qlonglong albumId, QJSValue cb) {
    m_client->fetchAlbum(albumId, [this, cb](Album album, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(albumToMap(album)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchArtistDetail(qlonglong artistId, QJSValue cb) {
    m_client->fetchArtistDetail(artistId, [this, cb](ArtistDetail d, QString err) mutable {
        QVariantMap m;
        m["id"]      = d.id;
        m["name"]    = d.name;
        m["bio"]     = d.bio;
        if (!d.picture.isEmpty()) {
            QString u = d.picture; u.replace('-', '/');
            m["coverUrl"]    = QStringLiteral("https://resources.tidal.com/images/%1/480x480.jpg").arg(u);
            m["coverUrl750"] = QStringLiteral("https://resources.tidal.com/images/%1/750x750.jpg").arg(u);
        }
        call(cb, { qjsEngine(this)->toScriptValue(m), qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchArtistAlbums(qlonglong artistId, QJSValue cb) {
    m_client->fetchArtistAlbums(artistId, [this, cb](QList<Album> albums, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(albumsToList(albums)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchArtistTopTracks(qlonglong artistId, QJSValue cb) {
    m_client->fetchArtistTopTracks(artistId, [this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::search(const QString &q, QJSValue cb, int limit) {
    m_client->search(q, [this, cb](SearchResults r, QString err) mutable {
        QVariantMap res;
        res["tracks"]    = tracksToList(r.tracks);
        res["albums"]    = albumsToList(r.albums);
        res["artists"]   = artistsToList(r.artists);
        res["playlists"] = playlistsList(r.playlists);
        call(cb, { qjsEngine(this)->toScriptValue(res), qjsEngine(this)->toScriptValue(err) });
    }, limit);
}
