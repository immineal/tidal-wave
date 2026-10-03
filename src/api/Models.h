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

// Tidal reports dates as ISO-8601 strings ("2024-05-01T10:00:00.000+0000").
// An unparseable or absent one answers 0, because an invalid QDateTime's
// toMSecsSinceEpoch() is not defined and would be sorted on as if it were a
// real instant.
inline qint64 isoToMSecs(const QString &iso) {
    if (iso.isEmpty()) return 0;
    const QDateTime dt = QDateTime::fromString(iso, Qt::ISODate);
    return dt.isValid() ? dt.toMSecsSinceEpoch() : 0;
}

struct Artist {
    qint64 id = 0;
    QString name;
    QString picture; // UUID for art
    // When this user followed the artist, in ms since epoch, 0 when the
    // response carried no date. See Album::addedAt.
    qint64  addedAt = 0;

    // `wrapper` is the favourites row the artist arrived in, where there was
    // one: users/<id>/favorites/artists answers {"created": …, "item": {…}}.
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
    // The two lines the sleeve carries and nothing in the app used to: the
    // rights line ("(P) 1975 ...") verbatim as the label worded it, and the
    // barcode. Both only arrive on albums/<id>; the album object nested inside
    // a track or a favourites row carries neither, which is why a page that
    // wants them has to fetch the album.
    QString copyright;
    QString upc;
    QList<Artist> artists;
    // When this user saved the album, in ms since epoch, 0 when the response
    // carried no date. Half of the sidebar's ordering key - see the comment on
    // LibraryIndex::rebuild(). Deliberately not releaseDate: that is when the
    // record came out, and an old album saved today has to rank as saved today.
    qint64  addedAt = 0;

    QString coverUrl(int size = 320) const {
        if (cover.isEmpty()) return {};
        QString u = cover;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    // `wrapper` is the favourites row the album arrived in, where there was one:
    // users/<id>/favorites/albums answers {"created": …, "item": {…}}, and the
    // "created" is this user's save date. The album object inside it carries no
    // date of its own, so passing only the unwrapped album throws the save date
    // away - which is what the sidebar was doing.
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
        if (j.contains("album"))
            t.album    = Album::fromJson(j["album"].toObject());
        for (const auto &v : j["artists"].toArray())
            t.artists.append(Artist::fromJson(v.toObject()));
        // Fallback: some endpoints include top-level artistId when artist objects lack id
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

// Who made one recording, and the small print that goes with it.
//
// Assembled from three responses rather than one, because no single endpoint
// carries all of it (see TidalClient::fetchTrackCredits):
//
//   tracks/<id>/credits  the contributor groups, as a top-level JSON array
//   tracks/<id>          the track's own rights line and its ISRC
//   albums/<id>          the release date in full, the barcode, and the
//                        album's rights line as a fallback for the track's
//
// albums/<id>/credits exists too and answered zero groups for every album
// probed against this account, so the per-track endpoint is the only one built
// on here.
struct CreditGroup {
    QString type;               // "Producer", "Bass guitar" - the label's word
    QList<Artist> contributors; // id and name; the id is not always an artist
};

struct TrackCredits {
    QList<CreditGroup> groups;
    QString copyright;   // the rights line, verbatim
    QString isrc;        // this recording
    QString releaseDate; // the album's, in full: "2017-09-22", not just a year
    QString upc;         // the album's barcode

    // Whether there is anything at all to put on screen. A track with no
    // contributor groups still has a release date and a rights line, and that
    // is worth a panel; nothing at all is not.
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
    // When this user acquired the playlist — created it or saved someone
    // else's — in ms since epoch, 0 when the response carried no usable date.
    // Half of the ordering key in sortPlaylistsByRecency(), and of the
    // sidebar's in LibraryIndex::rebuild().
    qint64  addedAt = 0;

    QString coverUrl(int size = 320) const {
        if (image.isEmpty()) return {};
        QString u = image;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    // `wrapper` is the favourites row the playlist arrived in, where there was
    // one. Its "created" is when *this* user saved the playlist, while the
    // playlist's own "created" is the original author's and can be years old,
    // so the wrapper's date wins. "lastUpdated" is deliberately not consulted:
    // it moves every time anyone adds a track, which would reorder the home row
    // behind the user's back.
    static Playlist fromJson(const QJsonObject &j, const QJsonObject &wrapper = QJsonObject()) {
        Playlist p;
        p.uuid        = j["uuid"].toString();
        p.title       = j["title"].toString();
        p.description = j["description"].toString();
        p.numTracks   = j["numberOfTracks"].toInt();
        p.duration    = j["duration"].toInt();
        // squareImage is the 1:1 art tidal serves at WxW sizes (what coverUrl
        // requests below); the plain "image" field is a 3:2 widescreen crop
        // that 403s at square dimensions, so prefer squareImage.
        p.image       = j["squareImage"].toString(j["image"].toString());
        p.type        = j["type"].toString();
        p.addedAt     = isoToMSecs(wrapper["created"].toString());
        if (p.addedAt == 0)
            p.addedAt = isoToMSecs(j["created"].toString());
        return p;
    }
};

// The `mixType` constants the app acts on. Every other value is carried through
// as whatever string the page sent; the ones seen in the captured responses the
// tests are built from are DAILY_MIX ("My Mix 1".."My Mix 8") and ARTIST_MIX
// (one radio station per artist).
namespace MixTypes {
inline constexpr auto DailyDiscovery = "DISCOVERY_MIX";   // "My Daily Discovery"
inline constexpr auto NewArrivals    = "NEW_RELEASE_MIX"; // "My New Arrivals"
// "My Video Mix 1".."My Video Mix 7". Dropped from the generated list only - see
// parseMixPage(). TRACK_MIX and ARTIST_MIX, the radio stations, are not written
// down here: nothing branches on them. A saved one is kept like any other saved
// mix, and nothing else is fetched that carries them.
inline constexpr auto VideoDailyMix  = "VIDEO_DAILY_MIX";
} // namespace MixTypes

struct Mix {
    QString id;
    QString title;
    QString subTitle;
    QString cover;  // UUID
    // When this user saved the mix, in ms since epoch, 0 when the response
    // carried no date - which is every mix that came from a `pages/*` feed. Only
    // v2/favorites/mixes says, and it says it per item as `dateAdded`. Half of
    // the sidebar's ordering key, as for Album::addedAt.
    qint64  addedAt = 0;
    // Which generated mix this is. The only handle on a particular mix that
    // code can match on: `title` arrives in the account's language, and the id
    // is an opaque string the account's own pages carry, so neither can be
    // written down anywhere. (The two example ids that used to stand here as
    // evidence came from a fabricated fixture; they are gone with it.)
    QString mixType;

    bool isDailyDiscovery() const { return mixType == QLatin1String(MixTypes::DailyDiscovery); }
    bool isNewArrivals()    const { return mixType == QLatin1String(MixTypes::NewArrivals); }
    bool isVideoMix()       const { return mixType == QLatin1String(MixTypes::VideoDailyMix); }

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
        // A plain string on every endpoint that labels a mix at all -
        // "DISCOVERY_MIX", not an object. It used to be read as one, purely to
        // look for artwork inside it; that lookup therefore always came up
        // empty and is gone. detailImages is the hero-sized set that really
        // does sit beside `images` on the v2 shape.
        m.mixType  = j["mixType"].toString();
        // Try multiple known image locations in the API response
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
        // v2/favorites/mixes only. Its dates carry six fractional digits
        // ("2026-06-08T19:33:03.142667Z"), which Qt::ISODate parses and rounds to
        // the millisecond; `updated` sits beside it and is deliberately not read,
        // because Tidal regenerates these daily and the sidebar would reshuffle
        // itself every morning.
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
};

struct SearchResults {
    QList<Track>    tracks;
    QList<Album>    albums;
    QList<Artist>   artists;
    QList<Playlist> playlists;
    // Mixes are a sixth kind the catalogue can answer with, filtered the way
    // the Home row filters them: a VIDEO_DAILY_MIX is dropped before it ever
    // reaches this struct, because the app cannot play one (see
    // TidalClient::parseSearchMixes and the long note on parseMixPage).
    QList<Mix>      mixes;

    // How many the server says it has, per kind, out of `totalNumberOfItems`
    // beside each list. These used to be parsed and then thrown away one layer
    // up, which left the page with no way to know it had reached the end of a
    // kind: a short page and the last page look identical when the only thing
    // you can count is what you were handed.
    int totalTracks    = 0;
    int totalAlbums    = 0;
    int totalArtists   = 0;
    int totalPlaylists = 0;
    // The count *before* the video filter, so "20 of 57" stays honest about
    // what paging has left to ask for. The page never shows it; it bounds the
    // run (see SearchPage's `_more`).
    int totalMixes     = 0;
};

} // namespace Tidal
