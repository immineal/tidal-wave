#include <algorithm>
#include "TidalBridge.h"
#include <QJSEngine>
#include <QSettings>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>
#include <QGuiApplication>
#include <QClipboard>
#include <QDebug>

TidalBridge::TidalBridge(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    QSettings settings;
    QString saved = settings.value(QStringLiteral("audio/preferredQuality"), QStringLiteral("LOSSLESS")).toString();
    setPreferredQuality(saved);

    connect(m_client, &TidalClient::userIdChanged, this, [this](qint64 uid) {
        // The recents are keyed by account and so are a different list before
        // and after a sign-in - including "none at all" while there is no
        // account. Anything showing them has to be told, or the search page
        // keeps whatever it read when it was built.
        emit recentSearchesChanged();
        if (uid > 0) {
            loadFavoriteTrackIds();
            loadFavoriteMixIds();
        } else {
            m_favoriteTrackIds.clear();
            m_favoriteTracks.clear();
            m_favoriteAlbums.clear();
            m_favoriteArtists.clear();
            m_favoritePlaylists.clear();
            // Invalidated as well as cleared, so a reply still out for the
            // account being left cannot fill the set behind the sign-out.
            ++m_favMixesLoadGen;
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

// Every artist, so a credit line can make each name its own link (SPEC N2)
// instead of sending every name to the lead. The joined `artists` string and
// the single `artistId` beside it stay exactly as they were: the string is what
// a window title and an MPRIS payload want, and the first id is what
// Player::trackFromMap reads back.
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
    // This track's radio, as a mix id, or "" when the response did not carry
    // one. Put in the map rather than on a new TrackRow property on purpose:
    // all seven pages that build a row already pass the whole map as
    // `trackData`, so the id reaches every one of them with no call site to
    // change - and a page this app has not written yet gets it for free. See
    // Track::trackMixId for why it may legitimately be empty.
    m["trackMixId"]  = t.trackMixId;
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
    // An album is credited to a list too, and the hero shows it.
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
    // The only handle on *which* mix this is that QML may branch on: the title
    // arrives in the account's language (MixTypes in Models.h says so at
    // length), so anything comparing against one breaks in German.
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
        // The five totals. TidalClient has always parsed them and this method
        // dropped all four of the ones that existed, which is why the page had
        // no end-of-list state to offer: a kind whose last page happens to be
        // full is indistinguishable from one with more behind it.
        res["totalTracks"]    = r.totalTracks;
        res["totalAlbums"]    = r.totalAlbums;
        res["totalArtists"]   = r.totalArtists;
        res["totalPlaylists"] = r.totalPlaylists;
        res["totalMixes"]     = r.totalMixes;
        call(cb, { qjsEngine(this)->toScriptValue(res), qjsEngine(this)->toScriptValue(err) });
    }, limit, offset);
}

// ─── Recent searches ───────────────────────────────
//
// Beside the recents LibraryIndex already keeps, and in the same place: a
// QSettings value under a per-account key, written whole on every change.
// LibraryIndex uses "user_<id>/library/lastPlayed" for what the user played;
// this is "user_<id>/search/recentQueries" for what they searched. Same store,
// same per-account scoping, same "serialise the lot, it is tiny" approach -
// a JSON array of strings rather than LibraryIndex's JSON object only because
// this list is ordered and has no values to carry.
//
// Not a file beside the album-track cache (LibraryIndex::trackCachePath), which
// is the other half of how LibraryIndex persists: that file exists because a
// whole library's tracklists are megabytes and do not belong in a settings
// file. Eight strings do.
//
// Nothing is logged. markPlaylistPlayed() a few lines up prints the uuid it
// records; the equivalent here would print what the user searched for, so
// there is deliberately no qDebug in any of these four.
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
    // A file edited by hand, or written by a future version with a bigger cap,
    // must not make the empty state scroll.
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

// See the header for the two rules beyond "prepend and truncate".
QStringList withRecentSearch(QStringList recents, const QString &query, int cap) {
    const QString q = query.trimmed();
    if (q.isEmpty() || cap <= 0) return recents;

    recents.removeIf([&q](const QString &e) {
        return e.compare(q, Qt::CaseInsensitive) == 0;
    });
    // The newest entry, if this query is a longer spelling of it, is the same
    // search still being typed - so it is replaced rather than kept above the
    // thing it was a prefix of.
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
            m_favoriteTrackIds.insert(trackId);
            emit favoriteTracksChanged();
            m_client->fetchTrack(trackId, [this](Track t, QString err) {
                if (err.isEmpty() && t.id > 0) {
                    // Don't add a second row if it's already in the list (e.g.
                    // re-liking a track that was loaded during paging).
                    const bool exists = std::any_of(
                        m_favoriteTracks.cbegin(), m_favoriteTracks.cend(),
                        [&](const Track &x) { return x.id == t.id; });
                    if (!exists) {
                        // Which end is "newest" depends on how far loading has
                        // got. fetchFavoriteTracks asks for order=DATE without
                        // a direction, so the endpoint answers oldest first and
                        // the pager appends in that order; the list is only
                        // turned round once the last page is in. So: front when
                        // the order has settled, back while it has not, and
                        // either way the song the user just liked ends up at
                        // the top of the Tracks tab rather than the bottom.
                        if (m_favTracksSettled) m_favoriteTracks.prepend(t);
                        else                    m_favoriteTracks.append(t);
                        emit favoriteTracksChanged();
                    }
                    // The sidebar's copy dedups for itself, so it is told
                    // whether or not this list already had the track.
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
            m_favoriteTrackIds.remove(trackId);
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
            // The cache first, because isMixFavorite() is what the pill reads
            // and the pill flipping to "Saved" *is* the confirmation - the same
            // gap addAlbumFavorite was fixed for.
            m_favoriteMixIds.insert(mixId);
            emit favoriteMixesChanged();
            // And the sidebar's own copy of the library, which keeps its own
            // mix list and hears nothing from the signal above. The row has to
            // be re-read, as addAlbumFavorite re-reads its album: this call is
            // handed an id and nothing else, and a row invented out of the id
            // would put an untitled line in the sidebar.
            //
            // `pages/mix` is the only endpoint that describes one mix, so the
            // track list comes back with the header and is dropped. That is a
            // real cost and it is paid once, on a deliberate save.
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
            // The server accepted it, but isAlbumFavorite() answers from
            // m_favoriteAlbums, so without this the Save button stayed on
            // "Save" and the album never appeared in the collection until the
            // next full fetch. removeAlbumFavorite has always maintained the
            // list; only the add side was missing it.
            m_client->fetchAlbum(albumId, [this](Album a, QString err) {
                if (err.isEmpty() && a.id > 0) {
                    const bool exists = std::any_of(
                        m_favoriteAlbums.cbegin(), m_favoriteAlbums.cend(),
                        [&](const Album &x) { return x.id == a.id; });
                    if (!exists) {
                        // Front, not back. This list is newest-saved first -
                        // the endpoint is asked for order=DATE&DESC and the
                        // pages are appended in that order - so appending put
                        // the album the user had just saved at the *oldest*
                        // end. The collection grid's default sort is "the order
                        // the library arrived in", so on a library of any size
                        // the album did appear, thousands of rows down, which
                        // is indistinguishable from not appearing at all.
                        m_favoriteAlbums.prepend(a);
                        emit favoriteAlbumsChanged();
                    }
                    // And the sidebar, which keeps a copy of its own. Emitted
                    // outside the guard above: the two lists dedup separately,
                    // so one having the album says nothing about the other.
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
            // Same gap as albums had: Follow reported success and then read
            // back as not-following, because isArtistFavorite() answers from
            // m_favoriteArtists. There is no fetchArtist, so the detail
            // endpoint supplies the three fields an Artist needs.
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
                        // Front, for the reason given in addAlbumFavorite.
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
        // Creating one updated neither this list nor the sidebar's, so the
        // playlist existed on the server and nowhere in the interface until the
        // next launch. Gated on the server having actually made it: a failed
        // POST must not leave a phantom row.
        if (err.isEmpty() && !p.uuid.isEmpty()) {
            const bool exists = std::any_of(
                m_favoritePlaylists.cbegin(), m_favoritePlaylists.cend(),
                [&](const Playlist &x) { return x.uuid == p.uuid; });
            if (!exists) {
                // Appended, not prepended as the three favourites above are:
                // every reader of this list runs it through sortPlaylists(),
                // which orders by max(last played, Playlist::addedAt), so where
                // a row sits in the raw list decides nothing. It does mean a
                // created playlist leads the row only if the POST response
                // carried `created`; nothing here can supply that date itself.
                m_favoritePlaylists.append(p);
                emit favoritePlaylistsChanged();
            }
            // Outside the guard, as with the favourites: the sidebar keeps its
            // own list and dedups for itself.
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
        // The same two caches createPlaylist above updates, and for the same
        // reason: the dialog's own page already shows the new name, and
        // without these the sidebar and the Collection grid would go on
        // showing the old one until the next launch.
        if (success) {
            bool found = false;
            for (int i = 0; i < m_favoritePlaylists.size(); ++i) {
                if (m_favoritePlaylists[i].uuid != uuid) continue;
                m_favoritePlaylists[i].title       = title;
                m_favoritePlaylists[i].description = description;
                found = true;
                break;
            }
            // Gated on the row being there. A rename reorders nothing - every
            // reader sorts by max(last played, addedAt) and neither moved - so
            // this is purely "redraw the label", and saying so about a
            // playlist this list has never heard of would be a lie the grid
            // would have to resolve by refetching.
            if (found) emit favoritePlaylistsChanged();

            // Outside the guard, as playlistCreated is: the sidebar's copy of
            // the library is a different list, filled from a different call,
            // and whether this one happens to hold the row says nothing about
            // whether that one does.
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
//
// Re-reads `playlists/<uuid>` and merges the fields a contents change moves into
// the favourites cache here and, through playlistStatsChanged, into the
// sidebar's separate copy. Both ends run mergePlaylistMeta(), which is where the
// field list and the exclusions live.
//
// **Why a round trip and not arithmetic.** A count this already holds plus one
// looks cheaper, and it is wrong:
//
//   * TidalClient::addTrackToPlaylist posts `onDuplicateFound=SKIP`. A song
//     already on the playlist is accepted by the server and added to nothing, so
//     a successful reply does not mean the playlist grew. The picker does not
//     hide playlists that already hold the track, so this is one click away, and
//     "+1 every time" would trade a count that is always 0 for a count that
//     drifts upward and can never be reconciled from the interface.
//   * `duration` cannot be computed at all. This method is handed a track id,
//     not a length.
//   * nor can `image`, which Tidal regenerates from the playlist's first tracks.
//
// **Why this is not the round trip that was deliberately removed.** That one was
// per *picker open* - a read on the hot path, which left the list blank until it
// answered, every single time the menu was used. This is per accepted *mutation*:
// the mutation has already cost two requests (the etag, then the post), the user
// asked for it by hand, and it runs after the callback has already reported the
// result, so nothing on screen is waiting for it.
void TidalBridge::refreshPlaylistMeta(const QString &uuid) {
    if (uuid.isEmpty()) return;
    m_client->fetchPlaylist(uuid, [this, uuid](Playlist fresh, QString err) {
        // A reply that failed or came back about something else is not news
        // about this playlist, and writing it in would blank the row with the
        // parse of an error body.
        //
        // The first half is belt and braces rather than a live guard, and is
        // recorded as such because a mutation proved it: TidalClient::fetchPlaylist
        // answers `cb({}, err)` on every failure, so an error always arrives with
        // a default-constructed Playlist whose uuid is empty, and the second half
        // already refuses that. Removing the `err` test changes no behaviour and
        // no fixture can be built that says otherwise - the state it guards
        // against cannot be produced by the only implementation. It stays because
        // "the reply failed" and "the reply is about something else" are two
        // different reasons to walk away and a reader should not have to derive
        // one from the other.
        if (!err.isEmpty() || fresh.uuid != uuid) return;

        bool changed = false;
        for (int i = 0; i < m_favoritePlaylists.size(); ++i) {
            if (m_favoritePlaylists[i].uuid != uuid) continue;
            changed = mergePlaylistMeta(m_favoritePlaylists[i], fresh);
            break;
        }
        // Gated on something having moved, as the rename path is: the four
        // readers of this list each rebuild a grid or a row off the signal, and
        // a playlist whose numbers the server confirmed unchanged is not a
        // redraw.
        if (changed) emit favoritePlaylistsChanged();

        // Outside the guard, as playlistCreated and playlistUpdated are: the
        // sidebar keeps its own list, filled from its own paging, and whether
        // this one happens to hold the row says nothing about whether that one
        // does.
        emit playlistStatsChanged(fresh);
        // And the QML-facing half of the same news, which says which playlist it
        // was. Also outside the `changed` guard: a page that is showing this
        // playlist wants the confirmation even when the cache had nothing to
        // learn, because its own figure may be the stale one.
        emit playlistStatsRefreshed(uuid);
    });
}

void TidalBridge::addTracksToPlaylist(const QString &uuid, qlonglong trackId, QJSValue cb) {
    m_client->addTrackToPlaylist(uuid, trackId, [this, uuid, cb](bool success) mutable {
        // The caller is answered first and the refresh goes out behind it. A
        // picker that waited for the second request before saying "Added" would
        // be slower than the one that said nothing.
        call(cb, { success });
        // Gated on the server having accepted it. A refused post must not move
        // a count, and re-reading the header after one would at best confirm
        // what is already cached and at worst cost a request per failure.
        if (success) refreshPlaylistMeta(uuid);
    });
}

void TidalBridge::removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb) {
    m_client->removeTrackFromPlaylist(uuid, itemIndex, [this, uuid, cb](bool success) mutable {
        // The mirror of the add above, and the same bug: taking a song off a
        // playlist left every cached count one too high.
        call(cb, { success });
        if (success) refreshPlaylistMeta(uuid);
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
        // A track Tidal serves but gives no radio for answers "" and no error.
        // The caller treats both the same - it falls back to the list viewer -
        // but they are different facts and are not folded together here.
        call(cb, { qjsEngine(this)->toScriptValue(t.trackMixId),
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
    // Invalidate any in-flight tracks-paging chain so its stale callbacks stop
    // appending after this reset (otherwise the old chain re-adds page 0).
    ++m_favTracksLoadGen;

    m_favTracksSettled = false;
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

void TidalBridge::loadFavoriteMixIds() {
    const int gen = ++m_favMixesLoadGen;
    m_favoriteMixIds.clear();
    // Not merged with loadFavoriteTrackIds(): that one walks four offset-paged
    // v1 endpoints and this is one cursor-paged v2 chain that TidalClient already
    // runs to completion for us. One list, one assignment, one signal.
    m_client->fetchFavoriteMixes([this, gen](QList<Mix> mixes, QString err) {
        if (gen != m_favMixesLoadGen) return;
        // A failed load leaves the set empty, which reads as "nothing is saved".
        // That is the right way round: it offers a Save on a mix that may already
        // be saved, and saving an already-saved mix is harmless, whereas guessing
        // the other way would offer an Unsave that could not work.
        if (!err.isEmpty()) return;
        for (const Mix &m : mixes)
            if (!m.id.isEmpty()) m_favoriteMixIds.insert(m.id);
        emit favoriteMixesChanged();
    });
}

void TidalBridge::loadNextFavoriteTracksPage(int offset) {
    if (m_client->userId() == 0) return;
    const int gen = m_favTracksLoadGen;
    m_client->fetchFavoriteTracks([this, offset, gen](QList<Track> tracks, QString err) {
        // A newer load has superseded this chain — stop before touching state.
        if (gen != m_favTracksLoadGen) return;
        if (!err.isEmpty() || tracks.isEmpty()) {
            // The last page. Until here the list is in the endpoint's order,
            // which is oldest like first; from here it is newest first, which
            // is what every reader of it expects.
            std::reverse(m_favoriteTracks.begin(), m_favoriteTracks.end());
            m_favTracksSettled = true;
            emit favoriteTracksChanged();
            return;
        }
        for (const auto &t : tracks) {
            // Skip tracks already seen this load — overlapping API windows
            // (order=DATE) would otherwise duplicate boundary items.
            if (m_favoriteTrackIds.contains(t.id)) continue;
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
    // The play times are kept per account, so without a session there are none
    // to read; the playlists' own addedAt still orders them.
    if (uid > 0) {
        QSettings settings;
        playtimes = settings.value(
            QStringLiteral("user_%1/playlists/lastPlayed").arg(uid)).toMap();
    }
    sortPlaylistsByRecency(playlists, playtimes);
}


