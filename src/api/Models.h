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

struct Artist {
    qint64 id = 0;
    QString name;
    QString picture; // UUID for art

    static Artist fromJson(const QJsonObject &j) {
        Artist a;
        a.id   = j["id"].toVariant().toLongLong();
        a.name = j["name"].toString();
        a.picture = j["picture"].toString();
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
    QList<Artist> artists;

    QString coverUrl(int size = 320) const {
        if (cover.isEmpty()) return {};
        QString u = cover;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    static Album fromJson(const QJsonObject &j) {
        Album a;
        a.id           = j["id"].toVariant().toLongLong();
        a.title        = j["title"].toString();
        a.cover        = j["cover"].toString();
        a.numTracks    = j["numberOfTracks"].toInt();
        a.duration     = j["duration"].toInt();
        a.releaseDate  = j["releaseDate"].toString();
        a.audioQuality = j["audioQuality"].toString();
        for (const auto &v : j["artists"].toArray())
            a.artists.append(Artist::fromJson(v.toObject()));
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

struct Playlist {
    QString uuid;
    QString title;
    QString description;
    int     numTracks = 0;
    int     duration  = 0;
    QString image;  // UUID
    QString type;   // USER / EDITORIAL

    QString coverUrl(int size = 320) const {
        if (image.isEmpty()) return {};
        QString u = image;
        u.replace('-', '/');
        return QStringLiteral("https://resources.tidal.com/images/%1/%2x%2.jpg").arg(u).arg(size);
    }

    static Playlist fromJson(const QJsonObject &j) {
        Playlist p;
        p.uuid        = j["uuid"].toString();
        p.title       = j["title"].toString();
        p.description = j["description"].toString();
        p.numTracks   = j["numberOfTracks"].toInt();
        p.duration    = j["duration"].toInt();
        p.image       = j["image"].toString(j["squareImage"].toString());
        p.type        = j["type"].toString();
        return p;
    }
};

struct Mix {
    QString id;
    QString title;
    QString subTitle;
    QString cover;  // UUID

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
        tryImages(j["mixType"].toObject()["images"].toObject());
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
    int totalTracks    = 0;
    int totalAlbums    = 0;
    int totalArtists   = 0;
    int totalPlaylists = 0;
};

} // namespace Tidal
