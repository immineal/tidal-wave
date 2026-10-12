// SPDX-License-Identifier: GPL-3.0-or-later

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
    // For endpoints whose body is a bare JSON array, such as
    // tracks/<id>/credits. QJsonDocument::object() reads those as {} with no
    // error.
    using ArrayCallback = std::function<void(QJsonArray, QString /*error*/)>;
    using RawCallback  = std::function<void(QByteArray, QString /*error*/)>;
    // For a caller that acts on the HTTP status. It is 0 when no answer came.
    // Beside an error the object is the body of the refusal, if that was JSON.
    using StatusCallback = std::function<void(QJsonObject, QString /*error*/, int /*httpStatus*/)>;

    explicit TidalApi(QObject *parent = nullptr);

    void setAccessToken(const QString &token);
    // Asked for a newer token when a request that carried `refused` got a 401
    // over it. It answers true once setAccessToken() holds one, and the
    // request is then sent once more. Requests refused together share it.
    using TokenRenewer =
        std::function<void(const QString &refused, std::function<void(bool)> done)>;
    void setTokenRenewer(TokenRenewer renewer);
    void setCountryCode(const QString &cc);
    QString countryCode() const { return m_countryCode; }

    // Virtual as a test seam only: tests answer canned JSON per query from a
    // subclass and drive the real TidalClient against it.
    virtual void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // The same GET against the v2 host. Its endpoints are cursor-paged, so
    // they are no drop-in replacements for their v1 siblings.
    void getV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // A v2 PUT with its arguments in the query string and an empty body, which
    // is what v2/favorites/mixes/add and .../remove require. A 200 is no proof
    // of success: see TidalClient::mixFavoriteAccepted().
    void putV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // The same v1 GET, for a body that is an array at the top level.
    void getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb);
    // A GET against the track-manifest host, the only one that serves a FLAC
    // manifest. The body is JSON:API: {data: {attributes: {...}}}.
    void getOpenApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // get() and getOpenApi() with the HTTP status handed on.
    void getWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb);
    void getOpenApiWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb);
    // post() and postForm() target the OAuth host and send no auth headers.
    void post(const QString &endpoint, const QByteArray &body,
              const QMap<QString,QString> &extraHeaders, JsonCallback cb);
    void postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    // POST against the authenticated API host.
    void postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    void deleteApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    void getEtag(const QString &endpoint, std::function<void(QString /*etag*/, QString /*error*/)> cb);
    void deleteApiEtag(const QString &endpoint, const QUrlQuery &params, const QString &etag, JsonCallback cb);
    void postApiFormEtag(const QString &endpoint, const QUrlQuery &form, const QString &etag, JsonCallback cb);
    QNetworkReply* getRaw(const QUrl &url, RawCallback cb);

    // The request every call above except post() sends. Public for
    // tst_request_headers.
    QNetworkRequest makeRequest(const QUrl &url) const;

    static constexpr auto kApiBase    = "https://api.tidal.com/v1/";
    static constexpr auto kApiBaseV2  = "https://api.tidal.com/v2/";
    static constexpr auto kAuthBase   = "https://auth.tidal.com/v1/";
    static constexpr auto kOpenApiBase = "https://openapi.tidal.com/v2/";

    // How long a request may go without a byte arriving. It is an idle timeout
    // and no budget for the transfer, so a whole-track download that takes
    // minutes is safe. Without it a stalled request never calls back.
    static constexpr int kTransferTimeoutMs = 15000;

protected:
    // Where a request for one of the base URLs above is sent. Virtual as a
    // test seam only: a subclass points the requests at a local server.
    virtual QString baseUrl(const QString &base) const { return base; }
    // Whether a request to `url` carries the tokens. Virtual as a test seam
    // only: a subclass names its local server.
    virtual bool takesTokens(const QUrl &url) const;

private:
    QNetworkAccessManager *m_nam;
    QString m_accessToken;
    QString m_countryCode;
    TokenRenewer m_renewer;

    // Builds one attempt with the token held at that moment and sends it.
    using Sender = std::function<QNetworkReply *()>;
    // Gets the finished reply and its body, which can be read only once.
    using Finisher = std::function<void(QNetworkReply *, const QByteArray &)>;
    // Every request that may carry the token goes through here.
    void send(Sender sender, Finisher done, bool resend = false);
    // What the writes make of an answer. A status of 400 or above is a
    // failure whose body still reaches `cb`. `errorKey` reads {"error": ...}
    // as one too.
    static Finisher writeAnswer(JsonCallback cb, bool errorKey);

    void getFrom(const QString &base, const QString &endpoint,
                 const QUrlQuery &params, StatusCallback cb);
    // What getFrom() and getArray() share. Hands back the whole document.
    void getDoc(const QString &base, const QString &endpoint,
                const QUrlQuery &params,
                std::function<void(QJsonDocument, QString /*error*/, int /*httpStatus*/)> cb);
};
