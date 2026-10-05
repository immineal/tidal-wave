#pragma once
#include <QObject>

class QSocketNotifier;

// Turns SIGTERM, SIGINT and SIGHUP into an ordinary quit, so the app shuts
// down the same way the tray's Quit and MPRIS's Quit() already do.
//
// Why this exists at all: the app installed no handler, so a KDE logout, a
// `systemctl reboot` or a Ctrl-C in a terminal killed the process outright.
// Nothing unwound, which meant ~Player never ran, so the session was not
// saved and the track it was playing was left behind in the temp directory.
// On the machine this was found on, 33 of those files had piled up over four
// days - 254 MB, and one lossless track can be far larger than the ~8 MB
// average of those; see the note on the temp file in ~Player.
//
// ── Why a self-pipe and not signalfd ─────────────────────────────────────
//
// A signal handler may only call async-signal-safe functions. It lands on
// whatever thread happened to be running, between any two instructions, so
// anything holding a lock - malloc, QDebug, and emphatically qApp->quit() -
// can deadlock or corrupt from in there. Qt sanctions two ways out, the
// self-pipe and Linux's signalfd, and this is the self-pipe:
//
//   * It is portable. The app ships on macOS as well (see the Q_OS_MACOS
//     paths in Application.cpp), and signalfd is Linux-only. Choosing it
//     would mean either a second implementation for the Mac or leaving the
//     Mac with the bug.
//   * signalfd needs the signals blocked with pthread_sigmask in *every*
//     thread, and Qt has already started threads of its own by the time this
//     is installed - the FFmpeg media backend and the network stack among
//     them. A thread that missed the mask takes the signal at its default
//     disposition and the process dies anyway, which is the bug we came to
//     fix, now intermittent.
//
// The handler therefore does one thing: write() one byte into a socketpair.
// The read end is a QSocketNotifier, so the byte comes back out on the event
// loop as an ordinary activation, where calling into Qt is safe again.
//
// ── Why a second signal cannot wedge the logout ──────────────────────────
//
// The handlers are installed with SA_RESETHAND, so delivering a signal
// atomically puts that signal back on SIG_DFL. The first SIGTERM asks for a
// clean quit; if the clean quit is wedged, a second one kills the process
// outright, exactly as it would have before this class existed. A handler
// that could swallow every SIGTERM would be worse than no handler at all,
// because then a hung shutdown would hang the user's logout with it.
//
// This is a wake-up, not a kill switch: it says "a quit was asked for" and
// leaves what that means to the caller.
class SignalWatcher : public QObject {
    Q_OBJECT

public:
    explicit SignalWatcher(QObject *parent = nullptr);
    ~SignalWatcher() override;

    // Installs the handlers. Idempotent: a second call on the same object is
    // a no-op that answers the same thing the first did.
    //
    // False means the handlers are not in place - the socketpair or the
    // sigaction() failed, or this is a platform without POSIX signals. It is
    // not a reason to refuse to start: the app then behaves exactly as it did
    // before this class existed, which is the status quo and not a new fault.
    bool install();

signals:
    // A quit was asked for, delivered on the event loop rather than from
    // inside the handler. May arrive more than once (a SIGINT after a SIGTERM,
    // or two of either), so whatever is connected to it has to tolerate being
    // called twice.
    void quitRequested();

private:
    void onActivated();

    QSocketNotifier *m_notifier = nullptr;
};
