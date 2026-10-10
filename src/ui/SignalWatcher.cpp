// SPDX-License-Identifier: GPL-3.0-or-later

#include "ui/SignalWatcher.h"

#include <QSocketNotifier>

#if defined(Q_OS_UNIX)
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#if defined(Q_OS_UNIX)
namespace {

// The socketpair the handler writes into and the notifier reads from. Global
// because a signal handler takes no context argument. Written by install()
// before any handler can run, so no lock, which a handler may not take anyway.
int g_fds[2] = { -1, -1 };

// Runs inside the signal: only async-signal-safe calls are allowed here.
void handleSignal(int sig)
{
    // write() may set errno, and the interrupted code needs its own back.
    const int savedErrno = errno;

    const char byte = static_cast<char>(sig);
    ssize_t n;
    do {
        n = ::write(g_fds[1], &byte, 1);
    } while (n < 0 && errno == EINTR);
    // A full socket means a wake-up is already queued. Any other error
    // leaves the second signal (SA_RESETHAND) as the way out.
    (void)n;

    errno = savedErrno;
}

// The signals that ask a process to go away and end it by default: logout
// and kill, Ctrl-C, and a closed session or terminal. Not SIGQUIT, which is a
// core-dump request, and nothing in the SIGSEGV family.
constexpr int kSignals[] = { SIGTERM, SIGINT, SIGHUP };

// Puts `disposition` on every signal in kSignals. False if any one failed.
bool setDisposition(void (*disposition)(int), int flags)
{
    // Zero-initialised: struct sigaction has members beyond the three set here.
    struct sigaction sa = {};
    sa.sa_handler = disposition;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = flags;

    bool ok = true;
    for (const int sig : kSignals)
        ok = (::sigaction(sig, &sa, nullptr) == 0) && ok;
    return ok;
}

} // namespace
#endif // Q_OS_UNIX

SignalWatcher::SignalWatcher(QObject *parent) : QObject(parent) {}

SignalWatcher::~SignalWatcher()
{
#if defined(Q_OS_UNIX)
    if (!m_notifier)
        return;

    // Restore the default disposition before closing the descriptors, or a
    // signal in between would write into a closed, possibly reused, fd.
    setDisposition(SIG_DFL, 0);

    delete m_notifier;
    m_notifier = nullptr;

    for (int &fd : g_fds) {
        if (fd >= 0) ::close(fd);
        fd = -1;
    }
#endif
}

bool SignalWatcher::install()
{
#if defined(Q_OS_UNIX)
    if (m_notifier)
        return true;

    // One live watcher per process: handlers and descriptors are
    // process-wide, and a second one would overwrite the first's descriptors.
    if (g_fds[0] >= 0)
        return false;

    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, g_fds) != 0)
        return false;

    for (const int fd : g_fds) {
        // Non-blocking on both ends: the handler must never block, and the
        // notifier drains the read end until it would block.
        const int fl = ::fcntl(fd, F_GETFL, 0);
        if (fl >= 0) ::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        // Close-on-exec, so child processes do not inherit these.
        const int fd_fl = ::fcntl(fd, F_GETFD, 0);
        if (fd_fl >= 0) ::fcntl(fd, F_SETFD, fd_fl | FD_CLOEXEC);
    }

    m_notifier = new QSocketNotifier(g_fds[0], QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated,
            this, &SignalWatcher::onActivated);

    // SA_RESTART so other code's read() does not see EINTR. SA_RESETHAND so
    // a second signal gets the default disposition and kills the process.
    if (!setDisposition(&handleSignal, SA_RESTART | SA_RESETHAND)) {
        delete m_notifier;
        m_notifier = nullptr;
        for (int &fd : g_fds) {
            if (fd >= 0) ::close(fd);
            fd = -1;
        }
        return false;
    }

    return true;
#else
    // No POSIX signals. Qt already turns Windows' WM_QUERYENDSESSION into an
    // ordinary quit.
    return false;
#endif
}

void SignalWatcher::onActivated()
{
#if defined(Q_OS_UNIX)
    // Drain it: more than one byte can be waiting, and all mean the same.
    char buf[16];
    while (::read(g_fds[0], buf, sizeof(buf)) > 0) { }
#endif
    emit quitRequested();
}
