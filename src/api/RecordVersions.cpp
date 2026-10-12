// SPDX-License-Identifier: GPL-3.0-or-later

#include "RecordVersions.h"

#include <QHash>

#include <algorithm>
#include <utility>

namespace Tidal {

namespace {

bool streamable(const Album &a) { return a.allowStreaming && a.streamReady; }

// A product that names its modes and no stereo among them is Dolby Atmos only.
bool stereo(const Album &a) {
    return a.audioModes.isEmpty() || a.audioModes.contains(QLatin1String("STEREO"));
}

bool hiRes(const Album &a) {
    return a.mediaTags.contains(QLatin1String("HIRES_LOSSLESS"));
}

// True when `a` stands for a record before `b` does. The id comes last, so
// two entries never tie.
bool standsBefore(const Album &a, const Album &b) {
    if (streamable(a) != streamable(b)) return streamable(a);
    if (a.explicit_ != b.explicit_)     return a.explicit_;
    if (stereo(a) != stereo(b))         return stereo(a);
    if (hiRes(a) != hiRes(b))           return hiRes(a);
    if (a.popularity != b.popularity)   return a.popularity > b.popularity;
    return a.id < b.id;
}

// Within 3 % of the longer one.
bool near(int a, int b) {
    return 100 * qAbs(qint64(a) - b) <= 3 * qint64(qMax(a, b));
}

// Case and spacing say nothing about which record a title names.
QString titleKey(const QString &title) {
    return title.simplified().toCaseFolded();
}

} // namespace

RecordSection recordSection(const Album &a) {
    if (a.featured) return RecordSection::AppearsOn;
    if (a.type == QLatin1String("SINGLE") || a.type == QLatin1String("EP"))
        return RecordSection::SinglesAndEps;
    if (a.type == QLatin1String("ALBUM") || a.type == QLatin1String("COMPILATION"))
        return RecordSection::Albums;
    return a.numTracks <= 3 ? RecordSection::SinglesAndEps : RecordSection::Albums;
}

QString recordSectionKey(const Album &a) {
    switch (recordSection(a)) {
        case RecordSection::Albums:        break;
        case RecordSection::SinglesAndEps: return QStringLiteral("s");
        case RecordSection::AppearsOn:     return QStringLiteral("f");
    }
    return QStringLiteral("a");
}

QList<QList<Album>> recordVersions(const QList<Album> &albums) {
    // Candidates for one record share the row, the title and the track count.
    // An entry without a title is a candidate for nothing.
    QHash<QString, qsizetype> bucketOf;
    QList<QList<qsizetype>> buckets;
    for (qsizetype i = 0; i < albums.size(); ++i) {
        const Album &a = albums.at(i);
        const QString title = titleKey(a.title);
        if (title.isEmpty()) { buckets.append(QList<qsizetype>{i}); continue; }
        const QString key = recordSectionKey(a) + QString::number(a.numTracks)
                            + QLatin1Char('/') + title;
        auto it = bucketOf.find(key);
        if (it == bucketOf.end()) {
            it = bucketOf.insert(key, buckets.size());
            buckets.append(QList<qsizetype>());
        }
        buckets[*it].append(i);
    }

    QList<QList<qsizetype>> records;
    for (QList<qsizetype> &bucket : buckets) {
        // Best first, so what comes out depends on the entries alone and on
        // no order they arrived in: "within 3 %" is not transitive.
        std::stable_sort(bucket.begin(), bucket.end(), [&albums](qsizetype x, qsizetype y) {
            return standsBefore(albums.at(x), albums.at(y));
        });
        const qsizetype firstOfBucket = records.size();
        for (qsizetype i : std::as_const(bucket)) {
            const Album &a = albums.at(i);
            bool placed = false;
            for (qsizetype r = firstOfBucket; r < records.size() && !placed; ++r) {
                // Measured against the record's best member with as many
                // videos: an album's duration counts its videos.
                QList<qsizetype> &record = records[r];
                const auto like = std::find_if(record.cbegin(), record.cend(),
                    [&](qsizetype j) { return albums.at(j).numVideos == a.numVideos; });
                if (like == record.cend() || near(albums.at(*like).duration, a.duration)) {
                    record.append(i);
                    placed = true;
                }
            }
            if (!placed) records.append(QList<qsizetype>{i});
        }
    }

    // Each record at the place of its first member.
    std::sort(records.begin(), records.end(),
              [](const QList<qsizetype> &x, const QList<qsizetype> &y) {
        return *std::min_element(x.cbegin(), x.cend()) < *std::min_element(y.cbegin(), y.cend());
    });

    QList<QList<Album>> out;
    out.reserve(records.size());
    for (const QList<qsizetype> &record : std::as_const(records)) {
        QList<Album> members;
        members.reserve(record.size());
        for (qsizetype i : record) members.append(albums.at(i));
        out.append(members);
    }
    return out;
}

QList<Album> oneEntryPerRecord(const QList<Album> &albums) {
    const QList<QList<Album>> records = recordVersions(albums);
    QList<Album> out;
    out.reserve(records.size());
    for (const QList<Album> &record : records) out.append(record.first());
    return out;
}

} // namespace Tidal
