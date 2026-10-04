#include "TidalApi.h"
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <chrono>

TidalApi::TidalApi(QObject *parent) : QObject(parent) {
    m_nam = new QNetworkAccessManager(this);
    m_nam->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
    // On the manager rather than on each request, so there is no second place
    // to forget: it reaches makeRequest()'s GETs, postApiForm()'s POSTs and the
    // OAuth host requests in post(), which builds a QNetworkRequest of its own.
    // Measured, not assumed - a manager-level timeout does apply to a request
    // that sets none of its own, GET and POST alike. See kTransferTimeoutMs for
    // why the number is what it is, and why an idle timeout is the instrument.
    //
    // Note what this does not cover: QMediaPlayer streams through the FFmpeg
    // backend, which does its own HTTP. On this app's path that no longer
    // matters, because DashFetcher fetches every byte through here and hands
    // the backend a local file.
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    m_nam->setTransferTimeout(std::chrono::milliseconds(kTransferTimeoutMs));
#else
    m_nam->setTransferTimeout(kTransferTimeoutMs);
#endif
}

void TidalApi::setAccessToken(const QString &token) { m_accessToken = token; }
void TidalApi::setCountryCode(const QString &cc)    { m_countryCode = cc; }

QNetworkRequest TidalApi::makeRequest(const QUrl &url) {
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 KHTML, like Gecko Chrome/131 Safari/537.36");
    req.setRawHeader("X-Tidal-Token", "fX2JxdmntZWK0ixT");
    if (!m_accessToken.isEmpty())
        req.setRawHeader("Authorization", ("Bearer " + m_accessToken).toUtf8());
    return req;
}

void TidalApi::get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kApiBase), endpoint, params, std::move(cb));
}

void TidalApi::getV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kApiBaseV2), endpoint, params, std::move(cb));
}

void TidalApi::getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb) {
    getDoc(QString::fromLatin1(kApiBase), endpoint, params,
        [cb](QJsonDocument doc, QString err) {
            if (!err.isEmpty()) { cb({}, err); return; }
            cb(doc.array(), {});
        });
}

void TidalApi::getOpenApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) {
    getFrom(QString::fromLatin1(kOpenApiBase), endpoint, params, std::move(cb));
}

void TidalApi::getFrom(const QString &base, const QString &endpoint,
                       const QUrlQuery &params, JsonCallback cb) {
    getDoc(base, endpoint, params, [cb](QJsonDocument doc, QString err) {
        if (!err.isEmpty()) { cb({}, err); return; }
        cb(doc.object(), {});
    });
}

void TidalApi::getDoc(const QString &base, const QString &endpoint,
                      const QUrlQuery &params,
                      std::function<void(QJsonDocument, QString)> cb) {
    QUrl url(base + endpoint);
    QUrlQuery q = params;
    if (!m_countryCode.isEmpty()) q.addQueryItem("countryCode", m_countryCode);
    url.setQuery(q);

    auto *reply = m_nam->get(makeRequest(url));
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            cb({}, reply->errorString());
            return;
        }
        QJsonParseError err;
        auto doc = QJsonDocument::fromJson(reply->readAll(), &err);
        if (err.error != QJsonParseError::NoError) {
            cb({}, err.errorString());
            return;
        }
        cb(doc, {});
    });
}

void TidalApi::post(const QString &endpoint, const QByteArray &body,
                    const QMap<QString,QString> &extraHeaders, JsonCallback cb) {
    QUrl url(kAuthBase + endpoint);
    // Auth endpoints must NOT receive X-Tidal-Token or Authorization headers
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
    auto *reply = m_nam->get(makeRequest(url));
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
