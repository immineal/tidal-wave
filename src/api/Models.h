// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QString>
#include <QList>
#include <QUrl>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>

namespace Tidal {

enum class AudioQuality { Low96k, Low320k, Lossless, HiResLossless };
enum class MediaType { Track, Album, Artist, Playlist, Mix };

// Tidal reports dates as ISO-8601 strings. An unparseable or absent one
// answers 0: toMSecsSinceEpoch() on an invalid QDateTime is undefined.
inline qint64 isoToMSecs(const QString &iso) {
    if (iso.isEmpty()) return 0;
    const QDateTime dt = QDateTime::fromString(iso, Qt::ISODate);
    return dt.isValid() ? dt.toMSecsSinceEpoch() : 0;
}

// The `mixType` values the app acts on. Any other value is carried through as
// the string the page sent.
namespace MixTypes {
inline constexpr auto DailyDiscovery = "DISCOVERY_MIX";   // "My Daily Discovery"
inline constexpr auto NewArrivals    = "NEW_RELEASE_MIX"; // "My New Arrivals"
// Dropped from the generated list only, see parseMixPage(). A saved one is
// kept like any other saved mix.
inline constexpr auto VideoDailyMix  = "VIDEO_DAILY_MIX";
// A track's radio station. `tracks/<id>` carries its id under
// `mixes.TRACK_MIX`, so a radio can open on MixPage and be saved.
inline constexpr auto TrackMix       = "TRACK_MIX";
// The other key `mixes` can carry. Nothing reads an artist radio yet.
inline constexpr auto ArtistMix      = "ARTIST_MIX";
} // namespace MixTypes

struct Artist {
    qint64 id = 0;
    QString name;
    QString picture; // UUID for art
    // When this user followed the artist, in ms since epoch. 0 when the
    // response carried no date.
    qint64  addedAt = 0;

    // `wrapper` is the favourites row the artist arrived in, if any:
    // users/<id>/favorites/artists answers {"created": …, "item": {…}}.
    static Artist fromJson(const QJsonObject &j, const QJsonObject &wrapper = QJsonObject()) {
        Artist a;
        a.id   = j["id"].toVariant().toLongLong();
        a.name = j["name"].toString();
        a.picture = j["picture"].toString();
        a.addedAt = isoToMSecs(wrapper["created"].toString());
        return a;
    }
};

struct Album {
    qint64  id = 0;
    QString title;
    QString cover;      // UUID for art
    int     numTracks = 0;
    int     duration  = 0;
    QString releaseDate;
    QString audioQuality;
    QString type;       // ALBUM / SINGLE / EP / COMPILATION
    // The rights line and the barcode. Both arrive only on albums/<id>; an
    // album nested in a track or a favourites row carries neither.
    QString copyright;
    QString upc;
    QList<Artist> artists;
    // When this user saved the album, in ms since epoch. 0 when the response
    // carried no date. Half of the sidebar's ordering key, so it must not be
    // releaseDate.
    qint64  addedAt = 0;
    // Somebody else's record that this artist appears on. No response carries
    // it: TidalClient::fetchArtistAlbums() sets it from the request that
    // answered, and it is false everywhere else.
    bool    featured = false;
    // What tells the products of one record apart. Tidal lists each of them
    // under its own id: see RecordVersions.h.
    QString     version;
    bool        explicit_  = false;
    QStringList audioModes;     // STEREO, DOLBY_ATMOS
    QStringList mediaTags;      // LOSSLESS, HIRES_LOSSLESS, DOLBY_ATMOS
    int         numVideos  = 0; // Album::duration counts them
    int         popularity = 0;
    // True where the response says nothing: an album nested in a track
    // carries neither.
    bool        allowStreaming = true;
    bool        streamReady    = true;

    QString coverUrl(int size = 320) const {
        if (cover.isEmpty()) return {};
        QString u = cover;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    // `wrapper` is the favourites row the album arrived in, if any. Its
    // "created" is this user's save date; the album inside carries no date.
    static Album fromJson(const QJsonObject &j, const QJsonObject &wrapper = QJsonObject()) {
        Album a;
        a.id           = j["id"].toVariant().toLongLong();
        a.title        = j["title"].toString();
        a.cover        = j["cover"].toString();
        a.numTracks    = j["numberOfTracks"].toInt();
        a.duration     = j["duration"].toInt();
        a.releaseDate  = j["releaseDate"].toString();
        a.audioQuality = j["audioQuality"].toString();
        a.type         = j["type"].toString();
        a.copyright    = j["copyright"].toString();
        a.upc          = j["upc"].toString();
        for (const auto &v : j["artists"].toArray())
            a.artists.append(Artist::fromJson(v.toObject()));
        a.addedAt = isoToMSecs(wrapper["created"].toString());
        a.version      = j["version"].toString();
        a.explicit_    = j["explicit"].toBool();
        for (const auto &v : j["audioModes"].toArray())
            a.audioModes.append(v.toString());
        for (const auto &v : j["mediaMetadata"]["tags"].toArray())
            a.mediaTags.append(v.toString());
        a.numVideos      = j["numberOfVideos"].toInt();
        a.popularity     = j["popularity"].toInt();
        a.allowStreaming = j["allowStreaming"].toBool(true);
        a.streamReady    = j["streamReady"].toBool(true);
        return a;
    }

    QString artistNames() const {
        QStringList names;
        for (const auto &a : artists) names << a.name;
        return names.join(", ");
    }
};

struct Track {
    qint64  id = 0;
    QString title;
    int     duration = 0;
    int     trackNumber = 0;
    int     discNumber  = 1;
    bool    explicit_  = false;
    int     popularity  = 0;
    QString audioQuality;
    Album   album;
    QList<Artist> artists;
    // This track's radio as a mix id, from `mixes.TRACK_MIX`. Empty is a
    // normal case: a listing endpoint may omit `mixes`, and TrackRow then
    // falls back to RadioPage.
    QString trackMixId;

    static Track fromJson(const QJsonObject &j) {
        Track t;
        t.id           = j["id"].toVariant().toLongLong();
        t.title        = j["title"].toString();
        t.duration     = j["duration"].toInt();
        t.trackNumber  = j["trackNumber"].toInt();
        t.discNumber   = j["volumeNumber"].toInt(1);
        t.explicit_    = j["explicit"].toBool();
        t.popularity   = j["popularity"].toInt();
        t.audioQuality = j["audioQuality"].toString();
        // A hex string, unlike a numeric track id. A missing `mixes` yields "".
        t.trackMixId   = j["mixes"].toObject()[MixTypes::TrackMix].toString();
        if (j.contains("album"))
            t.album    = Album::fromJson(j["album"].toObject());
        for (const auto &v : j["artists"].toArray())
            t.artists.append(Artist::fromJson(v.toObject()));
        // Some endpoints send a top-level artistId when the artist objects lack an id.
        if (!t.artists.isEmpty() && t.artists[0].id == 0) {
            qint64 fallback = j["artistId"].toVariant().toLongLong();
            if (fallback > 0) t.artists[0].id = fallback;
        }
        return t;
    }

    QString artistNames() const {
        QStringList names;
        for (const auto &a : artists) names << a.name;
        return names.join(", ");
    }

    QString durationString() const {
        int m = duration / 60;
        int s = duration % 60;
        return QStringLiteral("%1:%2").arg(m).arg(s, 2, 10, QChar('0'));
    }

    QString coverUrl(int size = 320) const {
        return album.coverUrl(size);
    }
};

// Who made one recording, and the small print that goes with it. Assembled
// from tracks/<id>/credits, tracks/<id> and albums/<id>, because no single
// endpoint carries all of it. See TidalClient::fetchTrackCredits.
struct CreditGroup {
    QString type;               // the label's word, e.g. "Producer"
    QList<Artist> contributors; // id and name; the id is not always an artist
};

struct TrackCredits {
    QList<CreditGroup> groups;
    QString copyright;   // the rights line, verbatim
    QString isrc;        // this recording
    QString releaseDate; // the album's, as a full date
    QString upc;         // the album's barcode

    // A track with no contributor groups can still have a date and a rights
    // line to show.
    bool isEmpty() const {
        return groups.isEmpty() && copyright.isEmpty()
            && releaseDate.isEmpty() && isrc.isEmpty() && upc.isEmpty();
    }

    static CreditGroup groupFromJson(const QJsonObject &j) {
        CreditGroup g;
        g.type = j["type"].toString();
        for (const auto &v : j["contributors"].toArray()) {
            const auto o = v.toObject();
            Artist a;
            a.id   = o["id"].toVariant().toLongLong();
            a.name = o["name"].toString();
            if (!a.name.isEmpty()) g.contributors.append(a);
        }
        return g;
    }
};

struct Playlist {
    QString uuid;
    QString title;
    QString description;
    int     numTracks = 0;
    int     duration  = 0;
    QString image;  // UUID
    QString type;   // USER / EDITORIAL
    // When this user created or saved the playlist, in ms since epoch. 0 when
    // the response carried no usable date. Half of the ordering key in
    // sortPlaylistsByRecency() and in LibraryIndex::rebuild().
    qint64  addedAt = 0;

    QString coverUrl(int size = 320) const {
        if (image.isEmpty()) return {};
        QString u = image;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    // `wrapper` is the favourites row the playlist arrived in, if any. Its
    // "created" is this user's save date and wins over the playlist's own,
    // which is the author's. "lastUpdated" moves on every edit and is not read.
    static Playlist fromJson(const QJsonObject &j, const QJsonObject &wrapper = QJsonObject()) {
        Playlist p;
        p.uuid        = j["uuid"].toString();
        p.title       = j["title"].toString();
        p.description = j["description"].toString();
        p.numTracks   = j["numberOfTracks"].toInt();
        p.duration    = j["duration"].toInt();
        // squareImage is the 1:1 art coverUrl() asks for. The plain "image" is
        // a 3:2 crop that answers 403 at square sizes.
        p.image      = j["squareImage"].toString(j["image"].toString());
        p.type        = j["type"].toString();
        p.addedAt     = isoToMSecs(wrapper["created"].toString());
        if (p.addedAt == 0)
            p.addedAt = isoToMSecs(j["created"].toString());
        return p;
    }
};

// Copies the fields a change to a playlist's contents moves and answers
// whether any changed. addedAt stays: `fresh` carries the author's date, which
// would sink the row in the sidebar. description belongs to the rename path.
inline bool mergePlaylistMeta(Playlist &dst, const Playlist &fresh) {
    bool changed = false;
    if (dst.numTracks != fresh.numTracks) { dst.numTracks = fresh.numTracks; changed = true; }
    if (dst.duration  != fresh.duration)  { dst.duration  = fresh.duration;  changed = true; }
    if (dst.image     != fresh.image)     { dst.image     = fresh.image;     changed = true; }
    if (!fresh.title.isEmpty() && dst.title != fresh.title) {
        // Tidal holds no nameless playlist, so an empty title means the reply
        // did not parse. The other three can truly be empty.
        dst.title = fresh.title;
        changed = true;
    }
    return changed;
}

struct Mix {
    QString id;
    QString title;
    QString subTitle;
    QString cover;  // UUID
    // When this user saved the mix, in ms since epoch. Only v2/favorites/mixes
    // carries it, as `dateAdded`; a mix from a `pages/*` feed has 0.
    qint64  addedAt = 0;
    // The only handle code can match a generated mix on: `title` is localised
    // and the id is opaque and per account.
    QString mixType;

    bool isDailyDiscovery() const { return mixType == QLatin1String(MixTypes::DailyDiscovery); }
    bool isNewArrivals()    const { return mixType == QLatin1String(MixTypes::NewArrivals); }
    bool isVideoMix()       const { return mixType == QLatin1String(MixTypes::VideoDailyMix); }
    // A radio station: the mix Tidal builds out of one track.
    bool isTrackMix()      const { return mixType == QLatin1String(MixTypes::TrackMix); }

    QString coverUrl(int size = 320) const {
        if (cover.isEmpty()) return {};
        if (cover.startsWith(QLatin1String("http"))) return cover;
        QString u = cover;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    static Mix fromJson(const QJsonObject &j) {
        Mix m;
        m.id       = j["id"].toString();
        m.title    = j["title"].toString();
        m.subTitle = j["subTitle"].toString();
        // A plain string on every endpoint that labels a mix.
        m.mixType  = j["mixType"].toString();
        // The art sits in one of three places depending on the endpoint.
        // detailImages is the hero-sized set on the v2 shape.
        auto tryImages = [&](const QJsonObject &imgs) {
            if (m.cover.isEmpty() && imgs.contains("LARGE"))
                m.cover = imgs["LARGE"].toObject()["url"].toString();
            if (m.cover.isEmpty() && imgs.contains("MEDIUM"))
                m.cover = imgs["MEDIUM"].toObject()["url"].toString();
            if (m.cover.isEmpty() && imgs.contains("SMALL"))
                m.cover = imgs["SMALL"].toObject()["url"].toString();
        };
        tryImages(j["images"].toObject());
        tryImages(j["detail"].toObject()["images"].toObject());
        tryImages(j["detailImages"].toObject());
        // v2/favorites/mixes only. `updated` beside it is not read: Tidal
        // regenerates mixes daily and the sidebar would reshuffle each time.
        m.addedAt = isoToMSecs(j["dateAdded"].toString());
        return m;
    }
};

struct ArtistDetail {
    qint64 id = 0;
    QString name;
    QString picture;
    QString bio;
    int popularity = 0;
    QList<Album> albums;
    QList<Track> topTracks;
    QList<Artist> similarArtists;

    QString pictureUrl(int size = 480) const {
        if (picture.isEmpty()) return {};
        QString u = picture;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }
};

struct StreamManifest {
    enum Type { BTS, MPD };
    Type    type = BTS;
    QString url;           // BTS: direct URL, MPD: manifest content
    QString mimeType;
    QString codec;
    int     sampleRate = 44100;
    int     bitDepth   = 16;
    double  replayGainTrack = 0.0;
    double  replayGainAlbum = 0.0;
    // Read beside an error: what Tidal's answer says about the track. Unknown
    // when the request itself failed, which says nothing about it.
    enum Reason {
        Unknown,
        Gone,            // Tidal no longer has the track
        NotForAccount,   // Tidal has it and does not play it to this account or region
    };
    Reason  reason = Unknown;
};

struct SearchResults {
    QList<Track>    tracks;
    QList<Album>    albums;
    QList<Artist>   artists;
    QList<Playlist> playlists;
    // Video mixes are dropped before they reach this list, because the app
    // cannot play one. See TidalClient::parseSearchMixes.
    QList<Mix>      mixes;

    // The server's `totalNumberOfItems` per kind. Paging needs it: a short
    // page and the last page look the same otherwise.
    int totalTracks    = 0;
    int totalAlbums    = 0;
    int totalArtists   = 0;
    int totalPlaylists = 0;
    // The count before the video filter, so it bounds paging. Never shown.
    int totalMixes     = 0;
};

} // namespace Tidal
