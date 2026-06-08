#pragma once
#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrlQuery>
#include <functional>

class TidalApi : public QObject {
    Q_OBJECT
public:
    using JsonCallback = std::function<void(QJsonObject, QString /*error*/)>;
    using RawCallback  = std::function<void(QByteArray, QString /*error*/)>;

    explicit TidalApi(QObject *parent = nullptr);

    void setAccessToken(const QString &token);
    void setCountryCode(const QString &cc);
    QString countryCode() const { return m_countryCode; }

    // Low-level GET/POST
    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    void post(const QString &endpoint, const QByteArray &body,
              const QMap<QString,QString> &extraHeaders, JsonCallback cb);
    void postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    // POST against the authenticated API host (api.tidal.com), unlike post()/postForm()
    // which target the OAuth host (auth.tidal.com) and deliberately omit auth headers.
    void postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    void getRaw(const QUrl &url, RawCallback cb);

    static constexpr auto kApiBase  = "https://api.tidal.com/v1/";
    static constexpr auto kAuthBase = "https://auth.tidal.com/v1/";

private:
    QNetworkAccessManager *m_nam;
    QString m_accessToken;
    QString m_countryCode;

    QNetworkRequest makeRequest(const QUrl &url);
};
