// SPDX-License-Identifier: GPL-3.0-or-later

#include "scrobble/ListenBrainz.h"
#include "ui/UpdateCheck.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>

namespace {
constexpr int kTimeoutMs = 20000;
const QString kPlayer = QStringLiteral("Tidal Wave");
} // namespace

ListenBrainz::ListenBrainz(QObject *parent)
    : ScrobbleService(parent)
    , m_net(new QNetworkAccessManager(this))
    , m_base(QStringLiteral("https://api.listenbrainz.org"))
{}

QString ListenBrainz::trackUrl(qint64 trackId) {
    return QStringLiteral("https://tidal.com/track/%1").arg(trackId);
}

QJsonObject ListenBrainz::listenJson(const Listen &l, bool withTimestamp) {
    // Keys with nothing to say are left out, as the docs ask.
    QJsonObject info;
    if (l.durationMs > 0)    info[QStringLiteral("duration_ms")] = l.durationMs;
    // A string in the documented table of fields.
    if (l.trackNumber > 0)   info[QStringLiteral("tracknumber")] = QString::number(l.trackNumber);
    if (!l.isrc.isEmpty())   info[QStringLiteral("isrc")] = l.isrc;
    info[QStringLiteral("media_player")]              = kPlayer;
    info[QStringLiteral("media_player_version")]      = QStringLiteral(TIDALWAVE_VERSION);
    info[QStringLiteral("submission_client")]         = kPlayer;
    info[QStringLiteral("submission_client_version")] = QStringLiteral(TIDALWAVE_VERSION);
    info[QStringLiteral("music_service")]             = QStringLiteral("tidal.com");
    if (l.trackId > 0)       info[QStringLiteral("origin_url")] = trackUrl(l.trackId);

    QJsonObject meta;
    meta[QStringLiteral("artist_name")] = l.artist;
    meta[QStringLiteral("track_name")]  = l.title;
    if (!l.album.isEmpty()) meta[QStringLiteral("release_name")] = l.album;
    meta[QStringLiteral("additional_info")] = info;

    QJsonObject o;
    if (withTimestamp) o[QStringLiteral("listened_at")] = l.listenedAt;
    o[QStringLiteral("track_metadata")] = meta;
    return o;
}

QByteArray ListenBrainz::payload(const QString &listenType, const QList<Listen> &listens) {
    const bool stamped = listenType != QLatin1String("playing_now");
    QJsonArray items;
    for (const Listen &l : listens) items.append(listenJson(l, stamped));
    QJsonObject doc;
    doc[QStringLiteral("listen_type")] = listenType;
    doc[QStringLiteral("payload")]     = items;
    return QJsonDocument(doc).toJson(QJsonDocument::Compact);
}

ScrobbleReply ListenBrainz::classify(int status, const QByteArray &remaining,
                                     const QByteArray &resetIn, const QByteArray &body) {
    ScrobbleReply r;
    bool ok = false;
    const int reset = resetIn.trimmed().toInt(&ok);
    const int wait  = ok && reset > 0 ? reset : 0;
    const QString said = QJsonDocument::fromJson(body).object().value(QStringLiteral("error")).toString();
    if (status == 0) {
        r.kind = ScrobbleReply::Retry;
        r.detail = QStringLiteral("no answer");
    } else if (status >= 200 && status < 300) {
        r.kind = ScrobbleReply::Ok;
        // The window's last request was used up: the next one waits for it.
        if (remaining.trimmed() == "0") r.waitSec = wait;
    } else if (status == 401) {
        r.kind = ScrobbleReply::AuthFailed;
    } else if (status == 429) {
        r.kind = ScrobbleReply::Retry;
        r.waitSec = wait > 0 ? wait : kDefaultWaitSec;
    } else if (status >= 500 || status == 408) {
        r.kind = ScrobbleReply::Retry;
    } else {
        r.kind = ScrobbleReply::Rejected;
    }
    if (status != 0) {
        r.detail = QStringLiteral("HTTP %1").arg(status);
        if (!said.isEmpty()) r.detail += QStringLiteral(": ") + said.left(200);
    }
    return r;
}

static QNetworkRequest requestFor(const QUrl &url, const QString &secret) {
    QNetworkRequest req(url);
    req.setRawHeader("Authorization", "Token " + secret.toUtf8());
    req.setRawHeader("User-Agent", UpdateCheck::userAgent());
    req.setHeader(QNetworkRequest::ContentTypeHeader, QByteArrayLiteral("application/json"));
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    req.setTransferTimeout(std::chrono::milliseconds(kTimeoutMs));
#else
    req.setTransferTimeout(kTimeoutMs);
#endif
    return req;
}

static QUrl endpoint(QUrl base, const QString &path) {
    QString p = base.path();
    if (p.endsWith(QLatin1Char('/'))) p.chop(1);
    base.setPath(p + path);
    return base;
}

QNetworkReply *ListenBrainz::post(const QString &path, const QString &secret, const QByteArray &body) {
    return m_net->post(requestFor(endpoint(m_base, path), secret), body);
}

void ListenBrainz::finish(QNetworkReply *reply, Done done) {
    connect(reply, &QNetworkReply::finished, this, [reply, done = std::move(done)] {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        done(classify(status, reply->rawHeader("X-RateLimit-Remaining"),
                      reply->rawHeader("X-RateLimit-Reset-In"), reply->readAll()));
    });
}

void ListenBrainz::verify(const QString &secret, Verified done) {
    QNetworkReply *reply = m_net->get(requestFor(endpoint(m_base, QStringLiteral("/1/validate-token")), secret));
    connect(reply, &QNetworkReply::finished, this, [reply, done = std::move(done)] {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        ScrobbleReply r = classify(status, reply->rawHeader("X-RateLimit-Remaining"),
                                   reply->rawHeader("X-RateLimit-Reset-In"), body);
        QString user;
        if (r.kind == ScrobbleReply::Ok) {
            // 200 also for a token it does not know, with "valid": false.
            const QJsonObject o = QJsonDocument::fromJson(body).object();
            user = o.value(QStringLiteral("user_name")).toString();
            if (!o.value(QStringLiteral("valid")).toBool() || user.isEmpty()) {
                r.kind = ScrobbleReply::AuthFailed;
                r.detail = QStringLiteral("token not valid");
                user.clear();
            }
        } else if (r.kind == ScrobbleReply::Rejected) {
            r.kind = ScrobbleReply::AuthFailed;
        }
        done(r, user);
    });
}

void ListenBrainz::nowPlaying(const QString &secret, const Listen &listen, Done done) {
    finish(post(QStringLiteral("/1/submit-listens"), secret,
                payload(QStringLiteral("playing_now"), {listen})), std::move(done));
}

void ListenBrainz::submit(const QString &secret, const QList<Listen> &listens, Done done) {
    const QString type = listens.size() == 1 ? QStringLiteral("single") : QStringLiteral("import");
    finish(post(QStringLiteral("/1/submit-listens"), secret, payload(type, listens)), std::move(done));
}
