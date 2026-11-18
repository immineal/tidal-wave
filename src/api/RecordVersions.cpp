// SPDX-License-Identifier: GPL-3.0-or-later

#include "RecordVersions.h"

#include <QHash>
#include <QStringList>

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
bool standsBefore(const Album &a, const Album &b, bool preferExplicit) {
    if (streamable(a) != streamable(b)) return streamable(a);
    if (a.explicit_ != b.explicit_)     return a.explicit_ == preferExplicit;
    if (stereo(a) != stereo(b))         return stereo(a);
    if (hiRes(a) != hiRes(b))           return hiRes(a);
    if (a.popularity != b.popularity)   return a.popularity > b.popularity;
    return a.id < b.id;
}

// Within 5 % of the longer one.
bool near(int a, int b) {
    return 100 * qAbs(qint64(a) - b) <= 5 * qint64(qMax(a, b));
}

// Case and spacing say nothing about which record a title names.
QString titleKey(const QString &title) {
    return title.simplified().toCaseFolded();
}

// The credited artists by id, in order, as one key.
QString artistKey(const QList<Artist> &artists) {
    QStringList ids;
    for (const Artist &a : artists) ids << QString::number(a.id);
    return ids.join(QLatin1Char(','));
}

bool sameRelease(const Album &a, const Album &b) {
    return a.numTracks == b.numTracks && a.numVideos == b.numVideos
        && near(a.duration, b.duration)
        && artistKey(a.artists) == artistKey(b.artists);
}

// A clean edit runs as long as the explicit cut, give or take a second or
// two; a live or a remixed take of the same title does not.
bool sameRelease(const Track &a, const Track &b) {
    return qAbs(a.duration - b.duration) <= 3
        && artistKey(a.artists) == artistKey(b.artists);
}

bool canStream(const Album &a) { return streamable(a); }
bool canStream(const Track &t) { return t.streamable; }

// Where in `among` the preferred version of `a` is, when `a` is the other
// version of a release that `among` holds in both; -1 otherwise.
template <typename T>
qsizetype counterpartOf(const T &a, const QList<T> &among, bool preferExplicit) {
    if (a.explicit_ == preferExplicit || titleKey(a.title).isEmpty()) return -1;
    for (qsizetype j = 0; j < among.size(); ++j) {
        const T &b = among.at(j);
        if (b.id != a.id && b.explicit_ == preferExplicit
            && titleKey(b.title) == titleKey(a.title)
            && sameRelease(a, b) && (canStream(b) || !canStream(a)))
            return j;
    }
    return -1;
}

template <typename T>
QList<T> cutToPreferred(const QList<T> &items, bool preferExplicit) {
    QList<T> out;
    for (const T &a : items)
        if (counterpartOf(a, items, preferExplicit) < 0) out.append(a);
    return out;
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

QList<QList<Album>> recordVersions(const QList<Album> &albums, bool preferExplicit) {
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
        // no order they arrived in: "within 5 %" is not transitive.
        std::stable_sort(bucket.begin(), bucket.end(), [&albums, preferExplicit](qsizetype x, qsizetype y) {
            return standsBefore(albums.at(x), albums.at(y), preferExplicit);
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

QList<Album> oneEntryPerRecord(const QList<Album> &albums, bool preferExplicit) {
    const QList<QList<Album>> records = recordVersions(albums, preferExplicit);
    QList<Album> out;
    out.reserve(records.size());
    for (const QList<Album> &record : records) out.append(record.first());

    // Counted over the entries shown, so the products folded into one count once.
    const auto shownKey = [](const Album &a) {
        const QString title = titleKey(a.title);
        return title.isEmpty() ? QString() : recordSectionKey(a) + QLatin1Char('/') + title;
    };
    QHash<QString, int> entriesOf;
    for (const Album &a : std::as_const(out)) {
        const QString key = shownKey(a);
        if (!key.isEmpty()) ++entriesOf[key];
    }
    for (Album &a : out) {
        const QString key = shownKey(a);
        a.titleShared = !key.isEmpty() && entriesOf.value(key) > 1;
    }
    return out;
}

QList<Album> preferredVersions(const QList<Album> &albums, bool preferExplicit) {
    return cutToPreferred(albums, preferExplicit);
}

QList<Track> preferredVersions(const QList<Track> &tracks, bool preferExplicit) {
    return cutToPreferred(tracks, preferExplicit);
}

qsizetype preferredCounterpart(const Album &album, const QList<Album> &among, bool preferExplicit) {
    return counterpartOf(album, among, preferExplicit);
}

qsizetype preferredCounterpart(const Track &track, const QList<Track> &among, bool preferExplicit) {
    return counterpartOf(track, among, preferExplicit);
}

QList<Album> versionCounterparts(const Album &album, const QList<Album> &among) {
    QList<Album> out;
    for (const Album &b : among)
        if (b.id != album.id && b.explicit_ != album.explicit_
            && titleKey(b.title) == titleKey(album.title) && sameRelease(album, b))
            out.append(b);
    return out;
}

} // namespace Tidal
