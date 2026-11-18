// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QString>

// A Tidal link reduced to what it opens. Takes tidal:// links and the
// tidal.com and listen.tidal.com web links, with or without /browse.
struct TidalLink {
    // "track", "album", "artist", "playlist" or "mix"; empty when not a link.
    QString kind;
    // A number for tracks, albums and artists, a lower-case UUID for
    // playlists, the mix id for mixes.
    QString id;

    bool isValid() const { return !kind.isEmpty(); }

    static TidalLink parse(const QString &text);
};
