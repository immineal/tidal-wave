#include "PinStore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>

namespace {

// One key per account (P6). TidalBridge already namespaces its per-user state
// as user_<id>/..., so this follows the same shape.
QString pinsKey(qint64 uid) { return QStringLiteral("user_%1/pins").arg(uid); }

constexpr auto kKind     = "kind";
constexpr auto kId       = "id";
constexpr auto kTitle    = "title";
constexpr auto kSubtitle = "subtitle";
constexpr auto kImageUrl = "imageUrl";

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
    row[QLatin1String(kSubtitle)] = subtitle;
    row[QLatin1String(kImageUrl)] = imageUrl;

    const int at = indexOf(kind, id);
    if (at >= 0) {
        // Already pinned. Refresh the label and the art, which may have been
        // stale, but leave the position alone: the order is the user's.
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
    // Treating it as one would rewrite settings and repaint on every drop.
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

    // Anything unreadable counts as "no pins". Losing the pinned block is
    // annoying and recoverable; refusing to draw the sidebar is neither.
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
        row[QLatin1String(kSubtitle)] = o.value(QLatin1String(kSubtitle)).toString();
        row[QLatin1String(kImageUrl)] = o.value(QLatin1String(kImageUrl)).toString();
        m_items.append(row);
    }
}

void PinStore::save() const {
    // Signed out there is no account to hang the list on. Pinning still works
    // in memory so the sidebar behaves, but nothing is written where the next
    // account would pick it up.
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
