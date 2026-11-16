// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QJsonObject>
#include <QMetaType>
#include <QString>
#include <QVariantMap>

// One play of a track, as a scrobbling service is told about it. The same
// shape goes to every service and into the queue on disk.
struct Listen {
    qint64  trackId = 0;
    QString artist;
    QString title;
    QString album;
    qint64  durationMs = 0;
    int     trackNumber = 0;
    QString isrc;
    // When the play started, in seconds since the epoch. 0 for "playing now".
    qint64  listenedAt = 0;

    bool isValid() const { return trackId != 0 && !artist.isEmpty() && !title.isEmpty(); }

    // From a row as Player keeps it (TidalBridge::trackToMap()).
    static Listen fromTrackMap(const QVariantMap &m) {
        Listen l;
        l.trackId     = m.value(QStringLiteral("id")).toLongLong();
        l.artist      = m.value(QStringLiteral("artists")).toString();
        l.title       = m.value(QStringLiteral("title")).toString();
        l.album       = m.value(QStringLiteral("albumTitle")).toString();
        l.durationMs  = m.value(QStringLiteral("duration")).toLongLong() * 1000;
        l.trackNumber = m.value(QStringLiteral("trackNumber")).toInt();
        l.isrc        = m.value(QStringLiteral("isrc")).toString();
        return l;
    }

    // The queue file's own form, not any service's.
    QJsonObject toStored() const {
        QJsonObject o;
        o[QStringLiteral("id")]          = trackId;
        o[QStringLiteral("artist")]      = artist;
        o[QStringLiteral("title")]       = title;
        o[QStringLiteral("album")]       = album;
        o[QStringLiteral("duration_ms")] = durationMs;
        o[QStringLiteral("track")]       = trackNumber;
        o[QStringLiteral("isrc")]        = isrc;
        o[QStringLiteral("listened_at")] = listenedAt;
        return o;
    }
    static Listen fromStored(const QJsonObject &o) {
        Listen l;
        l.trackId     = o.value(QStringLiteral("id")).toVariant().toLongLong();
        l.artist      = o.value(QStringLiteral("artist")).toString();
        l.title       = o.value(QStringLiteral("title")).toString();
        l.album       = o.value(QStringLiteral("album")).toString();
        l.durationMs  = o.value(QStringLiteral("duration_ms")).toVariant().toLongLong();
        l.trackNumber = o.value(QStringLiteral("track")).toInt();
        l.isrc        = o.value(QStringLiteral("isrc")).toString();
        l.listenedAt  = o.value(QStringLiteral("listened_at")).toVariant().toLongLong();
        return l;
    }

    bool operator==(const Listen &o) const {
        return trackId == o.trackId && artist == o.artist && title == o.title
            && album == o.album && durationMs == o.durationMs
            && trackNumber == o.trackNumber && isrc == o.isrc && listenedAt == o.listenedAt;
    }
};
Q_DECLARE_METATYPE(Listen)
