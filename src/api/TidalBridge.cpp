#include "TidalBridge.h"
#include <QJSEngine>
#include <QSettings>
#include <QGuiApplication>
#include <QClipboard>

TidalBridge::TidalBridge(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    QSettings settings;
    QString saved = settings.value(QStringLiteral("audio/preferredQuality"), QStringLiteral("LOSSLESS")).toString();
    setPreferredQuality(saved);

    connect(m_client, &TidalClient::userIdChanged, this, [this](qint64 uid) {
        if (uid > 0) {
            loadFavoriteTrackIds();
        } else {
            m_favoriteTrackIds.clear();
            m_favoriteTracks.clear();
            m_favoriteAlbums.clear();
            m_favoriteArtists.clear();
            m_favoritePlaylists.clear();
            emit favoriteTracksChanged();
            emit favoriteAlbumsChanged();
            emit favoriteArtistsChanged();
            emit favoritePlaylistsChanged();
        }
    });

    if (m_client->userId() > 0) {
        loadFavoriteTrackIds();
    }
}

QString TidalBridge::preferredQuality() const {
    switch (m_client->audioQuality()) {
        case AudioQuality::Low96k:        return QStringLiteral("LOW");
        case AudioQuality::Low320k:       return QStringLiteral("HIGH");
        case AudioQuality::Lossless:      return QStringLiteral("LOSSLESS");
        case AudioQuality::HiResLossless: return QStringLiteral("HI_RES_LOSSLESS");
    }
    return QStringLiteral("LOSSLESS");
}

void TidalBridge::setPreferredQuality(const QString &q) {
    AudioQuality quality;
    if      (q == QStringLiteral("LOW"))             quality = AudioQuality::Low96k;
    else if (q == QStringLiteral("HIGH"))            quality = AudioQuality::Low320k;
    else if (q == QStringLiteral("HI_RES_LOSSLESS")) quality = AudioQuality::HiResLossless;
    else                                             quality = AudioQuality::Lossless;

    if (quality == m_client->audioQuality()) return;

    m_client->setAudioQuality(quality);
    QSettings settings;
    settings.setValue(QStringLiteral("audio/preferredQuality"), preferredQuality());
    emit preferredQualityChanged();
}

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
    m["popularity"]  = t.popularity;
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
    m["duration"]    = a.duration;
    m["quality"]     = a.audioQuality;
    m["type"]        = a.type;
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
    m["uuid"]        = p.uuid;
    m["title"]       = p.title;
    m["description"] = p.description;
    m["numTracks"]   = p.numTracks;
    m["duration"]    = p.duration;
    m["coverUrl"]    = p.coverUrl(320);
    m["type"]        = p.type;
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

QVariantList TidalBridge::tracksToList(const QList<Track> &v) const {
    QVariantList r; for (const auto &t : v) r << trackToMap(t); return r;
}
QVariantList TidalBridge::albumsToList(const QList<Album> &v) const {
    QVariantList r; for (const auto &a : v) r << albumToMap(a); return r;
}
QVariantList TidalBridge::artistsToList(const QList<Artist> &v) const {
    QVariantList r; for (const auto &a : v) r << artistToMap(a); return r;
}
QVariantList TidalBridge::playlistsList(const QList<Playlist> &v) const {
    QVariantList r; for (const auto &p : v) r << playlistToMap(p); return r;
}
QVariantList TidalBridge::mixesList(const QList<Mix> &v) const {
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
        sortPlaylists(playlists);
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

bool TidalBridge::isTrackFavorite(qlonglong trackId) const {
    return m_favoriteTrackIds.contains(trackId);
}

void TidalBridge::addTrackFavorite(qlonglong trackId, QJSValue cb) {
    m_client->addTrackFavorite(trackId, [this, trackId, cb](bool success) mutable {
        if (success) {
            m_favoriteTrackIds.insert(trackId);
            emit favoriteTracksChanged();
            m_client->fetchTrack(trackId, [this](Track t, QString err) {
                if (err.isEmpty() && t.id > 0) {
                    m_favoriteTracks.append(t);
                    emit favoriteTracksChanged();
                }
            });
        }
        call(cb, { success });
    });
}

void TidalBridge::removeTrackFavorite(qlonglong trackId, QJSValue cb) {
    m_client->removeTrackFavorite(trackId, [this, trackId, cb](bool success) mutable {
        if (success) {
            m_favoriteTrackIds.remove(trackId);
            for (int i = 0; i < m_favoriteTracks.size(); ++i) {
                if (m_favoriteTracks[i].id == trackId) {
                    m_favoriteTracks.removeAt(i);
                    break;
                }
            }
            emit favoriteTracksChanged();
        }
        call(cb, { success });
    });
}

void TidalBridge::copyToClipboard(const QString &text) {
    QGuiApplication::clipboard()->setText(text);
}

bool TidalBridge::isAlbumFavorite(qlonglong albumId) const {
    for (const auto &a : m_favoriteAlbums)
        if (a.id == albumId) return true;
    return false;
}

void TidalBridge::addAlbumFavorite(qlonglong albumId, QJSValue cb) {
    m_client->addAlbumFavorite(albumId, [this, albumId, cb](bool success) mutable {
        if (success) emit favoriteAlbumsChanged();
        call(cb, { success });
    });
}

void TidalBridge::removeAlbumFavorite(qlonglong albumId, QJSValue cb) {
    m_client->removeAlbumFavorite(albumId, [this, albumId, cb](bool success) mutable {
        if (success) {
            for (int i = 0; i < m_favoriteAlbums.size(); ++i) {
                if (m_favoriteAlbums[i].id == albumId) { m_favoriteAlbums.removeAt(i); break; }
            }
            emit favoriteAlbumsChanged();
        }
        call(cb, { success });
    });
}

bool TidalBridge::isArtistFavorite(qlonglong artistId) const {
    for (const auto &a : m_favoriteArtists)
        if (a.id == artistId) return true;
    return false;
}

void TidalBridge::addArtistFavorite(qlonglong artistId, QJSValue cb) {
    m_client->addArtistFavorite(artistId, [this, artistId, cb](bool success) mutable {
        if (success) emit favoriteArtistsChanged();
        call(cb, { success });
    });
}

void TidalBridge::removeArtistFavorite(qlonglong artistId, QJSValue cb) {
    m_client->removeArtistFavorite(artistId, [this, artistId, cb](bool success) mutable {
        if (success) {
            for (int i = 0; i < m_favoriteArtists.size(); ++i) {
                if (m_favoriteArtists[i].id == artistId) { m_favoriteArtists.removeAt(i); break; }
            }
            emit favoriteArtistsChanged();
        }
        call(cb, { success });
    });
}

void TidalBridge::createPlaylist(const QString &title, QJSValue cb) {
    m_client->createPlaylist(title, [this, cb](Playlist p, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(playlistToMap(p)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::addTracksToPlaylist(const QString &uuid, qlonglong trackId, QJSValue cb) {
    m_client->addTrackToPlaylist(uuid, trackId, [this, cb](bool success) mutable {
        call(cb, { success });
    });
}

void TidalBridge::removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb) {
    m_client->removeTrackFromPlaylist(uuid, itemIndex, [this, cb](bool success) mutable {
        call(cb, { success });
    });
}

QVariantList TidalBridge::getUserPlaylists() const {
    QList<Playlist> playlists = m_favoritePlaylists;
    sortPlaylists(playlists);
    return playlistsList(playlists);
}

void TidalBridge::fetchTrackRadio(qlonglong trackId, QJSValue cb) {
    m_client->fetchTrackRadio(trackId, [this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchLyrics(qlonglong trackId, QJSValue cb) {
    m_client->fetchLyrics(trackId, [this, cb](QString text, bool timed, QString err) mutable {
        QVariantMap result;
        result["text"]  = text;
        result["timed"] = timed;
        call(cb, { qjsEngine(this)->toScriptValue(result), qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchRecentlyPlayed(QJSValue cb) {
    m_client->fetchRecentlyPlayed([this, cb](QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(tracksToList(tracks)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

QVariantList TidalBridge::searchFavoriteTracks(const QString &query) const {
    QVariantList list;
    QString lowered = query.toLower();
    for (const auto &t : m_favoriteTracks) {
        if (lowered.isEmpty() ||
            t.title.toLower().contains(lowered) ||
            t.artistNames().toLower().contains(lowered) ||
            t.album.title.toLower().contains(lowered)) {
            list.append(trackToMap(t));
        }
    }
    return list;
}

QVariantList TidalBridge::searchFavoriteAlbums(const QString &query) const {
    QVariantList list;
    QString lowered = query.toLower();
    for (const auto &a : m_favoriteAlbums) {
        if (lowered.isEmpty() ||
            a.title.toLower().contains(lowered) ||
            a.artistNames().toLower().contains(lowered)) {
            list.append(albumToMap(a));
        }
    }
    return list;
}

QVariantList TidalBridge::searchFavoriteArtists(const QString &query) const {
    QVariantList list;
    QString lowered = query.toLower();
    for (const auto &a : m_favoriteArtists) {
        if (lowered.isEmpty() ||
            a.name.toLower().contains(lowered)) {
            list.append(artistToMap(a));
        }
    }
    return list;
}

QVariantList TidalBridge::searchFavoritePlaylists(const QString &query) const {
    QList<Playlist> playlists;
    QString lowered = query.toLower();
    for (const auto &p : m_favoritePlaylists) {
        if (lowered.isEmpty() ||
            p.title.toLower().contains(lowered)) {
            playlists.append(p);
        }
    }
    sortPlaylists(playlists);
    return playlistsList(playlists);
}

void TidalBridge::loadFavoriteTrackIds() {
    m_favoriteTrackIds.clear();
    m_favoriteTracks.clear();
    m_favoriteAlbums.clear();
    m_favoriteArtists.clear();
    m_favoritePlaylists.clear();

    loadNextFavoriteTracksPage(0);
    loadNextFavoriteAlbumsPage(0);
    loadNextFavoriteArtistsPage(0);
    loadNextUserPlaylistsPage(0);
}

void TidalBridge::loadNextFavoriteTracksPage(int offset) {
    if (m_client->userId() == 0) return;
    m_client->fetchFavoriteTracks([this, offset](QList<Track> tracks, QString err) {
        if (!err.isEmpty() || tracks.isEmpty()) {
            std::reverse(m_favoriteTracks.begin(), m_favoriteTracks.end());
            emit favoriteTracksChanged();
            return;
        }
        for (const auto &t : tracks) {
            m_favoriteTrackIds.insert(t.id);
            m_favoriteTracks.append(t);
        }
        if (offset == 0) {
            emit favoriteTracksChanged();
        }
        loadNextFavoriteTracksPage(offset + tracks.size());
    }, 100, offset);
}

void TidalBridge::loadNextFavoriteAlbumsPage(int offset) {
    if (m_client->userId() == 0) return;
    m_client->fetchFavoriteAlbums([this, offset](QList<Album> albums, QString err) {
        if (!err.isEmpty() || albums.isEmpty()) {
            emit favoriteAlbumsChanged();
            return;
        }
        m_favoriteAlbums.append(albums);
        if (offset == 0) {
            emit favoriteAlbumsChanged();
        }
        loadNextFavoriteAlbumsPage(offset + albums.size());
    }, 100, offset);
}

void TidalBridge::loadNextFavoriteArtistsPage(int offset) {
    if (m_client->userId() == 0) return;
    m_client->fetchFavoriteArtists([this, offset](QList<Artist> artists, QString err) {
        if (!err.isEmpty() || artists.isEmpty()) {
            emit favoriteArtistsChanged();
            return;
        }
        m_favoriteArtists.append(artists);
        if (offset == 0) {
            emit favoriteArtistsChanged();
        }
        loadNextFavoriteArtistsPage(offset + artists.size());
    }, 100, offset);
}

void TidalBridge::loadNextUserPlaylistsPage(int offset) {
    if (m_client->userId() == 0) return;
    m_client->fetchUserPlaylists([this, offset](QList<Playlist> playlists, QString err) {
        if (!err.isEmpty() || playlists.isEmpty()) {
            emit favoritePlaylistsChanged();
            return;
        }
        m_favoritePlaylists.append(playlists);
        if (offset == 0) {
            emit favoritePlaylistsChanged();
        }
        loadNextUserPlaylistsPage(offset + playlists.size());
    }, 50, offset);
}

void TidalBridge::markPlaylistPlayed(const QString &uuid) {
    if (uuid.isEmpty()) return;
    qint64 uid = m_client->userId();
    if (uid <= 0) return;

    QSettings settings;
    QString key = QStringLiteral("user_%1/playlists/lastPlayed").arg(uid);
    QVariantMap playtimes = settings.value(key).toMap();
    playtimes[uuid] = QDateTime::currentMSecsSinceEpoch();
    settings.setValue(key, playtimes);
    emit favoritePlaylistsChanged();
}

void TidalBridge::sortPlaylists(QList<Playlist> &playlists) const {
    qint64 uid = m_client->userId();
    if (uid <= 0) return;

    QSettings settings;
    QString key = QStringLiteral("user_%1/playlists/lastPlayed").arg(uid);
    QVariantMap playtimes = settings.value(key).toMap();

    std::stable_sort(playlists.begin(), playlists.end(), [&playtimes](const Playlist &a, const Playlist &b) {
        qint64 timeA = playtimes.value(a.uuid, 0LL).toLongLong();
        qint64 timeB = playtimes.value(b.uuid, 0LL).toLongLong();
        if (timeA != timeB) {
            return timeA > timeB;
        }
        return false;
    });
}


