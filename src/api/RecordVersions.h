// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QList>
#include <QString>

#include "Models.h"

namespace Tidal {

// The artist page's three rows.
enum class RecordSection { Albums, SinglesAndEps, AppearsOn };

// The row a release belongs in. Album::featured outranks the type, and the
// track count decides only where the response carried no type.
RecordSection recordSection(const Album &a);

// The same as the letter an album map carries for QML: "a", "s" or "f".
QString recordSectionKey(const Album &a);

// Tidal lists every product of a record under its own id: explicit and clean,
// each as 16-bit, hi-res and Dolby Atmos only. This sorts a list into its
// records, each at the place of its first member, the members best first.
// `preferExplicit` says which of explicit and clean is better.
QList<QList<Album>> recordVersions(const QList<Album> &albums, bool preferExplicit = true);

// One entry per record: the best member of each group of recordVersions().
// Sets Album::titleShared on each entry whose row shows another of its title.
QList<Album> oneEntryPerRecord(const QList<Album> &albums, bool preferExplicit = true);

// A list with each release that it holds in both versions, explicit and
// clean, cut to the preferred one. A release of one version only stays, and
// so does the other version where the preferred one cannot be streamed.
// Albums pair on title, artists, track count and length; tracks on title,
// artists and length.
QList<Album> preferredVersions(const QList<Album> &albums, bool preferExplicit);
QList<Track> preferredVersions(const QList<Track> &tracks, bool preferExplicit);

// The index in `among` of the preferred version of this release, where
// `among` holds it and this is the other version; -1 otherwise.
qsizetype preferredCounterpart(const Album &album, const QList<Album> &among, bool preferExplicit);
qsizetype preferredCounterpart(const Track &track, const QList<Track> &among, bool preferExplicit);

// The albums in `among` that are `album` with the other explicit flag: same
// title, artists, track count and length.
QList<Album> versionCounterparts(const Album &album, const QList<Album> &among);

} // namespace Tidal
