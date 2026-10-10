// SPDX-License-Identifier: GPL-3.0-or-later

#include "Feedback.h"

#include "UpdateCheck.h"

#include <QStringList>
#include <QSysInfo>
#include <QUrl>
#include <QtGlobal>

namespace {

// The project's feedback mailbox. Only ever handed to a mail client.
constexpr auto kMailbox = "tidal-wave@linu.li";

// Encodes everything outside the unreserved set: a space becomes %20 and a
// newline %0A, as GitHub's form and mail clients expect in a query value.
QString enc(const QString &s) {
    return QString::fromLatin1(QUrl::toPercentEncoding(s));
}

// The version with a leading "v", as the Settings panel prints it.
QString tagged(const QString &version) {
    return version.isEmpty() ? version : QLatin1String("v") + version;
}

} // namespace

Feedback::Feedback(QObject *parent) : QObject(parent) {}

QString Feedback::mailAddress() const {
    return QLatin1String(kMailbox);
}

QString Feedback::appVersion() const {
    return QLatin1String(TIDALWAVE_VERSION);
}

QString Feedback::operatingSystem() const {
    // The name the system gives itself, such as the distribution's.
    return QSysInfo::prettyProductName();
}

QString Feedback::qtCompiledVersion() const {
    return QLatin1String(QT_VERSION_STR);
}

QString Feedback::qtRuntimeVersion() const {
    // Can differ from the compiled version: a package built against one Qt
    // may run on the one the distribution installed.
    return QLatin1String(qVersion());
}

QString Feedback::issueUrl() const {
    return issueUrlFor(issueTitleFor(appVersion()),
                       issueBodyFor(appVersion(), operatingSystem(),
                                    qtCompiledVersion(), qtRuntimeVersion()));
}

QString Feedback::mailUrl() const {
    return mailUrlFor(mailSubjectFor(appVersion()));
}

QString Feedback::issueUrlFor(const QString &title, const QString &body) {
    return QStringLiteral("https://github.com/%1/issues/new?title=%2&body=%3")
        .arg(UpdateCheck::repoSlug(), enc(title), enc(body));
}

QString Feedback::mailUrlFor(const QString &subject) {
    // The address is not encoded: RFC 6068 wants the addr-spec literal, "@"
    // included, and some clients cannot parse an encoded one.
    return QStringLiteral("mailto:%1?subject=%2")
        .arg(QLatin1String(kMailbox), enc(subject));
}

QString Feedback::issueTitleFor(const QString &version) {
    // A usable title even if the user never edits it.
    return tr("Problem with Tidal Wave %1").arg(tagged(version));
}

QString Feedback::mailSubjectFor(const QString &version) {
    return tr("Feedback on Tidal Wave %1").arg(tagged(version));
}

QString Feedback::issueBodyFor(const QString &version, const QString &os,
                               const QString &qtCompiled, const QString &qtRuntime) {
    // GitHub renders the body as Markdown. The headings are translated, the
    // "###" and the bullets are not.
    const QString h = QStringLiteral("### ");
    const QString b = QStringLiteral("- ");
    QStringList lines;
    lines << h + tr("What happened")
          << QString()
          << QString()
          << h + tr("What I expected instead")
          << QString()
          << QString()
          << h + tr("System")
          << QString()
          // Not translated: it is the name of the program.
          << b + QStringLiteral("Tidal Wave: %1").arg(tagged(version))
          << b + tr("Operating system: %1").arg(os)
          << b + tr("Qt, compiled against: %1").arg(qtCompiled)
          << b + tr("Qt, running now: %1").arg(qtRuntime);
    return lines.join(QLatin1Char('\n'));
}
