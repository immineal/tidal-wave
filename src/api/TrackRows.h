// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QMetaType>
#include <QVariant>
#include <QVariantList>

// A long list of track maps handed through QML untouched. JS sees an opaque
// value, so nothing is converted on the way; a C++ parameter that takes a
// QVariantList (Player::playTracks, TrackModel::source) takes it as one.
struct TrackRows {
    QVariantList rows;
};
Q_DECLARE_METATYPE(TrackRows)

namespace Tidal {

inline QVariant wrapRows(QVariantList rows) {
    static const bool registered = QMetaType::registerConverter<TrackRows, QVariantList>(
        [](const TrackRows &r) { return r.rows; });
    Q_UNUSED(registered);
    return QVariant::fromValue(TrackRows{std::move(rows)});
}

} // namespace Tidal
