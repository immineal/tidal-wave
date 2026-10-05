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

// The socketpair the handler writes into and the notifier reads out of.
// Namespace scope because a POSIX signal handler is a free function with no
// context argument: there is nowhere to hand it a `this`. One per process,
// which is all there can be - the handlers themselves are process-wide.
//
// Written once by install() before any handler can run, and read by the
// handler afterwards, so there is no race worth a lock here (and a lock is
// exactly what a handler may not take).
int g_fds[2] = { -1, -1 };

// The only code that runs inside the signal. Everything it touches has to be
// async-signal-safe, which write() is and essentially nothing else in this
// program is.
void handleSignal(int sig)
{
    // write() is allowed to set errno, and the code this signal interrupted
    // is entitled to find its own errno where it left it - it may be sitting
    // between a failed call and the if that tests for it.
    const int savedErrno = errno;

    const char byte = static_cast<char>(sig);
    ssize_t n;
    do {
        n = ::write(g_fds[1], &byte, 1);
    } while (n < 0 && errno == EINTR);
    // Nothing to do about a failure. A full socket means a wake-up is already
    // queued and unread, which produces the same quit; any other error leaves
    // the second signal (SA_RESETHAND, see the header) as the way out.
    (void)n;

    errno = savedErrno;
}

// The signals that ask a process to go away and whose default disposition is
// to end it where it stands - which is the bug. SIGTERM is what a desktop
// logout, `systemctl stop` and a plain `kill` send; SIGINT is Ctrl-C; SIGHUP
// arrives when the session or the terminal that started the app goes away, and
// a session manager that has given up on a polite shutdown sends it too.
// SIGHUP is caught for the same reason as the other two and no other: its
// default action is termination, so without a handler it leaks the temp file
// exactly as SIGTERM did.
//
// Not here: SIGQUIT, which is a core-dump request and should stay one, and
// nothing in the SIGSEGV family - a handler cannot honestly unwind a process
// whose state is already broken.
constexpr int kSignals[] = { SIGTERM, SIGINT, SIGHUP };

// Puts `disposition` on every signal in kSignals. Returns false if any one of
// them would not take.
bool setDisposition(void (*disposition)(int), int flags)
{
    // Zero-initialised rather than only partly assigned: struct sigaction has
    // members beyond the three set here (sa_restorer and padding on glibc), and
    // handing the kernel a struct with anything undefined in it is a bug that
    // would only ever show up somewhere else.
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

    // Order matters: put the signals back on their default disposition
    // *before* the descriptors go, or a signal arriving in between would have
    // the handler writing into a closed - possibly since reused - fd.
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

    // One live watcher per process, because the handlers and the descriptors
    // they write into are both process-wide. A second one would overwrite the
    // first's descriptors and leave its notifier watching a stale fd, so it is
    // refused outright rather than allowed to quietly break the one that is
    // already working.
    if (g_fds[0] >= 0)
        return false;

    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, g_fds) != 0)
        return false;

    for (const int fd : g_fds) {
        // Non-blocking on both ends. The write end because a handler that
        // blocks is a hung process, and the read end because the notifier
        // drains it in a loop until it would block.
        const int fl = ::fcntl(fd, F_GETFL, 0);
        if (fl >= 0) ::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        // Close-on-exec: the app starts other programs (xdg-open, ffmpeg) and
        // none of them should inherit these.
        const int fd_fl = ::fcntl(fd, F_GETFD, 0);
        if (fd_fl >= 0) ::fcntl(fd, F_SETFD, fd_fl | FD_CLOEXEC);
    }

    m_notifier = new QSocketNotifier(g_fds[0], QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated,
            this, &SignalWatcher::onActivated);

    // SA_RESTART so a signal does not turn somebody else's read() into an
    // EINTR they never handled, and SA_RESETHAND so a second signal gets the
    // default disposition - the escape hatch the header explains.
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
    // No POSIX signals to catch. Windows closes an app down through
    // WM_QUERYENDSESSION, which Qt already turns into an ordinary quit.
    return false;
#endif
}

void SignalWatcher::onActivated()
{
#if defined(Q_OS_UNIX)
    // Drain whatever is there. More than one byte can be waiting - a SIGINT
    // on the heels of a SIGTERM - and they all mean the same thing.
    char buf[16];
    while (::read(g_fds[0], buf, sizeof(buf)) > 0) { }
#endif
    emit quitRequested();
}
