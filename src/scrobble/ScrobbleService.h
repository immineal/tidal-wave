// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QList>
#include <QObject>
#include <QString>
#include <QUrl>
#include <functional>
#include "scrobble/Listen.h"

// What a service said to one request, in the terms ScrobbleSink acts on.
struct ScrobbleReply {
    enum Kind {
        Ok,
        Retry,       // offline, 5xx, 429: the same request later
        AuthFailed,  // the secret is no longer accepted: stop sending
        Rejected,    // the request itself is refused: never send it again
        Pending,     // a browser sign-in the user has not allowed yet
    };
    Kind kind = Ok;
    // A Retry because the service asked for fewer requests.
    bool slowDown = false;
    // Seconds the service asks to wait before the next request, from its
    // rate-limit headers. 0 when it said nothing.
    int waitSec = 0;
    // For the log. Never holds the secret.
    QString detail;
};

// One scrobbling service. ScrobbleSink owns the queue, the account and the
// retries; an implementation only speaks the service's protocol. The secret is
// the service's per-user credential: a ListenBrainz user token, a Last.fm
// session key.
class ScrobbleService : public QObject {
    Q_OBJECT
public:
    using Done = std::function<void(const ScrobbleReply &)>;
    using Verified = std::function<void(const ScrobbleReply &, const QString &userName)>;
    using Begun    = std::function<void(const ScrobbleReply &, const QString &token, const QUrl &page)>;
    using Finished = std::function<void(const ScrobbleReply &, const QString &secret, const QString &userName)>;

    using QObject::QObject;

    // Shown to the user, e.g. "ListenBrainz".
    virtual QString name() const = 0;
    // Names the queue file and the settings group, e.g. "listenbrainz".
    virtual QString key() const = 0;
    // The most listens one submit may carry.
    virtual int maxBatch() const = 0;

    // Asks the service whose secret this is.
    virtual void verify(const QString &secret, Verified done) = 0;

    // A service whose secret comes from a sign-in in the browser (Last.fm):
    // beginSignIn gets a request token and the page that allows it, and
    // finishSignIn trades the allowed token for the secret.
    virtual bool hasBrowserSignIn() const { return false; }
    virtual void beginSignIn(Begun done) {
        ScrobbleReply r; r.kind = ScrobbleReply::Rejected; done(r, {}, {});
    }
    virtual void finishSignIn(const QString &token, Finished done) {
        Q_UNUSED(token); ScrobbleReply r; r.kind = ScrobbleReply::Rejected; done(r, {}, {});
    }
    // Optional for the service and never retried.
    virtual void nowPlaying(const QString &secret, const Listen &listen, Done done) = 0;
    // Listens in the order they were played, at most maxBatch().
    virtual void submit(const QString &secret, const QList<Listen> &listens, Done done) = 0;
};
