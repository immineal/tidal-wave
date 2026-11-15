// SPDX-License-Identifier: GPL-3.0-or-later

#include <algorithm>
#include <limits>
#include "TidalBridge.h"
#include "PageEverything.h"
#include "RecordVersions.h"
#include "LyricsFinder.h"
#include "lyricsync/AutoSync.h"
#include <QJSEngine>
#include <QSettings>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>
#include <QGuiApplication>
#include <QClipboard>
#include <QScopeGuard>
#include <QDebug>

TidalBridge::TidalBridge(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    QSettings settings;
    QString saved = settings.value(QStringLiteral("audio/preferredQuality"), QStringLiteral("LOSSLESS")).toString();
    setPreferredQuality(saved);

    connect(m_client, &TidalClient::userIdChanged, this, [this](qint64 uid) {
        // The recents are keyed by account, so the list changes with it.
        emit recentSearchesChanged();
        if (uid > 0) {
            loadFavoriteTrackIds();
            loadFavoriteMixIds();
        } else {
            m_favoriteTrackIds.clear();
            m_likedTrackIds.clear();
            ++m_likedIdsGen;
            m_likedIdsInFlight = false;
            m_favoriteTracks.clear();
            m_favoriteAlbums.clear();
            m_favoriteArtists.clear();
            m_favoritePlaylists.clear();
            m_removals.clear();
            m_removing.clear();
            // Invalidated as well as cleared, so a reply still out for the
            // account being left cannot fill the set after the sign-out.
            ++m_favMixesLoadGen;
            resetFavoriteSync();
            m_favLoadsPending = 0;
            m_favoritesLoading = false;
            m_albumsLoading = m_artistsLoading = m_playlistsLoading = false;
            m_favoriteMixIds.clear();
            emit favoriteTracksChanged();
            emit favoriteAlbumsChanged();
            emit favoriteArtistsChanged();
            emit favoritePlaylistsChanged();
            emit favoriteMixesChanged();
        }
    });

    if (m_client->userId() > 0) {
        loadFavoriteTrackIds();
        loadFavoriteMixIds();
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

// Every artist, so a credit line can make each name its own link and MPRIS
// can name each one. The joined `artists` string and the single `artistId`
// stay beside it: Player::trackFromMap reads both.
static QVariantList artistsToVariantList(const QList<Artist> &artists) {
    QVariantList out;
    for (const Artist &a : artists) {
        QVariantMap am;
        am["id"]   = a.id;
        am["name"] = a.name;
        out.append(am);
    }
    return out;
}

QVariantMap TidalBridge::trackToMap(const Track &t) {
    QVariantMap m;
    m["id"]          = t.id;
    m["title"]       = t.title;
    m["artists"]     = t.artistNames();
    m["artistId"]    = t.artists.isEmpty() ? 0LL : t.artists[0].id;
    m["artistList"]  = artistsToVariantList(t.artists);
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
    // May be "": see Track::trackMixId.
    m["trackMixId"]  = t.trackMixId;
    // What the player looks a twin up by, and whether it has to.
    m["isrc"]        = t.isrc;
    m["streamable"]  = t.streamable;
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
    m["artistList"]  = artistsToVariantList(a.artists);
    m["coverUrl"]    = a.coverUrl(320);
    m["coverUrl640"] = a.coverUrl(640);
    m["releaseDate"] = a.releaseDate;
    m["copyright"]   = a.copyright;
    m["upc"]         = a.upc;
    m["numTracks"]   = a.numTracks;
    m["duration"]    = a.duration;
    m["quality"]     = a.audioQuality;
    m["type"]        = a.type;
    m["featured"]    = a.featured;
    // The artist page's row: "a" Albums, "s" Singles & EPs, "f" Appears on.
    // ArtistPage files a release by this and works nothing out itself.
    m["section"]     = recordSectionKey(a);
    // What a page needs to name a version of a record.
    m["explicit_"]   = a.explicit_;
    m["audioModes"]  = a.audioModes;
    m["mediaTags"]   = a.mediaTags;
    m["year"]        = a.releaseDate.left(4);
    // Another card of the artist page's row has this title. The page words
    // what tells them apart and works nothing out about titles itself.
    m["titleShared"] = a.titleShared;
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

QVariantMap TidalBridge::playlistToMap(const Playlist &p) const {
    QVariantMap m;
    m["uuid"]        = p.uuid;
    m["title"]       = p.title;
    m["description"] = p.description;
    m["numTracks"]   = p.numTracks;
    m["duration"]    = p.duration;
    m["coverUrl"]    = p.coverUrl(320);
    m["type"]        = p.type;
    // Whether this account may add to, rename or take songs out of it.
    m["editable"]    = p.editableBy(m_client->userId());
    return m;
}

QVariantMap TidalBridge::mixToMap(const Mix &m_) {
    QVariantMap m;
    m["id"]       = m_.id;
    m["title"]    = m_.title;
    m["subtitle"] = m_.subTitle;
    m["coverUrl"] = m_.coverUrl(320);
    // What QML may branch on. The title is localised.
    m["mixType"]  = m_.mixType;
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

void TidalBridge::fetchMixPage(const QString &mixId, QJSValue cb) {
    m_client->fetchMixPage(mixId, [this, cb](Mix mix, QList<Track> tracks, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(mixToMap(mix)),
                   qjsEngine(this)->toScriptValue(tracksToList(tracks)),
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

void TidalBridge::fetchPlaylist(const QString &uuid, QJSValue cb) {
    m_client->fetchPlaylist(uuid, [this, cb](Playlist p, QString err) mutable {
        call(cb, { qjsEngine(this)->toScriptValue(playlistToMap(p)),
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

void TidalBridge::fetchAlbumOtherVersions(qlonglong albumId, QJSValue cb) {
    m_client->fetchAlbumOtherVersions(albumId, [this, cb](QList<Album> albums, QString err) mutable {
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

void TidalBridge::search(const QString &q, QJSValue cb, int limit, int offset) {
    m_client->search(q, [this, cb](SearchResults r, QString err) mutable {
        QVariantMap res;
        res["tracks"]    = tracksToList(r.tracks);
        res["albums"]    = albumsToList(r.albums);
        res["artists"]   = artistsToList(r.artists);
        res["playlists"] = playlistsList(r.playlists);
        res["mixes"]     = mixesList(r.mixes);
        // The totals tell the page a full last page from one with more behind it.
        res["totalTracks"]    = r.totalTracks;
        res["totalAlbums"]    = r.totalAlbums;
        res["totalArtists"]   = r.totalArtists;
        res["totalPlaylists"] = r.totalPlaylists;
        res["totalMixes"]     = r.totalMixes;
        call(cb, { qjsEngine(this)->toScriptValue(res), qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

// ─── Recent searches ───────────────────────────────
// A JSON array in QSettings under a per-account key, written whole on every
// change. No qDebug in any of these: it would print what the user searched.
QString TidalBridge::recentSearchesKey() const {
    return QStringLiteral("user_%1/search/recentQueries").arg(m_client->userId());
}

QStringList TidalBridge::recentSearches() const {
    if (m_client->userId() <= 0) return {};
    QSettings settings;
    const QJsonDocument doc = QJsonDocument::fromJson(
        settings.value(recentSearchesKey()).toString().toUtf8());
    if (!doc.isArray()) return {};
    QStringList out;
    for (const QJsonValue &v : doc.array()) {
        const QString q = v.toString();
        if (!q.isEmpty()) out.append(q);
    }
    // A stored list longer than the cap must not make the empty state scroll.
    while (out.size() > kRecentSearchCap) out.removeLast();
    return out;
}

void TidalBridge::saveRecentSearches(const QStringList &queries) {
    if (m_client->userId() <= 0) return;
    QJsonArray arr;
    for (const QString &q : queries) arr.append(q);
    QSettings settings;
    settings.setValue(recentSearchesKey(),
                      QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    emit recentSearchesChanged();
}

void TidalBridge::addRecentSearch(const QString &q) {
    const QStringList before = recentSearches();
    const QStringList after  = withRecentSearch(before, q);
    if (after == before) return;
    saveRecentSearches(after);
}

void TidalBridge::removeRecentSearch(const QString &q) {
    QStringList queries = recentSearches();
    const qsizetype removed = queries.removeIf([&q](const QString &e) {
        return e.compare(q, Qt::CaseInsensitive) == 0;
    });
    if (removed == 0) return;
    saveRecentSearches(queries);
}

void TidalBridge::clearRecentSearches() {
    if (recentSearches().isEmpty()) return;
    saveRecentSearches({});
}

QStringList withRecentSearch(QStringList recents, const QString &query, int cap) {
    const QString q = query.trimmed();
    if (q.isEmpty() || cap <= 0) return recents;

    recents.removeIf([&q](const QString &e) {
        return e.compare(q, Qt::CaseInsensitive) == 0;
    });
    // A query that extends the newest entry is the same search still being
    // typed, so it replaces that entry. Only the newest is checked.
    if (!recents.isEmpty()
        && q.size() > recents.first().size()
        && q.startsWith(recents.first(), Qt::CaseInsensitive))
        recents.removeFirst();

    recents.prepend(q);
    while (recents.size() > cap) recents.removeLast();
    return recents;
}

bool TidalBridge::isTrackFavorite(qlonglong trackId) const {
    return m_favoriteTrackIds.contains(trackId);
}

void TidalBridge::addTrackFavorite(qlonglong trackId, QJSValue cb) {
    m_client->addTrackFavorite(trackId, [this, trackId, cb](bool success) mutable {
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Tracks);
            m_favoriteTrackIds.insert(trackId);
            m_likedTrackIds.insert(trackId);
            emit favoriteTracksChanged();
            m_client->fetchTrack(trackId, [this](Track t, QString err) {
                if (err.isEmpty() && t.id > 0) {
                    // The track may already be in the list from paging.
                    const bool exists = std::any_of(
                        m_favoriteTracks.cbegin(), m_favoriteTracks.cend(),
                        [&](const Track &x) { return x.id == t.id; });
                    if (!exists) {
                        // The list is oldest first while paging and reversed
                        // when the last page lands, so the newest end is the
                        // back until then and the front after.
                        m_favoriteTracks.prepend(t);
                        emit favoriteTracksChanged();
                    }
                    // Outside the guard: LibraryIndex dedups for itself.
                    emit favoriteTrackAdded(t);
                }
            });
        }
        call(cb, { success });
    });
}

void TidalBridge::removeTrackFavorite(qlonglong trackId, QJSValue cb) {
    m_client->removeTrackFavorite(trackId, [this, trackId, cb](bool success) mutable {
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Tracks);
            m_favoriteTrackIds.remove(trackId);
            m_likedTrackIds.remove(trackId);
            for (int i = 0; i < m_favoriteTracks.size(); ++i) {
                if (m_favoriteTracks[i].id == trackId) {
                    m_favoriteTracks.removeAt(i);
                    break;
                }
            }
            emit favoriteTracksChanged();
            emit favoriteRemoved(QStringLiteral("track"), QString::number(trackId));
        }
        call(cb, { success });
    });
}

bool TidalBridge::isMixFavorite(const QString &mixId) const {
    return !mixId.isEmpty() && m_favoriteMixIds.contains(mixId);
}

void TidalBridge::addMixFavorite(const QString &mixId, QJSValue cb) {
    if (mixId.isEmpty()) { call(cb, { false }); return; }
    m_client->addMixFavorite(mixId, [this, mixId, cb](bool success) mutable {
        if (success) {
            // The cache first: isMixFavorite() is what the Save pill reads.
            ++m_favMixesSyncGen;
            m_favoriteMixIds.insert(mixId);
            emit favoriteMixesChanged();
            // LibraryIndex needs the whole row, and `pages/mix` is the only
            // endpoint that describes one mix. Its track list is dropped.
            m_client->fetchMixPage(mixId, [this](Mix mix, QList<Track>, QString err) {
                if (err.isEmpty() && !mix.id.isEmpty()) emit favoriteMixAdded(mix);
            });
        }
        call(cb, { success });
    });
}

void TidalBridge::removeMixFavorite(const QString &mixId, QJSValue cb) {
    if (mixId.isEmpty()) { call(cb, { false }); return; }
    m_client->removeMixFavorite(mixId, [this, mixId, cb](bool success) mutable {
        if (success) {
            ++m_favMixesSyncGen;
            m_favoriteMixIds.remove(mixId);
            emit favoriteMixesChanged();
            emit favoriteRemoved(QStringLiteral("mix"), mixId);
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

QVariantMap TidalBridge::favoriteAlbumById(qlonglong albumId) const {
    for (const auto &a : m_favoriteAlbums)
        if (a.id == albumId) return albumToMap(a);
    return {};
}

void TidalBridge::addAlbumFavorite(qlonglong albumId, QJSValue cb) {
    m_client->addAlbumFavorite(albumId, [this, albumId, cb](bool success) mutable {
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Albums);
            // isAlbumFavorite() answers from m_favoriteAlbums, so the album
            // is fetched and added to it.
            m_client->fetchAlbum(albumId, [this](Album a, QString err) {
                if (err.isEmpty() && a.id > 0) {
                    const bool exists = std::any_of(
                        m_favoriteAlbums.cbegin(), m_favoriteAlbums.cend(),
                        [&](const Album &x) { return x.id == a.id; });
                    if (!exists) {
                        // Front: this list is newest-saved first.
                        m_favoriteAlbums.prepend(a);
                        emit favoriteAlbumsChanged();
                    }
                    // Outside the guard: LibraryIndex dedups for itself.
                    emit favoriteAlbumAdded(a);
                }
            });
            emit favoriteAlbumsChanged();
        }
        call(cb, { success });
    });
}

void TidalBridge::removeAlbumFavorite(qlonglong albumId, QJSValue cb) {
    m_client->removeAlbumFavorite(albumId, [this, albumId, cb](bool success) mutable {
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Albums);
            for (int i = 0; i < m_favoriteAlbums.size(); ++i) {
                if (m_favoriteAlbums[i].id == albumId) { m_favoriteAlbums.removeAt(i); break; }
            }
            emit favoriteAlbumsChanged();
            emit favoriteRemoved(QStringLiteral("album"), QString::number(albumId));
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
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Artists);
            // isArtistFavorite() answers from m_favoriteArtists. There is no
            // fetchArtist, so the detail endpoint supplies the Artist fields.
            m_client->fetchArtistDetail(artistId, [this](ArtistDetail d, QString err) {
                if (err.isEmpty() && d.id > 0) {
                    const bool exists = std::any_of(
                        m_favoriteArtists.cbegin(), m_favoriteArtists.cend(),
                        [&](const Artist &x) { return x.id == d.id; });
                    Artist a;
                    a.id      = d.id;
                    a.name    = d.name;
                    a.picture = d.picture;
                    if (!exists) {
                        // Front: this list is newest first.
                        m_favoriteArtists.prepend(a);
                        emit favoriteArtistsChanged();
                    }
                    emit favoriteArtistAdded(a);
                }
            });
            emit favoriteArtistsChanged();
        }
        call(cb, { success });
    });
}

void TidalBridge::removeArtistFavorite(qlonglong artistId, QJSValue cb) {
    m_client->removeArtistFavorite(artistId, [this, artistId, cb](bool success) mutable {
        if (success) {
            favoriteChangedHere(TidalClient::FavoriteKind::Artists);
            for (int i = 0; i < m_favoriteArtists.size(); ++i) {
                if (m_favoriteArtists[i].id == artistId) { m_favoriteArtists.removeAt(i); break; }
            }
            emit favoriteArtistsChanged();
            emit favoriteRemoved(QStringLiteral("artist"), QString::number(artistId));
        }
        call(cb, { success });
    });
}

void TidalBridge::createPlaylist(const QString &title, QJSValue cb) {
    m_client->createPlaylist(title, [this, cb](Playlist p, QString err) mutable {
        // Made by this account just now, whether or not the reply says so.
        if (p.creatorId == 0) p.creatorId = m_client->userId();
        // Gated on the server having made it: a failed POST must not leave a
        // phantom row.
        if (err.isEmpty() && !p.uuid.isEmpty()) {
            favoriteChangedHere(TidalClient::FavoriteKind::Playlists);
            const bool exists = std::any_of(
                m_favoritePlaylists.cbegin(), m_favoritePlaylists.cend(),
                [&](const Playlist &x) { return x.uuid == p.uuid; });
            if (!exists) {
                // Position in the raw list decides nothing: every reader
                // runs it through sortPlaylists().
                m_favoritePlaylists.append(p);
                emit favoritePlaylistsChanged();
            }
            // Outside the guard: LibraryIndex dedups for itself.
            emit playlistCreated(p);
        }
        call(cb, { qjsEngine(this)->toScriptValue(playlistToMap(p)),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::editPlaylist(const QString &uuid, const QString &title,
                               const QString &description, QJSValue cb)
{
    m_client->editPlaylist(uuid, title, description,
        [this, uuid, title, description, cb](bool success) mutable {
        if (success) {
            bool found = false;
            for (int i = 0; i < m_favoritePlaylists.size(); ++i) {
                if (m_favoritePlaylists[i].uuid != uuid) continue;
                m_favoritePlaylists[i].title       = title;
                m_favoritePlaylists[i].description = description;
                found = true;
                break;
            }
            if (found) emit favoritePlaylistsChanged();

            // Outside the guard: LibraryIndex keeps its own list.
            Playlist renamed;
            renamed.uuid        = uuid;
            renamed.title       = title;
            renamed.description = description;
            emit playlistUpdated(renamed);
        }
        call(cb, { success });
    });
}

// ── a playlist's own numbers, after its contents changed ────────────────────
// A round trip, because the count cannot be computed: the add posts
// `onDupes=SKIP`, so a successful reply does not mean the playlist
// grew. Duration and image cannot be derived from a track id either.
void TidalBridge::refreshPlaylistMeta(const QString &uuid, std::function<void()> then) {
    if (uuid.isEmpty()) { if (then) then(); return; }
    m_client->fetchPlaylist(uuid, [this, uuid, then](Playlist fresh, QString err) {
        const auto done = qScopeGuard([&then] { if (then) then(); });
        // A failed reply, or one about another playlist, would blank the row.
        if (!err.isEmpty() || fresh.uuid != uuid) return;

        bool changed = false;
        for (int i = 0; i < m_favoritePlaylists.size(); ++i) {
            if (m_favoritePlaylists[i].uuid != uuid) continue;
            changed = mergePlaylistMeta(m_favoritePlaylists[i], fresh);
            break;
        }
        if (changed) emit favoritePlaylistsChanged();

        // Both outside the `changed` guard: LibraryIndex keeps its own list,
        // and a page showing this playlist may hold the stale figure itself.
        emit playlistStatsChanged(fresh);
        emit playlistStatsRefreshed(uuid);
    });
}

void TidalBridge::addTracksToPlaylist(const QString &uuid, qlonglong trackId, QJSValue cb) {
    m_client->addTrackToPlaylist(uuid, trackId, [this, uuid, cb](bool success) mutable {
        // The caller is answered first; the refresh goes out behind it.
        call(cb, { success });
        if (success) refreshPlaylistMeta(uuid);
    });
}

void TidalBridge::removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb) {
    m_removals[uuid].append({itemIndex, false, cb});
    if (!m_removing.contains(uuid)) nextRemoval(uuid);
}

// One at a time, because each DELETE addresses a row by its index and sends
// the ETag the one before it produced. The next goes out once the header has
// been read again, which also brings that ETag.
void TidalBridge::nextRemoval(const QString &uuid) {
    auto it = m_removals.find(uuid);
    if (it == m_removals.end() || it->isEmpty()) {
        if (it != m_removals.end()) m_removals.erase(it);
        m_removing.remove(uuid);
        return;
    }
    m_removing.insert(uuid);
    if (it->first().gone) {
        // Asked twice for one row: the first request took it.
        Removal r = it->takeFirst();
        call(r.cb, { true, false, -1 });
        nextRemoval(uuid);
        return;
    }
    const int index = it->first().index;
    const qint64 uid = m_client->userId();
    m_client->removeTrackFromPlaylist(uuid, index,
        [this, uuid, index, uid](TidalClient::PlaylistWrite result) {
        // Signed out meanwhile: the queue went with the account.
        if (uid != m_client->userId()) return;
        auto it = m_removals.find(uuid);
        if (it == m_removals.end() || it->isEmpty()) { m_removing.remove(uuid); return; }
        Removal r = it->takeFirst();
        using W = TidalClient::PlaylistWrite;
        if (result == W::Stale) {
            // Every one still queued was aimed at the same stale rows.
            const QList<Removal> rest = std::exchange(*it, {});
            m_removals.remove(uuid);
            m_removing.remove(uuid);
            call(r.cb, { false, true, -1 });
            for (Removal later : rest) call(later.cb, { false, true, -1 });
            return;
        }
        if (result == W::Done) {
            // Those asked for before this answer counted rows as they were.
            for (Removal &later : *it) {
                if (later.gone) continue;
                if (index < later.index) --later.index;
                else if (index == later.index) later.gone = true;
            }
        }
        call(r.cb, { result == W::Done, false, result == W::Done ? index : -1 });
        if (result == W::Done) refreshPlaylistMeta(uuid, [this, uuid] { nextRemoval(uuid); });
        else nextRemoval(uuid);
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

void TidalBridge::fetchTrackMix(qlonglong trackId, QJSValue cb) {
    if (trackId <= 0) { call(cb, { QString(), QStringLiteral("no track") }); return; }
    m_client->fetchTrack(trackId, [this, cb](Track t, QString err) mutable {
        // A track with no radio answers "" and no error.
        call(cb, { qjsEngine(this)->toScriptValue(t.trackMixId),
                   qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::fetchLyrics(qlonglong trackId, QJSValue cb) {
    m_client->fetchLyrics(trackId, [this, cb, trackId](QString text, bool timed, QString err) mutable {
        // Remembered, so a replay of this track is not analysed ahead for nothing.
        if (timed && m_autoSync) m_autoSync->noteRealTimings(trackId);
        QVariantMap result;
        result["text"]  = text;
        result["timed"] = timed;
        call(cb, { qjsEngine(this)->toScriptValue(result), qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::findLyrics(const QVariantMap &track, QJSValue cb) {
    if (!m_lyricsFinder) {
        call(cb, { qjsEngine(this)->toScriptValue(QVariantMap()),
                   qjsEngine(this)->toScriptValue(QStringLiteral("off")) });
        return;
    }
    LyricsQuery q;
    q.trackId  = track.value(QStringLiteral("id")).toLongLong();
    q.title    = track.value(QStringLiteral("title")).toString();
    q.album    = track.value(QStringLiteral("albumTitle")).toString();
    q.duration = track.value(QStringLiteral("duration")).toInt();
    for (const QVariant &a : track.value(QStringLiteral("artistList")).toList()) {
        const QString name = a.toMap().value(QStringLiteral("name")).toString();
        if (!name.isEmpty()) q.artists << name;
    }
    if (q.artists.isEmpty() && !track.value(QStringLiteral("artists")).toString().isEmpty())
        q.artists << track.value(QStringLiteral("artists")).toString();
    m_lyricsFinder->find(q, [this, cb](const LyricsResult &r, const QString &err) mutable {
        QVariantMap result;
        result["text"]   = r.text;
        result["timed"]  = r.timed;
        result["source"] = r.source;
        result["url"]    = r.url.toString();
        result["instrumental"] = r.instrumental;
        call(cb, { qjsEngine(this)->toScriptValue(result), qjsEngine(this)->toScriptValue(err) });
    });
}

void TidalBridge::autoSyncLyrics(qlonglong trackId, const QString &text, QJSValue cb) {
    if (!m_autoSync) {
        call(cb, { qjsEngine(this)->toScriptValue(QVariantMap()),
                   qjsEngine(this)->toScriptValue(QStringLiteral("off")) });
        return;
    }
    m_autoSync->sync(trackId, text, [this, cb](const lyricsync::AutoSync::Result &r) mutable {
        QVariantMap result;
        result["ok"]         = r.ok;
        result["kept"]       = r.kept;
        result["confidence"] = r.confidence;
        result["lrc"]        = r.lrc;
        call(cb, { qjsEngine(this)->toScriptValue(result), qjsEngine(this)->toScriptValue(r.error) });
    });
}

void TidalBridge::cancelAutoSync() {
    if (m_autoSync) m_autoSync->cancel();
}

void TidalBridge::setLyricsLookAhead(bool on) {
    if (m_autoSync) m_autoSync->setLookAhead(on);
}

void TidalBridge::fetchTrackCredits(qlonglong trackId, QJSValue cb) {
    m_client->fetchTrackCredits(trackId, [this, cb](TrackCredits c, QString err) mutable {
        QVariantMap result;
        QVariantList groups;
        for (const CreditGroup &g : c.groups) {
            QVariantMap gm;
            gm["type"]         = g.type;
            gm["contributors"] = artistsToVariantList(g.contributors);
            groups.append(gm);
        }
        result["groups"]      = groups;
        result["copyright"]   = c.copyright;
        result["isrc"]        = c.isrc;
        result["releaseDate"] = c.releaseDate;
        result["upc"]         = c.upc;
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
    // Invalidates any paging chain in flight, so its callbacks stop appending
    // after this reset.
    ++m_favTracksLoadGen;
    resetFavoriteSync();

    m_favLoadsPending = 4;
    m_favoritesLoading = true;
    m_albumsLoading = m_artistsLoading = m_playlistsLoading = true;
    m_favoriteTrackIds.clear();
    m_favoriteTracks.clear();
    m_favoriteAlbums.clear();
    m_favoriteArtists.clear();
    m_favoritePlaylists.clear();

    m_likedTrackIds.clear();
    m_tracksFellBack = false;

    emit favoriteTracksChanged();
    refreshLikedTrackIds();
    loadFavoriteTracks();
    loadFavoriteAlbums();
    loadFavoriteArtists();
    loadNextUserPlaylistsPage(0);
}

void TidalBridge::resetFavoriteSync() {
    for (FavoriteSync &s : m_favSync) {
        ++s.gen;
        s.reloading = false;
        s.head = {};
    }
    ++m_favMixesSyncGen;
}

void TidalBridge::favoriteChangedHere(TidalClient::FavoriteKind kind) {
    FavoriteSync &s = m_favSync[int(kind)];
    ++s.gen;
    s.reloading = false;
    if (kind != TidalClient::FavoriteKind::Tracks) return;
    // An ids reply still out may predate the change, so it is asked again.
    // One that landed during the dropped reload is applied now.
    if (m_likedIdsInFlight) refreshLikedTrackIds();
    else                    applyLikedTrackIds();
}

void TidalBridge::syncFavorites() {
    if (m_client->userId() == 0 || m_favLoadsPending > 0) return;

    using Kind = TidalClient::FavoriteKind;
    for (Kind kind : {Kind::Tracks, Kind::Albums, Kind::Artists, Kind::Playlists}) {
        if (m_favSync[int(kind)].reloading) continue;
        const int gen = m_favSync[int(kind)].gen;
        m_client->fetchFavoritesHead(kind, [this, kind, gen](FavoritesHead head, QString err) {
            const FavoriteSync &s = m_favSync[int(kind)];
            if (!err.isEmpty() || gen != s.gen || s.reloading || head == s.head) return;
            reloadFavorites(kind, head);
        });
    }

    const int mixGen = m_favMixesSyncGen;
    m_client->fetchFavoriteMixes([this, mixGen](QList<Mix> mixes, QString err) {
        if (!err.isEmpty() || mixGen != m_favMixesSyncGen) return;
        QSet<QString> ids;
        for (const Mix &m : mixes)
            if (!m.id.isEmpty()) ids.insert(m.id);
        if (ids == m_favoriteMixIds) return;
        m_favoriteMixIds = ids;
        emit favoriteMixesChanged();
        emit favoritesChangedElsewhere();
    });
}

template <typename T, typename Fetch, typename Paged, typename KeyOf, typename Apply>
void TidalBridge::reloadInto(TidalClient::FavoriteKind kind, const FavoritesHead &head,
                             int limit, const QList<T> &cache, Fetch fetch, Paged paged,
                             KeyOf keyOf, Apply apply) {
    FavoriteSync &sync = m_favSync[int(kind)];
    sync.reloading = true;
    const auto landed = [this, kind, head, keyOf, apply, gen = sync.gen,
                         cache = &cache](const QList<T> &all, bool whole, bool fellBack) {
        FavoriteSync &s = m_favSync[int(kind)];
        if (gen != s.gen) return;
        s.reloading = false;
        // A failed reload leaves the list alone and the next check tries again.
        // So does one paged by date, but for the rows it adds: it can lose some.
        const bool lossy = fellBack && kind != TidalClient::FavoriteKind::Tracks;
        if (whole) {
            if (!lossy) s.head = head;
            const QList<T> next = lossy ? mergeLossy(*cache, all, keyOf) : all;
            const bool same = std::equal(next.cbegin(), next.cend(),
                                         cache->cbegin(), cache->cend(),
                [&](const T &a, const T &b) { return keyOf(a) == keyOf(b); });
            if (!same) {
                apply(next, fellBack);
                emit favoritesChangedElsewhere();
            }
        }
        // Held back while the reload ran, so one change redraws once.
        if (kind == TidalClient::FavoriteKind::Tracks) applyLikedTrackIds();
    };
    // Paged to the empty page, as the sign-in load is: a short page here would
    // otherwise replace the list with its first part.
    if (kind == TidalClient::FavoriteKind::Playlists) {
        pageEverything<T>(fetch, keyOf,
                          [landed](const QList<T> &all, bool whole) { landed(all, whole, false); },
                          limit, std::numeric_limits<int>::max(), false);
        return;
    }
    pageFavorites<T>(fetch, paged, keyOf, landed, TidalClient::kFavoritesPageMax, limit,
                     std::numeric_limits<int>::max(), "favourites",
                     kind != TidalClient::FavoriteKind::Tracks);
}

void TidalBridge::reloadFavorites(TidalClient::FavoriteKind kind, const FavoritesHead &head) {
    using Kind = TidalClient::FavoriteKind;
    const auto idKey = [](const auto &x) { return QString::number(x.id); };
    switch (kind) {
    case Kind::Tracks:
        // The ids come along: a heart Tidal lists only there may have gone too.
        // Marked as reloading first, so an early ids reply waits for the list.
        m_favSync[int(kind)].reloading = true;
        refreshLikedTrackIds();
        reloadInto<Track>(kind, head, 100, m_favoriteTracks,
            [this](int offset, int limit, TidalClient::TracksCallback cb) {
                m_client->fetchFavoriteTracksNewestFirst(std::move(cb), limit, offset); },
            [this](int offset, int limit, TidalClient::TracksCallback cb) {
                m_client->fetchFavoriteTracksByIndex(std::move(cb), limit, offset, true); },
            idKey,
            [this](const QList<Track> &all, bool fellBack) {
                m_favoriteTracks = all;
                m_tracksFellBack = fellBack;
                m_favoriteTrackIds = m_likedTrackIds;
                for (const Track &t : all) m_favoriteTrackIds.insert(t.id);
                emit favoriteTracksChanged();
                reportPagedLikes();
            });
        break;
    case Kind::Albums: {
        const auto page = [this](int offset, int limit, TidalClient::AlbumsCallback cb) {
            m_client->fetchFavoriteAlbums(std::move(cb), limit, offset); };
        reloadInto<Album>(kind, head, 100, m_favoriteAlbums, page, page, idKey,
            [this](const QList<Album> &all, bool) {
                m_favoriteAlbums = all;
                emit favoriteAlbumsChanged();
            });
        break;
    }
    case Kind::Artists: {
        const auto page = [this](int offset, int limit, TidalClient::ArtistsCallback cb) {
            m_client->fetchFavoriteArtists(std::move(cb), limit, offset); };
        reloadInto<Artist>(kind, head, 100, m_favoriteArtists, page, page, idKey,
            [this](const QList<Artist> &all, bool) {
                m_favoriteArtists = all;
                emit favoriteArtistsChanged();
            });
        break;
    }
    case Kind::Playlists: {
        const auto page = [this](int offset, int limit, TidalClient::PlaylistsCallback cb) {
            m_client->fetchUserPlaylists(std::move(cb), limit, offset); };
        reloadInto<Playlist>(kind, head, 50, m_favoritePlaylists, page, page,
            [](const Playlist &p) { return p.uuid; },
            [this](const QList<Playlist> &all, bool) {
                m_favoritePlaylists = all;
                emit favoritePlaylistsChanged();
            });
        break;
    }
    }
}

void TidalBridge::loadFavoriteMixIds() {
    const int gen = ++m_favMixesLoadGen;
    m_favoriteMixIds.clear();
    m_client->fetchFavoriteMixes([this, gen](QList<Mix> mixes, QString err) {
        if (gen != m_favMixesLoadGen) return;
        // A failed load leaves the set empty, so a saved mix offers Save.
        // That is harmless; an Unsave on an unsaved mix could not work.
        if (!err.isEmpty()) return;
        for (const Mix &m : mixes)
            if (!m.id.isEmpty()) m_favoriteMixIds.insert(m.id);
        emit favoriteMixesChanged();
    });
}

// The rows on hand are kept: they were liked or saved here during the load,
// and the listing may predate that.
template <typename T>
static void mergeLoaded(QList<T> &list, const QList<T> &loaded) {
    QSet<qint64> have;
    for (const T &x : list) have.insert(x.id);
    for (const T &x : loaded)
        if (!have.contains(x.id)) { have.insert(x.id); list.append(x); }
}

void TidalBridge::loadFavoriteTracks() {
    if (m_client->userId() == 0) return;
    const int gen = m_favTracksLoadGen;
    // Newest first, in one page: the collection shows its spinner until then.
    pageFavorites<Track>(
        [this](int offset, int limit, TidalClient::TracksCallback cb) {
            m_client->fetchFavoriteTracksNewestFirst(std::move(cb), limit, offset); },
        [this](int offset, int limit, TidalClient::TracksCallback cb) {
            m_client->fetchFavoriteTracksByIndex(std::move(cb), limit, offset, true); },
        [](const Track &t) { return QString::number(t.id); },
        [this, gen](const QList<Track> &all, bool, bool fellBack) {
            if (gen != m_favTracksLoadGen) return;
            m_favoritesLoading = false;
            --m_favLoadsPending;
            mergeLoaded(m_favoriteTracks, all);
            for (const Track &t : all) m_favoriteTrackIds.insert(t.id);
            m_tracksFellBack = fellBack;
            emit favoriteTracksChanged();
            reportPagedLikes();
        },
        TidalClient::kFavoritesPageMax, 100, std::numeric_limits<int>::max(),
        "liked songs", false);
}

void TidalBridge::loadFavoriteAlbums() {
    if (m_client->userId() == 0) return;
    const int gen = m_favTracksLoadGen;
    const auto page = [this](int offset, int limit, TidalClient::AlbumsCallback cb) {
        m_client->fetchFavoriteAlbums(std::move(cb), limit, offset); };
    pageFavorites<Album>(page, page,
        [](const Album &a) { return QString::number(a.id); },
        [this, gen](const QList<Album> &all, bool, bool) {
            if (gen != m_favTracksLoadGen) return;
            --m_favLoadsPending;
            m_albumsLoading = false;
            mergeLoaded(m_favoriteAlbums, all);
            emit favoriteAlbumsChanged();
        },
        TidalClient::kFavoritesPageMax, 100, std::numeric_limits<int>::max(),
        "saved albums", true);
}

void TidalBridge::loadFavoriteArtists() {
    if (m_client->userId() == 0) return;
    const int gen = m_favTracksLoadGen;
    const auto page = [this](int offset, int limit, TidalClient::ArtistsCallback cb) {
        m_client->fetchFavoriteArtists(std::move(cb), limit, offset); };
    pageFavorites<Artist>(page, page,
        [](const Artist &a) { return QString::number(a.id); },
        [this, gen](const QList<Artist> &all, bool, bool) {
            if (gen != m_favTracksLoadGen) return;
            --m_favLoadsPending;
            m_artistsLoading = false;
            mergeLoaded(m_favoriteArtists, all);
            emit favoriteArtistsChanged();
        },
        TidalClient::kFavoritesPageMax, 100, std::numeric_limits<int>::max(),
        "followed artists", true);
}

// The hearts: favorites/ids lists every liked song, unavailable ones too, and
// a listing that had to page can miss some.
void TidalBridge::refreshLikedTrackIds() {
    const int gen = ++m_likedIdsGen;
    m_likedIdsInFlight = true;
    m_client->fetchFavoriteIds([this, gen](FavoriteIds ids, QString err) {
        if (gen != m_likedIdsGen) return;
        m_likedIdsInFlight = false;
        if (!err.isEmpty()) return;
        m_likedTrackIds.clear();
        for (const qint64 id : std::as_const(ids.tracks)) m_likedTrackIds.insert(id);
        if (!m_favSync[int(TidalClient::FavoriteKind::Tracks)].reloading) applyLikedTrackIds();
        reportPagedLikes();
    });
}

void TidalBridge::applyLikedTrackIds() {
    QSet<qlonglong> hearts = m_likedTrackIds;
    for (const Track &t : std::as_const(m_favoriteTracks)) hearts.insert(t.id);
    if (hearts == m_favoriteTrackIds) return;
    m_favoriteTrackIds = hearts;
    emit favoriteTracksChanged();
}

// Only a paged listing can lose rows; one page leaves out the unavailable ones.
void TidalBridge::reportPagedLikes() {
    if (!m_tracksFellBack || m_likedTrackIds.isEmpty() || m_likedIdsInFlight) return;
    int missing = 0;
    QSet<qlonglong> listed;
    for (const Track &t : std::as_const(m_favoriteTracks)) listed.insert(t.id);
    for (const qlonglong id : std::as_const(m_likedTrackIds))
        if (!listed.contains(id)) ++missing;
    qWarning("favourites: the paged listing lacks %d of %d liked songs: unavailable "
             "here, or lost to paging if order=INDEX was refused too", missing,
             int(m_likedTrackIds.size()));
}

void TidalBridge::loadNextUserPlaylistsPage(int offset) {
    if (m_client->userId() == 0) return;
    // A chain from a superseded load must not end the current one's loading.
    const int gen = m_favTracksLoadGen;
    m_client->fetchUserPlaylists([this, offset, gen](QList<Playlist> playlists, QString err) {
        if (gen != m_favTracksLoadGen) return;
        if (!err.isEmpty() || playlists.isEmpty()) {
            --m_favLoadsPending;
            m_playlistsLoading = false;
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
    qDebug() << "[TidalBridge] markPlaylistPlayed uuid:" << uuid << "timestamp:" << playtimes[uuid].toLongLong();
    emit favoritePlaylistsChanged();
}

void sortPlaylistsByRecency(QList<Playlist> &playlists, const QVariantMap &playtimes) {
    const auto recency = [&playtimes](const Playlist &p) {
        return std::max(playtimes.value(p.uuid, 0LL).toLongLong(), p.addedAt);
    };
    std::stable_sort(playlists.begin(), playlists.end(),
                     [&recency](const Playlist &a, const Playlist &b) {
                         return recency(a) > recency(b);
                     });
}

void TidalBridge::sortPlaylists(QList<Playlist> &playlists) const {
    QVariantMap playtimes;
    const qint64 uid = m_client->userId();
    // Play times are kept per account. Without a session addedAt alone orders.
    if (uid > 0) {
        QSettings settings;
        playtimes = settings.value(
            QStringLiteral("user_%1/playlists/lastPlayed").arg(uid)).toMap();
    }
    sortPlaylistsByRecency(playlists, playtimes);
}


