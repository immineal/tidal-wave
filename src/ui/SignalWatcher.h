// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>

class QSocketNotifier;

// Turns SIGTERM, SIGINT and SIGHUP into an ordinary quit, so ~Player runs.
// A handler may only call async-signal-safe functions, so it writes one byte
// to a socketpair and a QSocketNotifier picks it up on the event loop.
// signalfd is ruled out: it is Linux-only and needs the signals blocked in
// every thread, and Qt has started threads by then. Installed with
// SA_RESETHAND, so a second signal kills a quit that hangs.
class SignalWatcher : public QObject {
    Q_OBJECT

public:
    explicit SignalWatcher(QObject *parent = nullptr);
    ~SignalWatcher() override;

    // Installs the handlers. Idempotent. False means they are not in place:
    // socketpair() or sigaction() failed, or the platform has no POSIX
    // signals. Not fatal.
    bool install();

signals:
    // Delivered on the event loop. May arrive more than once, so the
    // receiver has to tolerate being called twice.
    void quitRequested();

private:
    void onActivated();

    QSocketNotifier *m_notifier = nullptr;
};
