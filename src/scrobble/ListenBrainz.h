// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QJsonObject>
#include <QUrl>
#include "scrobble/ScrobbleService.h"

class QNetworkAccessManager;
class QNetworkReply;

// ListenBrainz's API, as documented at
// https://listenbrainz.readthedocs.io/en/latest/users/api/core.html
// and the payload at .../users/json.html.
class ListenBrainz : public ScrobbleService {
    Q_OBJECT
public:
    // The documented MAX_LISTENS_PER_REQUEST is 1000; a smaller batch keeps
    // each request well under MAX_LISTEN_PAYLOAD_SIZE and quick to retry.
    static constexpr int kMaxBatch = 100;
    // Waited after a 429 that names no reset time.
    static constexpr int kDefaultWaitSec = 10;

    explicit ListenBrainz(QObject *parent = nullptr);

    QString name() const override { return QStringLiteral("ListenBrainz"); }
    QString key()  const override { return QStringLiteral("listenbrainz"); }
    int maxBatch() const override { return kMaxBatch; }

    void verify(const QString &secret, Verified done) override;
    void nowPlaying(const QString &secret, const Listen &listen, Done done) override;
    void submit(const QString &secret, const QList<Listen> &listens, Done done) override;

    // https://api.listenbrainz.org by default; tests point it at loopback.
    void setBaseUrl(const QUrl &url) { m_base = url; }

    // ── pure, for the tests ──────────────────────────────────────────────
    // One payload entry. listened_at is left out for "playing now".
    static QJsonObject listenJson(const Listen &listen, bool withTimestamp);
    // "single" for one listen, "import" for a batch, or "playing_now".
    static QByteArray payload(const QString &listenType, const QList<Listen> &listens);
    // The track's page, as Copy link gives it.
    static QString trackUrl(qint64 trackId);
    // What a reply's status and rate-limit headers mean for the next request.
    static ScrobbleReply classify(int httpStatus, const QByteArray &remaining,
                                  const QByteArray &resetIn, const QByteArray &body);

private:
    QNetworkReply *post(const QString &path, const QString &secret, const QByteArray &body);
    void finish(QNetworkReply *reply, Done done);

    QNetworkAccessManager *m_net = nullptr;
    QUrl m_base;
};
