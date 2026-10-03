#include "Feedback.h"

#include "UpdateCheck.h"

#include <QStringList>
#include <QSysInfo>
#include <QUrl>
#include <QtGlobal>

namespace {

// The mailbox the project keeps for this, on the maintainer's own domain. The
// app only ever hands it to a mail client; it never logs in to it, so there is
// nothing here for a password to be needed for.
constexpr auto kMailbox = "tidal-wave@linu.li";

// Everything outside the unreserved set, encoded. QUrl::toPercentEncoding with
// no exclusions is the strict reading: a space becomes %20 rather than +, and a
// newline becomes %0A, which is what GitHub's form and every mail client expect
// in a query value.
QString enc(const QString &s) {
    return QString::fromLatin1(QUrl::toPercentEncoding(s));
}

// "v0.4.0" - the way the Account card prints it, so a report and the panel the
// user read it off agree.
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
    // "Arch Linux", "Debian GNU/Linux 12 (bookworm)", "macOS 15.1". Qt reads it
    // off /etc/os-release and friends, so it is the name the user's own system
    // calls itself rather than a kernel string nobody recognises.
    return QSysInfo::prettyProductName();
}

QString Feedback::qtCompiledVersion() const {
    return QLatin1String(QT_VERSION_STR);
}

QString Feedback::qtRuntimeVersion() const {
    // Not the same as the line above, and that is the point: a .deb built
    // against 6.12 can be running on the 6.11 the distribution installed, and a
    // report carrying one number cannot show it.
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
    // The address is left alone. RFC 6068 wants the addr-spec literal in the
    // path, "@" included; percent-encoding it gives some clients an address
    // they cannot parse.
    return QStringLiteral("mailto:%1?subject=%2")
        .arg(QLatin1String(kMailbox), enc(subject));
}

QString Feedback::issueTitleFor(const QString &version) {
    // A title that is a whole sentence even if the user never touches it: a
    // prefilled "Short summary here" left in place is an issue titled "Short
    // summary here".
    return tr("Problem with Tidal Wave %1").arg(tagged(version));
}

QString Feedback::mailSubjectFor(const QString &version) {
    return tr("Feedback on Tidal Wave %1").arg(tagged(version));
}

QString Feedback::issueBodyFor(const QString &version, const QString &os,
                               const QString &qtCompiled, const QString &qtRuntime) {
    // GitHub renders the body as Markdown, so the two blanks are headings with
    // nothing under them: a form with a visible gap in it is answered, and a
    // paragraph of instructions is deleted unread. The headings are translated;
    // the "###" and the bullets are not, because they are not words.
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
