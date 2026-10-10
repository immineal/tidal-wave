// SPDX-License-Identifier: GPL-3.0-or-later

#include "PinStore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>

namespace {

// One key per account, in the user_<id>/ namespace TidalBridge uses.
QString pinsKey(qint64 uid) { return QStringLiteral("user_%1/pins").arg(uid); }

// The one-shot marker for the default pin. Separate from the pin list: an
// empty list with the marker set means the user unpinned the default.
QString seedKey(qint64 uid) { return QStringLiteral("user_%1/pinsSeeded").arg(uid); }

constexpr auto kKind     = "kind";
constexpr auto kId       = "id";
constexpr auto kTitle    = "title";
constexpr auto kSubtitle = "subtitle";
constexpr auto kImageUrl = "imageUrl";

// A stored subtitle has to be a datum from Tidal, never text this app
// rendered: a translation or a count goes stale in storage. A playlist has no
// such datum, so its subtitle is dropped on the way in and on load.
QString storableSubtitle(const QString &kind, const QString &subtitle) {
    return kind == QLatin1String("playlist") ? QString() : subtitle;
}

} // namespace

PinStore::PinStore(QObject *parent) : QObject(parent) {}

bool PinStore::isValidKind(const QString &kind) {
    return kind == QLatin1String("album")
        || kind == QLatin1String("playlist")
        || kind == QLatin1String("artist")
        || kind == QLatin1String("mix");
}

void PinStore::setUserId(qint64 uid) {
    if (uid == m_userId) return;
    m_userId = uid;
    load();
    emit changed();
    seedDefaultPin();
}

bool PinStore::wasSeeded() const {
    // Signed out there is no account to seed.
    if (m_userId <= 0) return true;
    return QSettings().value(seedKey(m_userId), false).toBool();
}

void PinStore::markSeeded() const {
    if (m_userId <= 0) return;
    QSettings().setValue(seedKey(m_userId), true);
}

void PinStore::seedDefaultPin() {
    if (m_userId <= 0 || wasSeeded()) return;

    // An account that already has pins gets no default one, and is marked
    // done so the mix list is not fetched for nothing.
    if (!m_items.isEmpty()) { markSeeded(); return; }

    if (!m_mixSource) return;

    const qint64 uid = m_userId;
    m_mixSource([this, uid](QList<Tidal::Mix> mixes, QString err) {
        // Another account signed in, or signed out, while the request was out.
        if (uid != m_userId) return;
        // A failed request is retried on the next launch.
        if (!err.isEmpty()) return;
        // So is an empty list: Tidal generates these mixes from listening
        // history, and a new account has none yet.
        if (mixes.isEmpty()) return;
        // The user pinned something by hand while the request was out.
        if (!m_items.isEmpty()) { markSeeded(); return; }

        // Marked whether or not either mix exists, so a seeded row the user
        // unpins is not handed back on the next launch.
        markSeeded();

        // Walked by wanted type, since the endpoint promises no order. Matched
        // by mixType: titles arrive in the account's language. An account
        // with only one of the two gets that one.
        for (const char *wanted : {Tidal::MixTypes::DailyDiscovery,
                                   Tidal::MixTypes::NewArrivals}) {
            for (const Tidal::Mix &m : mixes) {
                if (m.mixType != QLatin1String(wanted)) continue;
                pin(QStringLiteral("mix"), m.id, m.title, m.subTitle, m.coverUrl(320));
                break;
            }
        }
    });
}

QVariantList PinStore::items() const { return m_items; }

int PinStore::indexOf(const QString &kind, const QString &id) const {
    for (int i = 0; i < m_items.size(); ++i) {
        const QVariantMap m = m_items.at(i).toMap();
        if (m.value(QLatin1String(kKind)).toString() == kind
            && m.value(QLatin1String(kId)).toString() == id)
            return i;
    }
    return -1;
}

bool PinStore::isPinned(const QString &kind, const QString &id) const {
    return indexOf(kind, id) >= 0;
}

void PinStore::pin(const QString &kind, const QString &id, const QString &title,
                   const QString &subtitle, const QString &imageUrl) {
    if (!isValidKind(kind) || id.isEmpty()) return;

    QVariantMap row;
    row[QLatin1String(kKind)]     = kind;
    row[QLatin1String(kId)]       = id;
    row[QLatin1String(kTitle)]    = title;
    row[QLatin1String(kSubtitle)] = storableSubtitle(kind, subtitle);
    row[QLatin1String(kImageUrl)] = imageUrl;

    const int at = indexOf(kind, id);
    if (at >= 0) {
        // Already pinned: refresh the label and art, keep the position.
        if (m_items.at(at).toMap() == row) return;
        m_items[at] = row;
    } else {
        m_items.append(row);
    }
    save();
    emit changed();
}

void PinStore::unpin(const QString &kind, const QString &id) {
    const int at = indexOf(kind, id);
    if (at < 0) return;
    m_items.removeAt(at);
    save();
    emit changed();
}

void PinStore::toggle(const QString &kind, const QString &id, const QString &title,
                      const QString &subtitle, const QString &imageUrl) {
    if (isPinned(kind, id)) unpin(kind, id);
    else                    pin(kind, id, title, subtitle, imageUrl);
}

void PinStore::move(int from, int to) {
    // A drag that ends where it started, or outside the list, is not an edit.
    if (from == to) return;
    if (from < 0 || from >= m_items.size()) return;
    if (to   < 0 || to   >= m_items.size()) return;
    m_items.move(from, to);
    save();
    emit changed();
}

void PinStore::load() {
    m_items.clear();
    if (m_userId <= 0) return;

    QSettings settings;
    const QString raw = settings.value(pinsKey(m_userId)).toString();
    if (raw.isEmpty()) return;

    // Anything unreadable counts as no pins.
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isArray()) return;

    for (const QJsonValue &v : doc.array()) {
        if (!v.isObject()) continue;
        const QJsonObject o = v.toObject();
        const QString kind = o.value(QLatin1String(kKind)).toString();
        const QString id   = o.value(QLatin1String(kId)).toString();
        if (!isValidKind(kind) || id.isEmpty()) continue;
        if (indexOf(kind, id) >= 0) continue;   // a duplicate from an older build

        QVariantMap row;
        row[QLatin1String(kKind)]     = kind;
        row[QLatin1String(kId)]       = id;
        row[QLatin1String(kTitle)]    = o.value(QLatin1String(kTitle)).toString();
        row[QLatin1String(kSubtitle)] =
            storableSubtitle(kind, o.value(QLatin1String(kSubtitle)).toString());
        row[QLatin1String(kImageUrl)] = o.value(QLatin1String(kImageUrl)).toString();
        m_items.append(row);
    }
}

void PinStore::save() const {
    // Signed out, pins live in memory only, so the next account cannot pick
    // them up.
    if (m_userId <= 0) return;

    QJsonArray arr;
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        QJsonObject o;
        o[QLatin1String(kKind)]     = m.value(QLatin1String(kKind)).toString();
        o[QLatin1String(kId)]       = m.value(QLatin1String(kId)).toString();
        o[QLatin1String(kTitle)]    = m.value(QLatin1String(kTitle)).toString();
        o[QLatin1String(kSubtitle)] = m.value(QLatin1String(kSubtitle)).toString();
        o[QLatin1String(kImageUrl)] = m.value(QLatin1String(kImageUrl)).toString();
        arr.append(o);
    }

    QSettings settings;
    settings.setValue(pinsKey(m_userId),
                      QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
}
