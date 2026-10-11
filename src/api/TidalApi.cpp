// SPDX-License-Identifier: GPL-3.0-or-later

#include "TidalApi.h"
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
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

// The origins that are sent the access token and the client token. Every
// other host, the audio CDN and the image host among them, gets neither.
static bool takesTokens(const QUrl &url) {
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

// For the callers that have no use for the HTTP status.
static TidalApi::StatusCallback withoutStatus(TidalApi::JsonCallback cb) {
    return [cb = std::move(cb)](QJsonObject obj, QString err, int) { cb(obj, err); };
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
    QUrl url(kApiBaseV2 + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    QNetworkRequest req = makeRequest(url);
    // An empty body makes Qt send Content-Length: 0.
    auto *reply = m_nam->put(req, QByteArray());
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        const QByteArray data = reply->readAll();
        if (data.isEmpty()) {
            cb({}, reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
            return;
        }
        QJsonParseError err;
        const auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString());
            return;
        }
        const auto obj = doc.object();
        if (obj.contains("error"))
            cb(obj, obj["error_description"].toString(obj["error"].toString()));
        else
            cb(obj, {});
    });
}

void TidalApi::getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb) {
    getDoc(QString::fromLatin1(kApiBase), endpoint, params,
        [cb](QJsonDocument doc, QString err, int) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(doc.array(), {});
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
    getDoc(base, endpoint, params, [cb](QJsonDocument doc, QString err, int httpStatus) {
        if (!err.isEmpty()) { cb({}, err, httpStatus); return; }
        cb(doc.object(), {}, httpStatus);
    });
}

void TidalApi::getDoc(const QString &base, const QString &endpoint,
                      const QUrlQuery &params,
                      std::function<void(QJsonDocument, QString, int)> cb) {
    QUrl url(baseUrl(base) + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    auto *reply = m_nam->get(makeRequest(url));
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        // Invalid, and so 0, when the request ended without an answer.
        const int httpStatus =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError) {
            cb({}, reply->errorString(), httpStatus);
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(reply->readAll(), &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString(), httpStatus);
            return;
        }
        cb(doc, {}, httpStatus);
    });
}

void TidalApi::post(const QString &endpoint, const QByteArray &body,
                    const QMap<QString,QString> &extraHeaders, JsonCallback cb) {
    QUrl url(kAuthBase + endpoint);
    // Auth endpoints must not receive X-Tidal-Token or Authorization headers.
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 KHTML, like Gecko Chrome/131 Safari/537.36");
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    for (auto it = extraHeaders.cbegin(); it != extraHeaders.cend(); ++it)
        req.setRawHeader(it.key().toUtf8(), it.value().toUtf8());

    auto *reply = m_nam->post(req, body);
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString());
            return;
        }
        auto obj = doc.object();
        if (obj.contains("error"))
            cb(obj, obj["error_description"].toString(obj["error"].toString()));
        else
            cb(obj, {});
    });
}

void TidalApi::postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb) {
    post(endpoint, form.toString(QUrl::FullyEncoded).toUtf8(), {}, cb);
}

void TidalApi::postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb) {
    QUrl url(kApiBase + endpoint);
    QNetworkRequest req = makeRequest(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");

    auto *reply = m_nam->post(req, form.toString(QUrl::FullyEncoded).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        if (data.isEmpty()) {
            cb({}, reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString());
            return;
        }
        auto obj = doc.object();
        if (obj.contains("error"))
            cb(obj, obj["error_description"].toString(obj["error"].toString()));
        else
            cb(obj, {});
    });
}

void TidalApi::deleteApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    QUrl url(kApiBase + endpoint);
    if (!params.isEmpty()) {
        url.setQuery(params);
    }
    QNetworkRequest req = makeRequest(url);
    auto *reply = m_nam->deleteResource(req);
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        if (data.isEmpty()) {
            cb({}, reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString());
            return;
        }
        cb(doc.object(), {});
    });
}

void TidalApi::getEtag(const QString &endpoint, std::function<void(QString, QString)> cb) {
    QUrl url(kApiBase + endpoint);
    if (!m_countryCode.isEmpty()) {
        QUrlQuery q;
        q.addQueryItem("countryCode", m_countryCode);
        url.setQuery(q);
    }
    auto *reply = m_nam->get(makeRequest(url));
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            cb({}, reply->errorString());
            return;
        }
        QString etag = QString::fromLatin1(reply->rawHeader("ETag"));
        cb(etag, {});
    });
}

void TidalApi::deleteApiEtag(const QString &endpoint, const QUrlQuery &params, const QString &etag, JsonCallback cb) {
    QUrl url(kApiBase + endpoint);
    if (!params.isEmpty()) url.setQuery(params);
    QNetworkRequest req = makeRequest(url);
    if (!etag.isEmpty())
        req.setRawHeader("If-None-Match", etag.toLatin1());
    auto *reply = m_nam->deleteResource(req);
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        if (data.isEmpty()) {
            cb({}, reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) { cb({}, err.errorString()); return; }
        cb(doc.object(), {});
    });
}

void TidalApi::postApiFormEtag(const QString &endpoint, const QUrlQuery &form, const QString &etag, JsonCallback cb) {
    QUrl url(kApiBase + endpoint);
    QNetworkRequest req = makeRequest(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    if (!etag.isEmpty())
        req.setRawHeader("If-None-Match", etag.toLatin1());
    auto *reply = m_nam->post(req, form.toString(QUrl::FullyEncoded).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        if (data.isEmpty()) {
            cb({}, reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(data, &err);
        if (err.error != QJsonParseError::NoError) { cb({}, err.errorString()); return; }
        auto obj = doc.object();
        if (obj.contains("error"))
            cb(obj, obj["error_description"].toString(obj["error"].toString()));
        else
            cb(obj, {});
    });
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
            cb({}, reply->errorString());
            return;
        }
        cb(reply->readAll(), {});
    });
    return reply;
}
