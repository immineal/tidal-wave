// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QString>

// Feedback from Settings: a prefilled GitHub issue and a mailto: link. Both
// only build a URL for the browser or mail client; there is no network code
// and no credential here. The issue body carries the version, the operating
// system, and both the Qt compiled against and the Qt running, which can
// differ. The repository comes from UpdateCheck::repoSlug().
class Feedback : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    // Default-constructible on purpose: the type holds no state, so QML may
    // build its own instance.
    explicit Feedback(QObject *parent = nullptr);

    // ── what the panel calls ─────────────────────────────────────────────

    // GitHub's new-issue form with title and body prefilled and
    // percent-encoded. Nothing is filed until the user files it.
    Q_INVOKABLE QString issueUrl() const;

    // "mailto:<the project mailbox>?subject=..." with no body.
    Q_INVOKABLE QString mailUrl() const;

    // The project's mailbox, the only address in the app.
    Q_INVOKABLE QString mailAddress() const;

    // The four facts the issue body carries.
    Q_INVOKABLE QString appVersion() const;
    Q_INVOKABLE QString operatingSystem() const;
    Q_INVOKABLE QString qtCompiledVersion() const;
    Q_INVOKABLE QString qtRuntimeVersion() const;

    // ── the builders ─────────────────────────────────────────────────────
    // Static and independent of this machine, so tests can pin the shape and
    // the encoding.

    static QString issueUrlFor(const QString &title, const QString &body);
    static QString mailUrlFor(const QString &subject);
    static QString issueBodyFor(const QString &version, const QString &os,
                                const QString &qtCompiled, const QString &qtRuntime);
    static QString issueTitleFor(const QString &version);
    static QString mailSubjectFor(const QString &version);
};
