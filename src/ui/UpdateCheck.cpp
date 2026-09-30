#include "UpdateCheck.h"

#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QStringList>
#include <algorithm>
#include <chrono>

namespace {

// The repository the update check reads releases from. One edit here is the
// whole move if the project ever changes hands or names; CPACK_PACKAGE_HOMEPAGE_URL
// in CMakeLists.txt has to agree with it.
constexpr auto kRepoSlug = "immineal/tidal-wave";

constexpr auto kLastCheck = "update/lastCheck";
constexpr auto kLatest    = "update/latestVersion";
constexpr auto kUrl       = "update/releaseUrl";
constexpr auto kSkipped   = "update/skippedVersion";
constexpr auto kEnabled   = "update/enabled";

// A version tag split into the numeric core and the prerelease suffix. Build
// metadata ("+d1e8a") carries no ordering in semver, so it is dropped here.
struct Parsed {
    QList<int>  core;
    QStringList pre;
};

Parsed parseVersion(const QString &raw) {
    QString s = raw.trimmed();
    if (s.startsWith(QLatin1Char('v')) || s.startsWith(QLatin1Char('V')))
        s.remove(0, 1);
    const qsizetype plus = s.indexOf(QLatin1Char('+'));
    if (plus >= 0) s.truncate(plus);

    Parsed out;
    const qsizetype dash = s.indexOf(QLatin1Char('-'));
    QString core = s;
    if (dash >= 0) {
        core = s.left(dash);
        const QString pre = s.mid(dash + 1);
        if (!pre.isEmpty())
            out.pre = pre.split(QLatin1Char('.'), Qt::SkipEmptyParts);
    }

    // A component that is not a number reads as zero rather than failing the
    // whole comparison: a tag nobody expected should never crash a launch.
    const QStringList parts = core.split(QLatin1Char('.'), Qt::SkipEmptyParts);
    for (const QString &p : parts) {
        bool ok = false;
        const int n = p.toInt(&ok);
        out.core.append(ok && n > 0 ? n : 0);
    }
    return out;
}

int compareCore(const QList<int> &a, const QList<int> &b) {
    const qsizetype n = std::max(a.size(), b.size());
    for (qsizetype i = 0; i < n; ++i) {
        const int x = i < a.size() ? a[i] : 0;   // "1.2" is "1.2.0"
        const int y = i < b.size() ? b[i] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

// Semver's prerelease rule: identifier by identifier, numbers numerically and
// below anything alphanumeric, and a shorter run of identifiers sorts first.
int comparePre(const QStringList &a, const QStringList &b) {
    if (a.isEmpty() && b.isEmpty()) return 0;
    if (a.isEmpty()) return 1;      // a release outranks its own prereleases
    if (b.isEmpty()) return -1;

    const qsizetype n = std::min(a.size(), b.size());
    for (qsizetype i = 0; i < n; ++i) {
        bool aNum = false, bNum = false;
        const int x = a[i].toInt(&aNum);
        const int y = b[i].toInt(&bNum);
        if (aNum && bNum) {
            if (x != y) return x < y ? -1 : 1;
        } else if (aNum != bNum) {
            return aNum ? -1 : 1;
        } else {
            const int c = QString::compare(a[i], b[i]);
            if (c != 0) return c < 0 ? -1 : 1;
        }
    }
    if (a.size() == b.size()) return 0;
    return a.size() < b.size() ? -1 : 1;
}

bool hasPrerelease(const QString &tag) {
    return !parseVersion(tag).pre.isEmpty();
}

} // namespace

UpdateCheck::UpdateCheck(QObject *parent)
    : QObject(parent)
    , m_enabled(m_settings.value(QLatin1String(kEnabled), true).toBool())
    , m_latestVersion(m_settings.value(QLatin1String(kLatest)).toString())
    , m_releaseUrl(m_settings.value(QLatin1String(kUrl)).toString())
    , m_skippedVersion(m_settings.value(QLatin1String(kSkipped)).toString())
{
    // The cache decides what this launch offers. Whatever the network says
    // later is for the launch after this one.
    m_updateAvailable = shouldOffer(m_latestVersion,
                                    QStringLiteral(TIDALWAVE_VERSION),
                                    m_skippedVersion) && m_enabled;
}

QUrl UpdateCheck::releasesApiUrl() {
    return QUrl(QStringLiteral("https://api.github.com/repos/%1/releases/latest")
                    .arg(QLatin1String(kRepoSlug)));
}

QString UpdateCheck::releasesPageUrl() {
    return QStringLiteral("https://github.com/%1/releases/latest").arg(QLatin1String(kRepoSlug));
}

QByteArray UpdateCheck::userAgent() {
    // The GitHub API answers 403 to a request that does not send one.
    return QStringLiteral("tidal-wave/%1 (+https://github.com/%2)")
        .arg(QLatin1String(TIDALWAVE_VERSION), QLatin1String(kRepoSlug))
        .toUtf8();
}

int UpdateCheck::compareVersions(const QString &a, const QString &b) {
    const Parsed pa = parseVersion(a);
    const Parsed pb = parseVersion(b);
    const int core = compareCore(pa.core, pb.core);
    return core != 0 ? core : comparePre(pa.pre, pb.pre);
}

UpdateCheck::Release UpdateCheck::parseRelease(const QByteArray &payload) {
    Release r;
    const QJsonDocument doc = QJsonDocument::fromJson(payload);
    if (!doc.isObject()) return r;             // empty body, HTML error page, array

    const QJsonObject o = doc.object();
    // A draft is not public yet, and a prerelease is opt-in by definition.
    if (o.value(QStringLiteral("draft")).toBool()) return r;
    if (o.value(QStringLiteral("prerelease")).toBool()) return r;

    const QString tag = o.value(QStringLiteral("tag_name")).toString().trimmed();
    if (tag.isEmpty()) return r;               // also covers GitHub's error objects

    r.tag = tag;
    r.url = o.value(QStringLiteral("html_url")).toString().trimmed();
    // "Open release" has to land somewhere, even on a payload without a link.
    if (r.url.isEmpty()) r.url = releasesPageUrl();
    return r;
}

bool UpdateCheck::shouldOffer(const QString &tag, const QString &current, const QString &skipped) {
    if (tag.trimmed().isEmpty()) return false;
    if (compareVersions(tag, current) <= 0) return false;
    // A stable build is never nudged onto a prerelease, however new it is.
    if (hasPrerelease(tag) && !hasPrerelease(current)) return false;
    if (!skipped.isEmpty() && compareVersions(tag, skipped) <= 0) return false;
    return true;
}

bool UpdateCheck::isDue(const QDateTime &lastCheck, const QDateTime &now) {
    if (!lastCheck.isValid()) return true;
    // A stamp in the future means the clock moved, not that a check just ran.
    if (lastCheck > now) return true;
    return lastCheck.secsTo(now) >= qint64(checkIntervalHours) * 3600;
}

void UpdateCheck::startupCheck() {
    if (!m_enabled) return;
    if (!isDue(m_settings.value(QLatin1String(kLastCheck)).toDateTime(),
               QDateTime::currentDateTimeUtc()))
        return;
    sendRequest(releasesApiUrl());
}

void UpdateCheck::checkNow() {
    if (!m_enabled) return;
    sendRequest(releasesApiUrl());
}

void UpdateCheck::skipThisVersion() {
    if (m_latestVersion.isEmpty()) return;
    m_skippedVersion = m_latestVersion;
    m_settings.setValue(QLatin1String(kSkipped), m_skippedVersion);
    recompute();
}

void UpdateCheck::remindLater() {
    // Forget the release but keep the timestamp. Nothing is offered now, and
    // the next check that runs puts the offer back for the launch after it.
    const bool had = !m_latestVersion.isEmpty() || !m_releaseUrl.isEmpty();
    m_latestVersion.clear();
    m_releaseUrl.clear();
    m_settings.remove(QLatin1String(kLatest));
    m_settings.remove(QLatin1String(kUrl));
    recompute(had);
}

void UpdateCheck::setEnabled(bool v) {
    if (v == m_enabled) return;
    m_enabled = v;
    m_settings.setValue(QLatin1String(kEnabled), v);
    emit enabledChanged();
    recompute();
}

void UpdateCheck::sendRequest(const QUrl &url) {
    if (m_inFlight) return;
    if (!m_net) m_net = new QNetworkAccessManager(this);   // only ever built if a check runs

    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgent());
    req.setRawHeader("Accept", "application/vnd.github+json");
    req.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    // Startup must not depend on this finishing, or on it finishing at all.
#if QT_VERSION >= QT_VERSION_CHECK(6, 7, 0)
    req.setTransferTimeout(std::chrono::seconds(15));
#else
    req.setTransferTimeout(15000);
#endif

    QNetworkReply *reply = m_net->get(req);
    m_inFlight = true;
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        m_inFlight = false;
        // 0 when the request never reached a server: no network, no DNS, timeout.
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool limited = status == 403
                          && reply->rawHeader("X-RateLimit-Remaining") == QByteArrayLiteral("0");
        handleReply(status, reply->readAll(), limited);
    });
}

void UpdateCheck::handleReply(int httpStatus, const QByteArray &body, bool rateLimited) {
    if (rateLimited) {
        // Retrying would only be refused again, so take the full day off.
        markChecked();
        return;
    }
    // Being offline is not something to report. The timestamp is left alone so
    // that coming back online is enough to get a check on the next launch.
    if (httpStatus != 200) return;

    markChecked();

    const Release r = parseRelease(body);
    // A draft, a prerelease or a broken payload leaves the cache as it was:
    // the newest release worth offering is still whatever was found last.
    if (!r.isValid()) return;

    const bool changed = (r.tag != m_latestVersion) || (r.url != m_releaseUrl);
    m_latestVersion = r.tag;
    m_releaseUrl    = r.url;
    m_settings.setValue(QLatin1String(kLatest), m_latestVersion);
    m_settings.setValue(QLatin1String(kUrl), m_releaseUrl);
    recompute(changed);
}

void UpdateCheck::markChecked() {
    m_settings.setValue(QLatin1String(kLastCheck), QDateTime::currentDateTimeUtc());
}

// `force` covers the case where latestVersion or releaseUrl moved while
// updateAvailable itself did not: the three share one notify signal.
void UpdateCheck::recompute(bool force) {
    const bool now = m_enabled
                  && shouldOffer(m_latestVersion, QStringLiteral(TIDALWAVE_VERSION), m_skippedVersion);
    const bool changed = force || now != m_updateAvailable;
    m_updateAvailable = now;
    if (changed) emit updateChanged();
}
