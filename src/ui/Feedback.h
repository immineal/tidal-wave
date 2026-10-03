#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QString>

// The two ways a user can say something back: a prefilled GitHub issue and a
// mailto: link, side by side in Settings.
//
// Neither of them talks to anything. Both build a URL and hand it to a program
// the user already trusts - their browser, their mail client - and that program
// does whatever talking happens, once the user presses send. There is no
// account here, no network code and no password: a mailbox this app
// authenticated to would mean shipping a credential inside a binary anyone can
// unpack, which is the one thing it must never do.
//
// The issue body is filled in with the four facts a report always ends up
// needing, so nobody has to go back and ask for them: the version, the
// operating system, and the Qt the build was compiled against *and* the Qt it
// is running on. Those last two are not the same number - the gap between them
// is what caused four bugs in one afternoon - and a report that carries only
// one of them cannot tell the two apart.
//
// The repository is not written down here. It comes from UpdateCheck::repoSlug(),
// which is the one copy in the project.
class Feedback : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    // Default-constructible on purpose, the way Shortcuts is: this holds no
    // state and has nothing to wire. (Qt decides how to build a QML_SINGLETON
    // by checking std::is_default_constructible first and only then looking for
    // create(), so a singleton that *does* need wiring must not be default-
    // constructible - see the comment on ThemePalette.)
    explicit Feedback(QObject *parent = nullptr);

    // ── what the panel calls ─────────────────────────────────────────────

    // "https://github.com/<slug>/issues/new?title=...&body=..." with both
    // parameters percent-encoded. Opening it lands on GitHub's new-issue form
    // with the template already in it; nothing is filed until the user files it.
    Q_INVOKABLE QString issueUrl() const;

    // "mailto:<the project mailbox>?subject=..." and nothing else. No body: a
    // prefilled body in a mail client is a wall of quoted text the user has to
    // delete before they can write, and the diagnostics belong on the issue
    // form where they are machine-readable.
    Q_INVOKABLE QString mailUrl() const;

    // The project's own mailbox, so a label can show the user where their mail
    // is about to go without writing the address down a second time. It is the
    // only address anywhere in this app, deliberately: it is a box made for
    // this, and no personal address belongs in a shipped binary.
    Q_INVOKABLE QString mailAddress() const;

    // The four facts the issue body carries, each on its own so a test can look
    // for them without taking a URL back apart, and so the panel could show
    // them if it ever wanted to.
    Q_INVOKABLE QString appVersion() const;
    Q_INVOKABLE QString operatingSystem() const;
    Q_INVOKABLE QString qtCompiledVersion() const;
    Q_INVOKABLE QString qtRuntimeVersion() const;

    // ── the builders ─────────────────────────────────────────────────────
    //
    // Static and free of this machine, so the shape and the encoding can be
    // pinned without depending on the box the test runs on.

    static QString issueUrlFor(const QString &title, const QString &body);
    static QString mailUrlFor(const QString &subject);
    static QString issueBodyFor(const QString &version, const QString &os,
                                const QString &qtCompiled, const QString &qtRuntime);
    static QString issueTitleFor(const QString &version);
    static QString mailSubjectFor(const QString &version);
};
