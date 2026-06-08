#include "TidalApi.h"
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>

TidalApi::TidalApi(QObject *parent) : QObject(parent) {
    m_nam = new QNetworkAccessManager(this);
    m_nam->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
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
    QUrl url(kApiBase + endpoint);
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
        cb(doc.object(), {});
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

void TidalApi::getRaw(const QUrl &url, RawCallback cb) {
    auto *reply = m_nam->get(makeRequest(url));
    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            cb({}, reply->errorString());
            return;
        }
        cb(reply->readAll(), {});
    });
}
