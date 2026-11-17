// SPDX-License-Identifier: GPL-3.0-or-later

#include "FavoritesCache.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTimeZone>

using namespace Tidal;

namespace FavoritesCache {

namespace {

constexpr int kVersion = 1;

QString iso(qint64 ms) {
    if (ms <= 0) return {};
    return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::utc()).toString(Qt::ISODateWithMs);
}

QJsonArray strings(const QStringList &l) {
    QJsonArray out;
    for (const QString &s : l) out.append(s);
    return out;
}

template <typename T>
QJsonArray arrayOf(const QList<T> &items) {
    QJsonArray out;
    for (const T &x : items) out.append(toJson(x));
    return out;
}

} // namespace

QJsonObject toJson(const Artist &a) {
    QJsonObject o;
    o["id"]      = double(a.id);
    o["name"]    = a.name;
    o["picture"] = a.picture;
    o["created"] = iso(a.addedAt);
    return o;
}

QJsonObject toJson(const Album &a) {
    QJsonObject o;
    o["id"]             = double(a.id);
    o["title"]          = a.title;
    o["cover"]          = a.cover;
    o["numberOfTracks"] = a.numTracks;
    o["duration"]       = a.duration;
    o["releaseDate"]    = a.releaseDate;
    o["audioQuality"]   = a.audioQuality;
    o["type"]           = a.type;
    o["copyright"]      = a.copyright;
    o["upc"]            = a.upc;
    o["artists"]        = arrayOf(a.artists);
    o["created"]        = iso(a.addedAt);
    o["version"]        = a.version;
    o["explicit"]       = a.explicit_;
    o["audioModes"]     = strings(a.audioModes);
    o["mediaMetadata"]  = QJsonObject{{"tags", strings(a.mediaTags)}};
    o["numberOfVideos"] = a.numVideos;
    o["popularity"]     = a.popularity;
    o["allowStreaming"] = a.allowStreaming;
    o["streamReady"]    = a.streamReady;
    return o;
}

QJsonObject toJson(const Track &t) {
    QJsonObject o;
    o["id"]             = double(t.id);
    o["title"]          = t.title;
    o["version"]        = t.version;
    o["duration"]       = t.duration;
    o["trackNumber"]    = t.trackNumber;
    o["volumeNumber"]   = t.discNumber;
    o["explicit"]       = t.explicit_;
    o["popularity"]     = t.popularity;
    o["audioQuality"]   = t.audioQuality;
    o["isrc"]           = t.isrc;
    o["allowStreaming"] = t.streamable;
    o["streamReady"]    = true;
    if (!t.trackMixId.isEmpty())
        o["mixes"] = QJsonObject{{QLatin1String(MixTypes::TrackMix), t.trackMixId}};
    o["album"]          = toJson(t.album);
    o["artists"]        = arrayOf(t.artists);
    return o;
}

QJsonObject toJson(const Playlist &p) {
    QJsonObject o;
    o["uuid"]           = p.uuid;
    o["title"]          = p.title;
    o["description"]    = p.description;
    o["numberOfTracks"] = p.numTracks;
    o["duration"]       = p.duration;
    o["squareImage"]    = p.image;
    o["type"]           = p.type;
    o["creator"]        = QJsonObject{{"id", double(p.creatorId)}};
    o["created"]        = iso(p.addedAt);
    return o;
}

QJsonObject toJson(const Mix &m) {
    QJsonObject o;
    o["id"]        = m.id;
    o["title"]     = m.title;
    o["subTitle"]  = m.subTitle;
    o["mixType"]   = m.mixType;
    o["images"]    = QJsonObject{{"LARGE", QJsonObject{{"url", m.cover}}}};
    o["dateAdded"] = iso(m.addedAt);
    return o;
}

QString path(const QString &name, qint64 userId) {
    const QString root = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return root + QStringLiteral("/library/%1-%2.json").arg(name).arg(userId);
}

bool save(const QString &file, qint64 userId, const Lists &lists) {
    if (userId <= 0) return false;
    QJsonObject root;
    root["version"]   = kVersion;
    root["userId"]    = double(userId);
    root["tracks"]    = arrayOf(lists.tracks);
    root["albums"]    = arrayOf(lists.albums);
    root["artists"]   = arrayOf(lists.artists);
    root["playlists"] = arrayOf(lists.playlists);
    root["mixes"]     = arrayOf(lists.mixes);

    QDir().mkpath(QFileInfo(file).absolutePath());
    QSaveFile f(file);
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    return f.commit();
}

Lists load(const QString &file, qint64 userId) {
    Lists out;
    if (userId <= 0) return out;
    QFile f(file);
    if (!f.open(QIODevice::ReadOnly)) return out;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) return out;
    const QJsonObject root = doc.object();
    if (root["version"].toInt() != kVersion) return out;
    if (qint64(root["userId"].toDouble()) != userId) return out;

    for (const auto &v : root["tracks"].toArray())
        out.tracks.append(Track::fromJson(v.toObject()));
    for (const auto &v : root["albums"].toArray())
        out.albums.append(Album::fromJson(v.toObject(), v.toObject()));
    for (const auto &v : root["artists"].toArray())
        out.artists.append(Artist::fromJson(v.toObject(), v.toObject()));
    for (const auto &v : root["playlists"].toArray())
        out.playlists.append(Playlist::fromJson(v.toObject(), v.toObject()));
    for (const auto &v : root["mixes"].toArray())
        out.mixes.append(Mix::fromJson(v.toObject()));
    out.loaded = true;
    return out;
}

} // namespace FavoritesCache
