// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QList>
#include <QPair>
#include <QUrl>
#include "scrobble/ScrobbleService.h"

class QNetworkAccessManager;
class QNetworkReply;

// Last.fm's API as documented at https://www.last.fm/api/scrobbling, with the
// desktop sign-in of https://www.last.fm/api/desktopauth. The secret the sink
// keeps is the session key; the app's own key and shared secret are built in.
class LastFm : public ScrobbleService {
    Q_OBJECT
public:
    using Params = QList<QPair<QString, QString>>;

    // track.scrobble takes at most 50 scrobbles per call.
    static constexpr int kMaxBatch = 50;

    explicit LastFm(QObject *parent = nullptr);

    QString name() const override { return QStringLiteral("Last.fm"); }
    QString key()  const override { return QStringLiteral("lastfm"); }
    int maxBatch() const override { return kMaxBatch; }

    bool hasBrowserSignIn() const override { return true; }
    void beginSignIn(Begun done) override;
    void finishSignIn(const QString &token, Finished done) override;
    // Last.fm has no token to paste: the sign-in goes through the browser.
    void verify(const QString &secret, Verified done) override;
    void nowPlaying(const QString &secret, const Listen &listen, Done done) override;
    void submit(const QString &secret, const QList<Listen> &listens, Done done) override;

    // https://ws.audioscrobbler.com/2.0/ by default; tests point it at loopback.
    void setBaseUrl(const QUrl &url) { m_base = url; }
    // Tests sign with invented credentials, never the app's own.
    void setAppCredentials(const QString &apiKey, const QString &sharedSecret) {
        m_apiKey = apiKey; m_sharedSecret = sharedSecret;
    }

    // ── pure, for the tests ──────────────────────────────────────────────
    // The built-in key and secret look like Last.fm's: 32 hex digits each.
    static bool hasAppKey();
    // api_sig: md5 of every parameter but format and callback, name and value
    // in the order of the names, then the shared secret.
    static QString signature(const Params &params, const QString &sharedSecret);
    // The form body, every name and value percent-encoded.
    static QByteArray formBody(const Params &params);
    static Params nowPlayingParams(const Listen &listen);
    static Params scrobbleParams(const QList<Listen> &listens);
    // Where the user allows the request token.
    static QUrl authPage(const QString &apiKey, const QString &token);
    // What an answer means: Last.fm's error code if it gave one, else the
    // HTTP status.
    static ScrobbleReply classify(int httpStatus, const QByteArray &body);

private:
    // Adds api_key, sk when given, api_sig and format, then posts.
    QNetworkReply *call(const QString &method, Params params, const QString &sessionKey);

    QNetworkAccessManager *m_net = nullptr;
    QUrl    m_base;
    QString m_apiKey;
    QString m_sharedSecret;
};
