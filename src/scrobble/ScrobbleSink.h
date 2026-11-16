// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QElapsedTimer>
#include <QList>
#include <QObject>
#include <QString>
#include <QUrl>
#include <optional>
#include "scrobble/Listen.h"
#include "scrobble/ScrobbleService.h"

class QTimer;

// One scrobbling account: its secret, the listens that wait for it, and the
// pace and retries of sending them. The service it is built with speaks the
// protocol; everything here is the same for every service. Settings binds
// to these properties.
class ScrobbleSink : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString serviceName READ serviceName CONSTANT)
    // Off by default. Off, nothing is recorded or sent.
    Q_PROPERTY(bool    enabled     READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool    connected   READ connected   NOTIFY accountChanged)
    Q_PROPERTY(QString userName    READ userName    NOTIFY accountChanged)
    // A secret is being checked with the service.
    Q_PROPERTY(bool    checking    READ checking    NOTIFY checkingChanged)
    Q_PROPERTY(int     queuedCount READ queuedCount NOTIFY queueChanged)
    // The service turned the secret down: nothing goes out until a new one.
    Q_PROPERTY(bool    authFailed  READ authFailed  NOTIFY statusChanged)
    // The last thing that went wrong, as a sentence; empty once a send works.
    Q_PROPERTY(QString lastError   READ lastError   NOTIFY statusChanged)
    // The status line: what waits, and the last error.
    Q_PROPERTY(QString statusText  READ statusText  NOTIFY statusChanged)
    // Listens kept for an account that is not connected now.
    Q_PROPERTY(int     keptCount   READ keptCount   NOTIFY statusChanged)
    // Signed in through the browser rather than with a pasted token.
    Q_PROPERTY(bool    browserSignIn   READ browserSignIn   CONSTANT)
    // The browser is open at the page that allows access; finish or cancel.
    Q_PROPERTY(bool    awaitingBrowser READ awaitingBrowser NOTIFY signInChanged)
    Q_PROPERTY(QString signInPage      READ signInPage      NOTIFY signInChanged)

public:
    struct Paths {
        QString secret;  // the account, owner-only, beside the Tidal credentials
        QString queue;   // the listens not sent yet
    };
    static Paths defaultPaths(const QString &key);

    // The most listens kept; past it the oldest go.
    static constexpr int kMaxQueued = 10000;
    // The docs ask for at most one call per second.
    static constexpr int kSpacingMs = 1000;
    // The first wait after a failure; it doubles up to kMaxRetryMs.
    static constexpr int kRetryMs    = 30000;
    static constexpr int kMaxRetryMs = 30 * 60 * 1000;

    // Takes ownership of `service`.
    ScrobbleSink(ScrobbleService *service, const Paths &paths, QObject *parent = nullptr);

    QString serviceName() const { return m_service->name(); }
    bool    enabled()     const { return m_enabled; }
    void    setEnabled(bool on);
    bool    connected()   const { return !m_secret.isEmpty(); }
    QString userName()    const { return m_user; }
    bool    checking()    const { return m_checking; }
    int     queuedCount() const { return int(m_queue.size()); }
    bool    authFailed()  const { return m_authFailed; }
    QString lastError()   const { return m_lastError; }
    QString statusText()  const;
    int     keptCount()   const { return connected() ? 0 : int(m_queue.size()); }
    bool    browserSignIn()   const { return m_service->hasBrowserSignIn(); }
    bool    awaitingBrowser() const { return !m_requestToken.isEmpty(); }
    QString signInPage()      const { return m_signInPage.toString(); }

    // Checks the secret with the service and keeps it if it is accepted.
    Q_INVOKABLE void signIn(const QString &secret);
    // Forgets the secret. The listens that wait stay for the same account to
    // connect again; another account's sign-in drops them.
    Q_INVOKABLE void disconnectAccount();
    // Drops the kept listens, so no account will send them.
    Q_INVOKABLE void discardKept();

    // The browser sign-in: a request token and openPage(), then, once the
    // user has allowed it there, the session. Cancel drops the token.
    Q_INVOKABLE void startBrowserSignIn();
    Q_INVOKABLE void finishBrowserSignIn();
    Q_INVOKABLE void cancelBrowserSignIn();

    // From PlayTracker. Both do nothing while off or without an account.
    void add(const Listen &listen);
    void nowPlaying(const Listen &listen);

    QList<Listen> queued() const { return m_queue; }
    // Shorter waits, so a test need not sit through the real ones.
    void setTimingForTest(int spacingMs, int retryMs) { m_spacingMs = spacingMs; m_retryMs = retryMs; }

signals:
    void enabledChanged();
    void accountChanged();
    void checkingChanged();
    void queueChanged();
    void statusChanged();
    void signInChanged();
    // Asks for the page to be opened in the browser.
    void openPage(const QUrl &url);

private:
    void load();
    void saveQueue();
    bool saveSecret();
    void setError(const QString &text, bool stays = false);
    void setAuthFailed(bool failed);
    void setChecking(bool on);
    // A secret the service took: kept, and sending starts.
    void accept(const QString &secret, const QString &user);
    // Forgets the secret and any sign-in under way; the queue stays.
    void dropAccount();
    // The service turned the secret down while sending.
    void refused();
    void endBrowserStep();
    // Sends what is due, or sets the timer for when it is.
    void pump();
    void holdFor(qint64 ms);
    void sendBatch();
    void batchDone(const QList<Listen> &batch, int generation, const ScrobbleReply &reply);
    // Takes these out of the queue wherever they are; false if none was there.
    bool removeSent(const QList<Listen> &sent);
    QString retryText(const ScrobbleReply &reply) const;

    ScrobbleService *m_service;
    Paths   m_paths;
    bool    m_enabled = false;
    QString m_secret;
    QString m_user;
    bool    m_checking   = false;
    bool    m_authFailed = false;
    QString m_lastError;
    // The error tells of a listen that was dropped: a send that works later
    // does not take it back.
    bool    m_errorStays = false;
    QList<Listen> m_queue;
    // The account the queue belongs to, kept with it across a disconnect.
    QString m_queueUser;
    std::optional<Listen> m_pendingNow;
    QString m_requestToken;
    QUrl    m_signInPage;

    QTimer *m_timer = nullptr;
    bool    m_busy = false;
    // Raised by every change of account, so a late answer for the old one
    // changes nothing.
    int     m_generation = 0;
    // Nothing is sent before this, on m_clock.
    QElapsedTimer m_clock;
    qint64  m_notBefore = 0;
    int     m_failures = 0;
    // After a refused batch its listens go one at a time, to find the bad one.
    int     m_singlesLeft = 0;
    int     m_spacingMs = kSpacingMs;
    int     m_retryMs   = kRetryMs;
};
