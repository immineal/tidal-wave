// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QList>
#include <QString>
#include <QJsonObject>

#include "Models.h"

// The account's library as last loaded whole, on disk, so a start without a
// connection shows it instead of an empty library. Each model is written in
// the API's own shape and read back with its fromJson().
namespace FavoritesCache {

struct Lists {
    QList<Tidal::Track>    tracks;
    QList<Tidal::Album>    albums;
    QList<Tidal::Artist>   artists;
    QList<Tidal::Playlist> playlists;
    QList<Tidal::Mix>      mixes;
    bool loaded = false;      // a file for this account was read
};

// Under the app's data dir, beside LibraryIndex's tracklist cache. `name`
// keeps the two writers apart: their lists are in different orders.
QString path(const QString &name, qint64 userId);

bool  save(const QString &path, qint64 userId, const Lists &lists);
// Empty, and `loaded` false, for a missing file, another account's file or
// one from another version.
Lists load(const QString &path, qint64 userId);

QJsonObject toJson(const Tidal::Artist &a);
QJsonObject toJson(const Tidal::Album &a);
QJsonObject toJson(const Tidal::Track &t);
QJsonObject toJson(const Tidal::Playlist &p);
QJsonObject toJson(const Tidal::Mix &m);

} // namespace FavoritesCache
