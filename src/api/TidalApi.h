// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QDeadlineTimer>
#include <QHash>
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
    // What getRawWithStatus() hands a caller that retries.
    struct RawAnswer {
        QByteArray body;
        QString    error;
        int        httpStatus = 0;       // 0 when no answer came
        int        retryAfterSecs = -1;  // a 429's Retry-After, -1 when none
        bool       timedOut = false;     // silent for kTransferTimeoutMs
    };
    using RawStatusCallback = std::function<void(const RawAnswer &)>;
    // For a caller that acts on the HTTP status. It is 0 when no answer came.
    // Beside an error the object is the body of the refusal, if that was JSON.
    using StatusCallback = std::function<void(QJsonObject, QString /*error*/, int /*httpStatus*/)>;
    // Beside the body, the answer's ETag, which a playlist write must send back.
    using TaggedCallback = std::function<void(QJsonObject, QString /*error*/, QString /*etag*/)>;

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
    // getV2() with the web player's client version, which v2/home/feed
    // answers 400 without. Virtual as a test seam only.
    virtual void getV2Web(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    static constexpr auto kWebClientVersion = "2025.7.16";
    // A v2 PUT with its arguments in the query string and an empty body, which
    // is what v2/favorites/mixes/add and .../remove require. A 200 is no proof
    // of success: see TidalClient::mixFavoriteAccepted().
    void putV2(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // The same v1 GET, for a body that is an array at the top level.
    void getArray(const QString &endpoint, const QUrlQuery &params, ArrayCallback cb);
    // The same v1 GET with the body left unparsed, so a caller can parse a
    // large one off the GUI thread. Virtual as a test seam only.
    virtual void getBody(const QString &endpoint, const QUrlQuery &params, RawCallback cb);
    // A GET against the track-manifest host, the only one that serves a FLAC
    // manifest. The body is JSON:API: {data: {attributes: {...}}}.
    void getOpenApi(const QString &endpoint, const QUrlQuery &params, JsonCallback cb);
    // get() and getOpenApi() with the HTTP status handed on.
    void getWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb);
    void getOpenApiWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb);
    // The v1 GET with the answer's ETag handed on.
    void getTagged(const QString &endpoint, const QUrlQuery &params, TaggedCallback cb);
    // post() and postForm() target the OAuth host and send no auth headers.
    void post(const QString &endpoint, const QByteArray &body,
              const QMap<QString,QString> &extraHeaders, JsonCallback cb);
    void postForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    // postForm() with the HTTP status, for telling a refusal from a host
    // that is busy or down.
    void postFormWithStatus(const QString &endpoint, const QUrlQuery &form, StatusCallback cb);
    // POST against the authenticated API host.
    void postApiForm(const QString &endpoint, const QUrlQuery &form, JsonCallback cb);
    // DELETE against the authenticated API host, with the HTTP status handed on.
    void deleteApiWithStatus(const QString &endpoint, const QUrlQuery &params, StatusCallback cb);
    void getEtag(const QString &endpoint, std::function<void(QString /*etag*/, QString /*error*/)> cb);
    void deleteApiEtag(const QString &endpoint, const QUrlQuery &params, const QString &etag, JsonCallback cb);
    // The same with the HTTP status, so a 412 over a stale ETag can be told apart.
    void deleteApiEtagWithStatus(const QString &endpoint, const QUrlQuery &params,
                                 const QString &etag, StatusCallback cb);
    void postApiFormEtag(const QString &endpoint, const QUrlQuery &form, const QString &etag, JsonCallback cb);
    // The same with the HTTP status, for a move refused over a stale ETag.
    void postApiFormEtagWithStatus(const QString &endpoint, const QUrlQuery &form,
                                   const QString &etag, StatusCallback cb);
    QNetworkReply* getRaw(const QUrl &url, RawCallback cb);
    QNetworkReply* getRawWithStatus(const QUrl &url, RawStatusCallback cb);

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

    // ── 429 ─────────────────────────────────────────────────────────────
    // An endpoint that answered 429 gets no request until its Retry-After
    // has passed; those asked for meanwhile fail at once and nothing retries.
    // Without the header the wait starts here and doubles per 429 in a row.
    static constexpr int kRateLimitDefaultSecs = 30;
    static constexpr int kRateLimitMaxSecs     = 3600;
    // Host and path, with the segments that name one item read as "*".
    static QString rateLimitKey(const QUrl &url);
    // Seconds, from either form of the header; -1 when it says nothing usable.
    static int retryAfterSecs(const QByteArray &header, const QDateTime &now);
    // How long requests to `url` are held, 0 when they are not.
    int rateLimitedFor(const QUrl &url) const;
    // The same for an endpoint of one of the base URLs above.
    int rateLimitedFor(const char *base, const QString &endpoint) const;

    // Qt's error sentence with the query cut off every URL in it.
    static QString redactedError(const QString &errorString);

    // False from a request that got no answer at all until the next one that
    // got any. Updated before that request's callback runs.
    bool reachable() const { return m_reachable; }
    // Public as a test seam; every request reports here itself.
    void noteReachable(bool reachable);

signals:
    void reachableChanged(bool reachable);

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
    bool m_reachable = true;

    // What a finished request said, read off its reply once.
    struct Answer {
        int        status = 0;      // 0 when no answer came
        bool       failed = false;  // an error status, or no answer at all
        QString    error;           // Qt's sentence, redacted
        QByteArray body;
        QString    etag;
    };
    static Answer answerOf(QNetworkReply *reply, const QByteArray &body);

    // Builds one attempt with the token held at that moment and sends it.
    using Sender = std::function<QNetworkReply *()>;
    using Finisher = std::function<void(const Answer &)>;
    // Every request that may carry the token goes through here. `url` is
    // what the sender requests, for the 429 hold.
    void send(const QUrl &url, Sender sender, Finisher done, bool resend = false);
    void postAuth(const QString &endpoint, const QByteArray &body,
                  const QMap<QString,QString> &extraHeaders, StatusCallback cb);

    struct RateLimit { QDeadlineTimer until; int strikes = 0; };
    QHash<QString, RateLimit> m_rateLimits;
    void noteAnswer(const QUrl &url, const Answer &a, const QByteArray &retryAfter);
    bool refuseIfRateLimited(const QUrl &url, const Finisher &done);
    // What the writes make of an answer. A status of 400 or above is a
    // failure whose body still reaches `cb`. `errorKey` reads {"error": ...}
    // as one too.
    static Finisher writeAnswer(StatusCallback cb, bool errorKey);
    // What the three deletes share. An empty `etag` sends no If-None-Match.
    void sendDelete(const QString &endpoint, const QUrlQuery &params, const QString &etag,
                    StatusCallback cb);

    void getFrom(const QString &base, const QString &endpoint,
                 const QUrlQuery &params, StatusCallback cb);
    // What getFrom() and getArray() share. Hands back the whole document.
    void getDoc(const QString &base, const QString &endpoint,
                const QUrlQuery &params,
                std::function<void(QJsonDocument, QString /*error*/, int /*httpStatus*/,
                                   QString /*etag*/)> cb);
};
