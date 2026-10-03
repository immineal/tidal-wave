#include "PinStore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>

namespace {

// One key per account (P6). TidalBridge already namespaces its per-user state
// as user_<id>/..., so this follows the same shape.
QString pinsKey(qint64 uid) { return QStringLiteral("user_%1/pins").arg(uid); }

// The one-shot marker for the default pin. Separate from the pin list, because
// the question it answers is not "is this pinned" but "has this account been
// offered it", and those differ the moment the user unpins the thing: an empty
// list with the marker set is a user who said no.
QString seedKey(qint64 uid) { return QStringLiteral("user_%1/pinsSeeded").arg(uid); }

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
    seedDefaultPin();
}

bool PinStore::wasSeeded() const {
    // Signed out there is no account to seed, and nowhere to record that it was
    // done, so the answer that stops anything from happening is the safe one.
    if (m_userId <= 0) return true;
    return QSettings().value(seedKey(m_userId), false).toBool();
}

void PinStore::markSeeded() const {
    if (m_userId <= 0) return;
    QSettings().setValue(seedKey(m_userId), true);
}

void PinStore::seedDefaultPin() {
    if (m_userId <= 0 || wasSeeded()) return;

    // An account that already has pins has been curated, and dropping a row the
    // user never asked for into the middle of the ones they chose is worse than
    // leaving the feature unannounced - they have evidently found it. Marked
    // done rather than left open, so the network is never asked a question whose
    // answer cannot change the outcome.
    if (!m_items.isEmpty()) { markSeeded(); return; }

    if (!m_mixSource) return;

    const qint64 uid = m_userId;
    m_mixSource([this, uid](QList<Tidal::Mix> mixes, QString err) {
        // Another account signed in, or signed out, while the request was out.
        if (uid != m_userId) return;
        // A failed request is not an answer about this account. Left for the
        // next launch rather than spent.
        if (!err.isEmpty()) return;
        // Neither is an empty list: Tidal generates these mixes from listening
        // history, so a new account has none yet and will have some later.
        if (mixes.isEmpty()) return;
        // Pinning something by hand in the seconds the request was out counts
        // as finding the feature.
        if (!m_items.isEmpty()) { markSeeded(); return; }

        // Spent whether or not this account has either mix, because the list
        // came back and that is the authoritative answer. Without it, a user
        // who unpins a seeded row would be handed it again on the next launch,
        // for ever - and that holds for unpinning one of the two as much as for
        // unpinning both, which is why the marker is per account and not per
        // seeded row.
        markSeeded();

        // Daily Discovery first, then New Arrivals. The wanted types are walked
        // in that order rather than the list being walked once, because
        // `pages/my_collection_my_mixes` makes no promise about the order it
        // answers in and this is the first thing on screen.
        //
        // By mixType, never by title: every one of these titles arrives in the
        // account's own language ("Meine Neuheiten"), so a title match would
        // seed nothing at all for most users.
        //
        // An account that has one of the two and not the other gets the one it
        // has. Half a pair is still a destination worth having pinned, and it
        // still announces that the block exists - which is the whole point -
        // whereas insisting on both would leave an account that never generates
        // a Daily Discovery never told about pinning at all.
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
