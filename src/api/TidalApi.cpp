// SPDX-License-Identifier: GPL-3.0-or-later

#include "TidalApi.h"
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QTimeZone>
#include <QPointer>
#include <QRegularExpression>
#include <QTimer>
#include <chrono>

TidalApi::TidalApi(QObject *parent) : QObject(parent) {
    m_nam = new QNetworkAccessManager(this);
    m_nam->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
    // Set on the manager so it covers every request, including the ones
    // post() builds itself.
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    m_nam->setTransferTimeout(std::chrono::milliseconds(kTransferTimeoutMs));
#else
    m_nam->setTransferTimeout(kTransferTimeoutMs);
#endif
}

void TidalApi::setAccessToken(const QString &token) { m_accessToken = token; }
void TidalApi::setCountryCode(const QString &cc)    { m_countryCode = cc; }
void TidalApi::setTokenRenewer(TokenRenewer renewer) { m_renewer = std::move(renewer); }

// The origins that are sent the access token and the client token. Every
// other host, the audio CDN and the image host among them, gets neither.
bool TidalApi::takesTokens(const QUrl &url) const {
    static const QLatin1String kApiHosts[] = {
        QLatin1String("api.tidal.com"),
        QLatin1String("openapi.tidal.com"),
    };
    if (url.scheme() != QLatin1String("https") || url.port(443) != 443) return false;
    const QString host = url.host();
    for (const QLatin1String &apiHost : kApiHosts)
        if (host.compare(apiHost, Qt::CaseInsensitive) == 0) return true;
    return false;
}

QNetworkRequest TidalApi::makeRequest(const QUrl &url) const {
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 KHTML, like Gecko Chrome/131 Safari/537.36");
    if (takesTokens(url)) {
        // Qt copies the headers onto a redirected request, so one that carries
        // the tokens is only followed within its origin.
        req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::SameOriginRedirectPolicy);
        req.setRawHeader("X-Tidal-Token", "fX2JxdmntZWK0ixT");
        if (!m_accessToken.isEmpty())
            req.setRawHeader("Authorization", ("Bearer " + m_accessToken).toUtf8());
    }
    return req;
}

namespace {

// Whether the body of a 401 can be about the token. Tidal's v1 puts its own
// code on a refusal, and there a 401 covers more than the token. A refusal
// with no code is taken for it.
bool mayBeAboutTheToken(const QByteArray &body) {
    const QJsonObject o = QJsonDocument::fromJson(body).object();
    const int sub = o["subStatus"].toInt();
    // No code, an invalid session, a token that cannot be verified, an
    // expired one.
    return sub == 0 || sub == 6001 || sub == 6002 || sub == 11002 || sub == 11003
        || o["userMessage"].toString().startsWith(QLatin1String("The token has expired"));
}

} // namespace

// Qt names the URL in its error sentence. A signed media URL carries its
// signature in the query, and these sentences end up in the log.
QString TidalApi::redactedError(const QString &errorString) {
    static const QRegularExpression query(QStringLiteral("(\\w+://[^\\s?#]+)[?#]\\S*"));
    QString s = errorString;
    s.replace(query, QStringLiteral("\\1"));
    return s;
}

TidalApi::Answer TidalApi::answerOf(QNetworkReply *reply, const QByteArray &body) {
    Answer a;
    a.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    a.failed = reply->error() != QNetworkReply::NoError;
    if (a.failed) a.error = redactedError(reply->errorString());
    a.body = body;
    a.etag = QString::fromLatin1(reply->rawHeader("ETag"));
    return a;
}

// ── 429 ─────────────────────────────────────────────────────────────────────

namespace {

// Path segments that name one item, so every track shares one key.
bool namesAnItem(const QString &segment) {
    if (segment.isEmpty()) return false;
    bool digit = false;
    for (const QChar c : segment) {
        if (c.isDigit()) { digit = true; continue; }
        const bool hex = (c >= QLatin1Char('a') && c <= QLatin1Char('f'))
                      || (c >= QLatin1Char('A') && c <= QLatin1Char('F'));
        if (!hex && c != QLatin1Char('-')) return false;
    }
    return digit && (segment.size() >= 8 || segment.toLongLong() > 0);
}

} // namespace

QString TidalApi::rateLimitKey(const QUrl &url) {
    QStringList parts = url.path().split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (QString &p : parts)
        if (namesAnItem(p)) p = QStringLiteral("*");
    return url.host().toLower() + QLatin1Char('/') + parts.join(QLatin1Char('/'));
}

int TidalApi::retryAfterSecs(const QByteArray &header, const QDateTime &now) {
    const QByteArray v = header.trimmed();
    if (v.isEmpty()) return -1;
    bool ok = false;
    const int secs = v.toInt(&ok);
    if (ok) return secs < 0 ? -1 : secs;
    // The HTTP-date form, always in GMT.
    QDateTime when = QLocale::c().toDateTime(QString::fromLatin1(v),
                                             QStringLiteral("ddd, dd MMM yyyy hh:mm:ss 'GMT'"));
    if (!when.isValid()) return -1;
    when.setTimeZone(QTimeZone::utc());
    return int(qMax<qint64>(0, now.secsTo(when)));
}

int TidalApi::rateLimitedFor(const QUrl &url) const {
    const auto it = m_rateLimits.constFind(rateLimitKey(url));
    if (it == m_rateLimits.cend() || it->until.hasExpired()) return 0;
    return int(qMax<qint64>(1, (it->until.remainingTime() + 999) / 1000));
}

void TidalApi::noteAnswer(const QUrl &url, const Answer &a, const QByteArray &retryAfter) {
    const QString key = rateLimitKey(url);
    if (a.status != 429) {
        if (a.status > 0) m_rateLimits.remove(key);
        return;
    }
    RateLimit &r = m_rateLimits[key];
    ++r.strikes;
    int secs = retryAfterSecs(retryAfter, QDateTime::currentDateTimeUtc());
    // No usable header: wait, longer each time the endpoint says it again.
    if (secs < 0) secs = qMin(kRateLimitDefaultSecs << qMin(r.strikes - 1, 10), kRateLimitMaxSecs);
    secs = qBound(1, secs, kRateLimitMaxSecs);
    r.until = QDeadlineTimer(qint64(secs) * 1000);
    qWarning("TidalApi: %s answered 429, holding its requests for %d s",
             qPrintable(key), secs);
}

// A request to an endpoint that asked for a pause is not sent. It fails on
// the next turn of the event loop, as an answer would.
bool TidalApi::refuseIfRateLimited(const QUrl &url, const Finisher &done) {
    const int secs = rateLimitedFor(url);
    if (secs <= 0) return false;
    Answer a;
    a.status = 429;
    a.failed = true;
    a.error  = QStringLiteral("Tidal asked for a pause; try again in %1 s").arg(secs);
    QTimer::singleShot(0, this, [done, a] { done(a); });
    return true;
}

void TidalApi::send(const QUrl &url, Sender sender, Finisher done, bool resend) {
    if (refuseIfRateLimited(url, done)) return;
    QNetworkReply *reply = sender();
    connect(reply, &QNetworkReply::finished, this, [this, url, reply, sender, done, resend]() {
        const QByteArray body = reply->readAll();
        const Answer answer = answerOf(reply, body);
        noteAnswer(url, answer, reply->rawHeader("Retry-After"));
        const auto finish = [reply, answer, done] {
            reply->deleteLater();
            done(answer);
        };
        const QByteArray sent = reply->request().rawHeader("Authorization");
        const bool refused = !sent.isEmpty() && answer.status == 401;
        // One resend and no more. No request ends a session, whatever the
        // refusal says: the login host's answer to a refresh does that.
        if (!refused || resend || !mayBeAboutTheToken(body)) { finish(); return; }

        const QString token = QString::fromUtf8(sent.mid(qstrlen("Bearer ")));
        // The token was renewed while this request was on its way.
        if (!m_accessToken.isEmpty() && token != m_accessToken) {
            reply->deleteLater();
            send(url, sender, done, true);
            return;
        }
        if (!m_renewer) { finish(); return; }
        m_renewer(token, [self = QPointer<TidalApi>(this), url, reply, sender, done,
                          finish](bool renewed) {
            // The reply went with its manager.
            if (!self) return;
            if (!renewed) { finish(); return; }
            reply->deleteLater();
            self->send(url, sender, done, true);
        });
    });
}

TidalApi::Finisher TidalApi::writeAnswer(StatusCallback cb, bool errorKey) {
    return [cb = std::move(cb), errorKey](const Answer &a) {
        const QByteArray &data = a.body;
        QJsonParseError err;
        const auto obj = QJsonDocument::fromJson(data, &err).object();
        const int httpStatus = a.status;
        if (httpStatus >= 400 || a.failed) {
            // Tidal's v1 words a refusal in userMessage and has no "error" key.
            // A body that is no JSON reads as an empty object.
            QString said = obj["userMessage"].toString();
            if (said.isEmpty() && errorKey)
                said = obj["error_description"].toString(obj["error"].toString());
            cb(obj, said.isEmpty() ? a.error : said, httpStatus);
            return;
        }
        if (data.isEmpty()) {
            cb({}, {}, httpStatus);
            return;
        }
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString(), httpStatus);
            return;
        }
        if (errorKey && obj.contains("error"))
            cb(obj, obj["error_description"].toString(obj["error"].toString()), httpStatus);
        else
            cb(obj, {}, httpStatus);
    };
}

// For the writes whose callers have no use for the HTTP status. The body of
// a refusal goes on with the error.
static TidalApi::StatusCallback writeWithoutStatus(TidalApi::JsonCallback cb) {
    return [cb = std::move(cb)](QJsonObject obj, QString err, int) { cb(obj, err); };
}

// For the callers that have no use for the HTTP status.
static TidalApi::StatusCallback withoutStatus(TidalApi::JsonCallback cb) {
    // The body of a refusal is for the callers that ask for the status.
    return [cb = std::move(cb)](QJsonObject obj, QString err, int) {
        cb(err.isEmpty() ? obj : QJsonObject(), err);
    };
}

void TidalApi::get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kApiBase), endpoint, params, withoutStatus(std::move(cb)));
}

void TidalApi::getWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb) {
    getFrom(QString::fromLatin1(kApiBase), endpoint, params, std::move(cb));
}

void TidalApi::getV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kApiBaseV2), endpoint, params, withoutStatus(std::move(cb)));
}

void TidalApi::putV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    QUrl url(baseUrl(QString::fromLatin1(kApiBaseV2)) + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    // An empty body makes Qt send Content-Length: 0.
    send(url, [this, url] { return m_nam->put(makeRequest(url), QByteArray()); },
         writeAnswer(writeWithoutStatus(std::move(cb)), true));
}

void TidalApi::getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb) {
    getDoc(QString::fromLatin1(kApiBase), endpoint, params,
        [cb](QJsonDocument doc, QString err, int, QString) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(doc.array(), {});
        });
}

void TidalApi::getBody(const QString &endpoint, const QUrlQuery &params, RawCallback cb) {
    QUrl url(baseUrl(QString::fromLatin1(kApiBase)) + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    send(url, [this, url] { return m_nam->get(makeRequest(url)); },
         [cb](const Answer &a) {
        if (a.failed) { cb(a.body, a.error); return; }
        cb(a.body, {});
    });
}

void TidalApi::getOpenApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kOpenApiBase), endpoint, params, withoutStatus(std::move(cb)));
}

void TidalApi::getOpenApiWithStatus(const QString &endpoint, const QUrlQuery &params,
                                    StatusCallback cb) {
    getFrom(QString::fromLatin1(kOpenApiBase), endpoint, params, std::move(cb));
}

void TidalApi::getFrom(const QString &base, const QString &endpoint,
                       const QUrlQuery &params, StatusCallback cb) {
    getDoc(base, endpoint, params, [cb](QJsonDocument doc, QString err, int httpStatus, QString) {
        cb(doc.object(), err, httpStatus);
    });
}

void TidalApi::getTagged(const QString &endpoint, const QUrlQuery &params, TaggedCallback cb) {
    getDoc(QString::fromLatin1(kApiBase), endpoint, params,
        [cb](QJsonDocument doc, QString err, int, QString etag) {
            cb(err.isEmpty() ? doc.object() : QJsonObject(), err, etag);
        });
}

void TidalApi::getDoc(const QString &base, const QString &endpoint,
                      const QUrlQuery &params,
                      std::function<void(QJsonDocument, QString, int, QString)> cb) {
    QUrl url(baseUrl(base) + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    send(url, [this, url] { return m_nam->get(makeRequest(url)); },
         [cb](const Answer &a) {
        // 0 when the request ended without an answer.
        const int httpStatus = a.status;
        const QString &etag = a.etag;
        if (a.failed) {
            // The body of a refusal holds Tidal's own code for it. One that
            // is no JSON reads as an empty document.
            cb(QJsonDocument::fromJson(a.body), a.error, httpStatus, etag);
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(a.body, &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString(), httpStatus, etag);
            return;
        }
        cb(doc, {}, httpStatus, etag);
    });
}

void TidalApi::postAuth(const QString &endpoint, const QByteArray &body,
                        const QMap<QString,QString> &extraHeaders, StatusCallback cb) {
    QUrl url(baseUrl(QString::fromLatin1(kAuthBase)) + endpoint);
    // The login host's answers, with the status beside them. A body that is
    // no JSON is the network's or a proxy's and reads as an empty object.
    const Finisher done = [cb](const Answer &a) {
        QJsonParseError err;
        const QJsonObject obj = QJsonDocument::fromJson(a.body, &err).object();
        if (obj.contains("error")) {
            cb(obj, obj["error_description"].toString(obj["error"].toString()), a.status);
            return;
        }
        if (a.failed) { cb(obj, a.error, a.status); return; }
        if (err.error != QJsonParseError::NoError) { cb({}, err.errorString(), a.status); return; }
        cb(obj, {}, a.status);
    };
    if (refuseIfRateLimited(url, done)) return;

    // Auth endpoints must not receive X-Tidal-Token or Authorization headers.
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 KHTML, like Gecko Chrome/131 Safari/537.36");
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    for (auto it = extraHeaders.cbegin(); it != extraHeaders.cend(); ++it)
        req.setRawHeader(it.key().toUtf8(), it.value().toUtf8());

    auto *reply = m_nam->post(req, body);
    connect(reply, &QNetworkReply::finished, this, [this, url, reply, done]() {
        reply->deleteLater();
        const Answer a = answerOf(reply, reply->readAll());
        noteAnswer(url, a, reply->rawHeader("Retry-After"));
        done(a);
    });
}

void TidalApi::post(const QString &endpoint, const QByteArray &body,
                    const QMap<QString,QString> &extraHeaders, JsonCallback cb) {
    postAuth(endpoint, body, extraHeaders,
             [cb](QJsonObject obj, QString err, int) { cb(obj, err); });
}

void TidalApi::postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb) {
    post(endpoint, form.toString(QUrl::FullyEncoded).toUtf8(), {}, cb);
}

void TidalApi::postFormWithStatus(const QString &endpoint, const QUrlQuery &form,
                                  StatusCallback cb) {
    postAuth(endpoint, form.toString(QUrl::FullyEncoded).toUtf8(), {}, std::move(cb));
}

void TidalApi::postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb) {
    postApiFormEtag(endpoint, form, {}, std::move(cb));
}

void TidalApi::deleteApiWithStatus(const QString &endpoint, const QUrlQuery &params,
                                   StatusCallback cb) {
    sendDelete(endpoint, params, {}, std::move(cb));
}

void TidalApi::getEtag(const QString &endpoint, std::function<void(QString, QString)> cb) {
    QUrl url(baseUrl(QString::fromLatin1(kApiBase)) + endpoint);
    if (!m_countryCode.isEmpty()) {
        QUrlQuery q;
        q.addQueryItem("countryCode", m_countryCode);
        url.setQuery(q);
    }
    send(url, [this, url] { return m_nam->get(makeRequest(url)); },
         [cb](const Answer &a) {
        if (a.failed) { cb({}, a.error); return; }
        cb(a.etag, {});
    });
}

void TidalApi::deleteApiEtag(const QString &endpoint, const QUrlQuery &params, const QString &etag, JsonCallback cb) {
    sendDelete(endpoint, params, etag, writeWithoutStatus(std::move(cb)));
}

void TidalApi::deleteApiEtagWithStatus(const QString &endpoint, const QUrlQuery &params,
                                       const QString &etag, StatusCallback cb) {
    sendDelete(endpoint, params, etag, std::move(cb));
}

void TidalApi::sendDelete(const QString &endpoint, const QUrlQuery &params, const QString &etag,
                          StatusCallback cb) {
    QUrl url(baseUrl(QString::fromLatin1(kApiBase)) + endpoint);
    if (!params.isEmpty()) url.setQuery(params);
    send(url, [this, url, etag] {
        QNetworkRequest req = makeRequest(url);
        if (!etag.isEmpty())
            req.setRawHeader("If-None-Match", etag.toLatin1());
        return m_nam->deleteResource(req);
    }, writeAnswer(std::move(cb), false));
}

void TidalApi::postApiFormEtag(const QString &endpoint, const QUrlQuery &form, const QString &etag, JsonCallback cb) {
    const QUrl url(baseUrl(QString::fromLatin1(kApiBase)) + endpoint);
    const QByteArray body = form.toString(QUrl::FullyEncoded).toUtf8();
    send(url, [this, url, body, etag] {
        QNetworkRequest req = makeRequest(url);
        req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
        if (!etag.isEmpty())
            req.setRawHeader("If-None-Match", etag.toLatin1());
        return m_nam->post(req, body);
    }, writeAnswer(writeWithoutStatus(std::move(cb)), true));
}

QNetworkReply* TidalApi::getRaw(const QUrl &url, RawCallback cb) {
    QNetworkRequest req = makeRequest(url);
#if QT_VERSION < QT_VERSION_CHECK(6, 8, 0)
    // Older Qt's HTTP/2 header compression falls out of step with the audio
    // CDN after a few requests and the server drops the connection, so a
    // lossless track never arrives. HTTP/1.1 carries no such state.
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
#endif
    auto *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            cb({}, redactedError(reply->errorString()));
            return;
        }
        cb(reply->readAll(), {});
    });
    return reply;
}
