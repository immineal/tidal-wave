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
QList<QList<Album>> recordVersions(const QList<Album> &albums);

// One entry per record: the best member of each group of recordVersions().
// Sets Album::titleShared on each entry whose row shows another of its title.
QList<Album> oneEntryPerRecord(const QList<Album> &albums);

} // namespace Tidal
