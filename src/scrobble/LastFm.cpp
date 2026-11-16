// SPDX-License-Identifier: GPL-3.0-or-later

#include "scrobble/LastFm.h"
#include "ui/UpdateCheck.h"
#include <QCryptographicHash>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrlQuery>
#include <algorithm>

namespace {
constexpr int kTimeoutMs = 20000;
// The app's own API account. Open-source desktop clients ship theirs in the
// source: the desktop sign-in has no way to keep it from the user anyway.
const QString kApiKey       = QStringLiteral("1468cc746cd9b9c1e54a2a4385a93ea7");
const QString kSharedSecret = QStringLiteral("77c84d294dc9d8e071eeca0685408964");

QString errorText(const QJsonObject &o) {
    return o.value(QStringLiteral("message")).toString().left(200);
}
} // namespace

LastFm::LastFm(QObject *parent)
    : ScrobbleService(parent)
    , m_net(new QNetworkAccessManager(this))
    , m_base(QStringLiteral("https://ws.audioscrobbler.com/2.0/"))
    , m_apiKey(kApiKey)
    , m_sharedSecret(kSharedSecret)
{}

bool LastFm::hasAppKey() {
    static const QRegularExpression hex(QStringLiteral("^[0-9a-f]{32}$"));
    return hex.match(kApiKey).hasMatch() && hex.match(kSharedSecret).hasMatch();
}

QString LastFm::signature(const Params &params, const QString &sharedSecret) {
    Params sorted;
    for (const auto &p : params)
        if (p.first != QLatin1String("format") && p.first != QLatin1String("callback")
            && p.first != QLatin1String("api_sig"))
            sorted << p;
    std::sort(sorted.begin(), sorted.end(),
              [](const auto &a, const auto &b) { return a.first < b.first; });
    QByteArray text;
    for (const auto &p : std::as_const(sorted)) text += p.first.toUtf8() + p.second.toUtf8();
    text += sharedSecret.toUtf8();
    return QString::fromLatin1(QCryptographicHash::hash(text, QCryptographicHash::Md5).toHex());
}

QByteArray LastFm::formBody(const Params &params) {
    // By hand: QUrlQuery leaves '+' as it is, which a form decoder reads as a space.
    QByteArray out;
    for (const auto &p : params) {
        if (!out.isEmpty()) out += '&';
        out += QUrl::toPercentEncoding(p.first) + '=' + QUrl::toPercentEncoding(p.second);
    }
    return out;
}

LastFm::Params LastFm::nowPlayingParams(const Listen &l) {
    Params p{{QStringLiteral("artist"), l.artist}, {QStringLiteral("track"), l.title}};
    if (!l.album.isEmpty())  p << qMakePair(QStringLiteral("album"), l.album);
    if (l.trackNumber > 0)   p << qMakePair(QStringLiteral("trackNumber"), QString::number(l.trackNumber));
    if (l.durationMs > 0)    p << qMakePair(QStringLiteral("duration"), QString::number(l.durationMs / 1000));
    return p;
}

LastFm::Params LastFm::scrobbleParams(const QList<Listen> &listens) {
    Params p;
    for (qsizetype i = 0; i < listens.size(); ++i) {
        const Listen &l = listens.at(i);
        const auto at = [i](const char *name) { return QStringLiteral("%1[%2]").arg(QLatin1String(name)).arg(i); };
        p << qMakePair(at("artist"), l.artist) << qMakePair(at("track"), l.title)
          << qMakePair(at("timestamp"), QString::number(l.listenedAt));
        if (!l.album.isEmpty())  p << qMakePair(at("album"), l.album);
        if (l.trackNumber > 0)   p << qMakePair(at("trackNumber"), QString::number(l.trackNumber));
        if (l.durationMs > 0)    p << qMakePair(at("duration"), QString::number(l.durationMs / 1000));
    }
    return p;
}

QUrl LastFm::authPage(const QString &apiKey, const QString &token) {
    QUrl url(QStringLiteral("https://www.last.fm/api/auth/"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("api_key"), apiKey);
    q.addQueryItem(QStringLiteral("token"), token);
    url.setQuery(q);
    return url;
}

ScrobbleReply LastFm::classify(int status, const QByteArray &body) {
    ScrobbleReply r;
    const QJsonObject o = QJsonDocument::fromJson(body).object();
    const int code = o.value(QStringLiteral("error")).toInt();
    if (code != 0) {
        switch (code) {
        case 9:   // invalid session key
        case 4:   // authentication failed
        case 15:  // the request token expired
            r.kind = ScrobbleReply::AuthFailed;
            break;
        case 14:  // the user has not allowed the request token yet
            r.kind = ScrobbleReply::Pending;
            break;
        case 29:  // rate limit
            r.kind = ScrobbleReply::Retry;
            r.slowDown = true;
            break;
        case 11:  // service offline
        case 16:  // temporarily unavailable
        // The app's key or signature, not the listen: dropping would empty the queue.
        case 10: case 13: case 26:
            r.kind = ScrobbleReply::Retry;
            break;
        default:
            r.kind = ScrobbleReply::Rejected;
        }
        r.detail = QStringLiteral("HTTP %1, error %2: %3").arg(status).arg(code).arg(errorText(o));
        return r;
    }
    if (status == 0) {
        r.kind = ScrobbleReply::Retry;
        r.detail = QStringLiteral("no answer");
        return r;
    }
    if (status >= 200 && status < 300) r.kind = ScrobbleReply::Ok;
    else if (status == 429) { r.kind = ScrobbleReply::Retry; r.slowDown = true; }
    else if (status >= 500 || status == 408) r.kind = ScrobbleReply::Retry;
    else r.kind = ScrobbleReply::Rejected;
    r.detail = QStringLiteral("HTTP %1").arg(status);
    return r;
}

QNetworkReply *LastFm::call(const QString &method, Params params, const QString &sessionKey) {
    params << qMakePair(QStringLiteral("method"), method)
           << qMakePair(QStringLiteral("api_key"), m_apiKey);
    if (!sessionKey.isEmpty()) params << qMakePair(QStringLiteral("sk"), sessionKey);
    params << qMakePair(QStringLiteral("api_sig"), signature(params, m_sharedSecret))
           << qMakePair(QStringLiteral("format"), QStringLiteral("json"));
    QNetworkRequest req(m_base);
    req.setRawHeader("User-Agent", UpdateCheck::userAgent());
    req.setHeader(QNetworkRequest::ContentTypeHeader, QByteArrayLiteral("application/x-www-form-urlencoded"));
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    req.setTransferTimeout(std::chrono::milliseconds(kTimeoutMs));
#else
    req.setTransferTimeout(kTimeoutMs);
#endif
    return m_net->post(req, formBody(params));
}

// The answer and its JSON, once the reply is in.
template <typename F>
static void onAnswer(QObject *ctx, QNetworkReply *reply, F handle) {
    QObject::connect(reply, &QNetworkReply::finished, ctx, [reply, handle = std::move(handle)] {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        handle(LastFm::classify(status, body), QJsonDocument::fromJson(body).object());
    });
}

void LastFm::beginSignIn(Begun done) {
    onAnswer(this, call(QStringLiteral("auth.getToken"), {}, {}),
             [done = std::move(done), key = m_apiKey](ScrobbleReply r, const QJsonObject &o) {
        const QString token = o.value(QStringLiteral("token")).toString();
        if (r.kind == ScrobbleReply::Ok && token.isEmpty()) {
            r.kind = ScrobbleReply::Retry;
            r.detail = QStringLiteral("no token in the answer");
        }
        if (r.kind != ScrobbleReply::Ok) { done(r, {}, {}); return; }
        done(r, token, authPage(key, token));
    });
}

void LastFm::finishSignIn(const QString &token, Finished done) {
    onAnswer(this, call(QStringLiteral("auth.getSession"), {{QStringLiteral("token"), token}}, {}),
             [done = std::move(done)](ScrobbleReply r, const QJsonObject &o) {
        const QJsonObject session = o.value(QStringLiteral("session")).toObject();
        const QString key  = session.value(QStringLiteral("key")).toString();
        const QString user = session.value(QStringLiteral("name")).toString();
        if (r.kind == ScrobbleReply::Ok && (key.isEmpty() || user.isEmpty())) {
            r.kind = ScrobbleReply::Retry;
            r.detail = QStringLiteral("no session in the answer");
        }
        if (r.kind != ScrobbleReply::Ok) { done(r, {}, {}); return; }
        done(r, key, user);
    });
}

void LastFm::verify(const QString &, Verified done) {
    ScrobbleReply r;
    r.kind = ScrobbleReply::Rejected;
    r.detail = QStringLiteral("Last.fm signs in through the browser");
    done(r, {});
}

void LastFm::nowPlaying(const QString &secret, const Listen &listen, Done done) {
    onAnswer(this, call(QStringLiteral("track.updateNowPlaying"), nowPlayingParams(listen), secret),
             [done = std::move(done)](const ScrobbleReply &r, const QJsonObject &) { done(r); });
}

void LastFm::submit(const QString &secret, const QList<Listen> &listens, Done done) {
    onAnswer(this, call(QStringLiteral("track.scrobble"), scrobbleParams(listens), secret),
             [done = std::move(done)](const ScrobbleReply &r, const QJsonObject &o) {
        // Ignored scrobbles (too old, a filtered artist) are answered, not
        // refused: sending them again would be ignored again.
        const QJsonObject attr = o.value(QStringLiteral("scrobbles")).toObject()
                                  .value(QStringLiteral("@attr")).toObject();
        const int ignored = attr.value(QStringLiteral("ignored")).toInt();
        if (r.kind == ScrobbleReply::Ok && ignored > 0)
            qInfo().noquote() << "Scrobbling: Last.fm ignored" << ignored << "of the listens sent";
        done(r);
    });
}
