#pragma once
#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrlQuery>
#include <functional>

class TidalApi : public QObject {
    Q_OBJECT
public:
    using JsonCallback = std::function<void(QJsonObject, QString /*error*/)>;
    // For the endpoints whose whole body is a bare JSON array rather than an
    // object with an "items" key. tracks/<id>/credits is one: it answers
    // [{type, contributors:[…]}, …] at the top level, so QJsonDocument::object()
    // reads it as {} and every field comes back empty with no error to show for
    // it.
    using ArrayCallback = std::function<void(QJsonArray, QString /*error*/)>;
    using RawCallback  = std::function<void(QByteArray, QString /*error*/)>;

    explicit TidalApi(QObject *parent = nullptr);

    void setAccessToken(const QString &token);
    void setCountryCode(const QString &cc);
    QString countryCode() const { return m_countryCode; }

    // Low-level GET/POST
    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // The same GET against the v2 host. A handful of endpoints only exist there -
    // favorites/mixes is one - and they are cursor-paged rather than
    // offset-paged, so they are not drop-in replacements for their v1 siblings.
    void getV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // The same v1 GET, for a body that is an array at the top level.
    void getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb);
    // A GET against the track-manifest host, which is neither api.tidal.com nor
    // the same API version as anything else here, and is the only place that
    // will still hand this client a FLAC manifest. The body is JSON:API -
    // {data: {attributes: {...}}} - rather than the flat objects every other
    // endpoint answers with. Takes the same auth headers, and tolerates the
    // countryCode this adds to every request (checked against the live host:
    // identical response with it and without).
    void getOpenApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    void post(const QString &endpoint, const QByteArray &body,
              const QMap<QString,QString> &extraHeaders, JsonCallback cb);
    void postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    // POST against the authenticated API host (api.tidal.com), unlike post()/postForm()
    // which target the OAuth host (auth.tidal.com) and deliberately omit auth headers.
    void postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    void deleteApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    void getEtag(const QString &endpoint, std::function<void(QString /*etag*/, QString /*error*/)> cb);
    void deleteApiEtag(const QString &endpoint, const QUrlQuery &params, const QString &etag, JsonCallback cb);
    void postApiFormEtag(const QString &endpoint, const QUrlQuery &form, const QString &etag, JsonCallback cb);
    QNetworkReply* getRaw(const QUrl &url, RawCallback cb);

    static constexpr auto kApiBase    = "https://api.tidal.com/v1/";
    static constexpr auto kApiBaseV2  = "https://api.tidal.com/v2/";
    static constexpr auto kAuthBase   = "https://auth.tidal.com/v1/";
    static constexpr auto kOpenApiBase = "https://openapi.tidal.com/v2/";

private:
    QNetworkAccessManager *m_nam;
    QString m_accessToken;
    QString m_countryCode;

    QNetworkRequest makeRequest(const QUrl &url);
    void getFrom(const QString &base, const QString &endpoint,
                 const QUrlQuery &params, JsonCallback cb);
    // What getFrom() and getArray() share: the URL, the country code, the
    // request and the parse, handing back the whole document so the caller can
    // decide whether it wanted an object or an array out of it.
    void getDoc(const QString &base, const QString &endpoint,
                const QUrlQuery &params,
                std::function<void(QJsonDocument, QString /*error*/)> cb);
};
