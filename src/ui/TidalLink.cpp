// SPDX-License-Identifier: GPL-3.0-or-later

#include "TidalLink.h"

#include <QRegularExpression>
#include <QStringList>
#include <QUrl>

namespace {

bool isWebHost(const QString &host) {
    return host == QLatin1String("tidal.com") || host == QLatin1String("www.tidal.com")
        || host == QLatin1String("listen.tidal.com");
}

// The checks are per kind, so a playlist UUID never passes as an album.
QString checkedId(const QString &kind, const QString &raw) {
    static const QRegularExpression number(QStringLiteral("^[1-9][0-9]{0,17}$"));
    static const QRegularExpression uuid(QStringLiteral(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"));
    static const QRegularExpression mix(QStringLiteral("^[0-9A-Za-z]{1,64}$"));

    if (kind == QLatin1String("track") || kind == QLatin1String("album")
        || kind == QLatin1String("artist"))
        return number.match(raw).hasMatch() ? raw : QString();
    if (kind == QLatin1String("playlist"))
        return uuid.match(raw).hasMatch() ? raw.toLower() : QString();
    if (kind == QLatin1String("mix"))
        return mix.match(raw).hasMatch() ? raw : QString();
    return {};
}

} // namespace

TidalLink TidalLink::parse(const QString &text) {
    const QUrl url(text.trimmed(), QUrl::StrictMode);
    if (!url.isValid())
        return {};

    QStringList parts;
    const QString scheme = url.scheme().toLower();
    if (scheme == QLatin1String("tidal")) {
        // tidal://album/1 puts the kind in the host.
        parts << url.host();
    } else if (scheme == QLatin1String("https") || scheme == QLatin1String("http")) {
        if (!isWebHost(url.host().toLower()) || !url.userInfo().isEmpty())
            return {};
    } else {
        return {};
    }
    parts << url.path().split(QLatin1Char('/'));
    parts.removeAll(QString());

    if (!parts.isEmpty() && parts.first().compare(QLatin1String("browse"), Qt::CaseInsensitive) == 0)
        parts.removeFirst();
    if (parts.size() < 2)
        return {};

    QString kind = parts.at(0).toLower();
    QString raw = parts.at(1);
    // The web player names a track inside its album: /album/<id>/track/<id>.
    if (kind == QLatin1String("album") && parts.size() >= 4
        && parts.at(2).compare(QLatin1String("track"), Qt::CaseInsensitive) == 0) {
        kind = QStringLiteral("track");
        raw = parts.at(3);
    }

    const QString id = checkedId(kind, raw);
    if (id.isEmpty())
        return {};
    return {kind, id};
}
