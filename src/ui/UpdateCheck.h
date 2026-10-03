#pragma once
#include <QDateTime>
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QString>
#include <QUrl>

class QNetworkAccessManager;

// Asks GitHub whether there is a release newer than this build, at most once a
// day, and remembers the answer so most launches cost nothing. The app never
// downloads or installs anything: the prompt opens the release page in a
// browser and that is the end of it.
//
// This class only publishes state. Nothing here interrupts a session - the
// prompt is shown at the next launch, by QML, reading `updateAvailable`.
class UpdateCheck : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the update context property")

    // True when there is a release worth showing: newer than this build, not a
    // prerelease, not one the user skipped, and the check is switched on.
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateChanged)
    // The tag as GitHub spells it, "v0.4.1" and all.
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY updateChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)

public:
    explicit UpdateCheck(QObject *parent = nullptr);

    // One release, already judged. An empty tag means "nothing to offer",
    // which is where a draft, a prerelease and a broken payload all land.
    struct Release {
        QString tag;
        QString url;
        bool isValid() const { return !tag.isEmpty(); }
    };

    static constexpr int checkIntervalHours = 24;

    bool    updateAvailable() const { return m_updateAvailable; }
    QString latestVersion()   const { return m_latestVersion; }
    QString releaseUrl()      const { return m_releaseUrl; }
    bool    enabled()         const { return m_enabled; }

    void setEnabled(bool v);

    // Called once from Application::run(). Honours the switch and the 24h
    // throttle, and does nothing at all if either says no. Never blocks: the
    // request is asynchronous and a failure is silent.
    void startupCheck();

    // Ignores the throttle, for a "check now" button in Settings. Still
    // silent on failure, and still does nothing when the check is off.
    Q_INVOKABLE void checkNow();
    // Never offer this version again. Anything newer is still offered.
    Q_INVOKABLE void skipThisVersion();
    // Drop the offer for now; it comes back on the launch after the next
    // check succeeds.
    Q_INVOKABLE void remindLater();

    // ── pure, so the parts worth getting right are testable offline ──────

    // -1, 0 or +1, ordering two semver-ish tags: a leading "v" is ignored,
    // numeric components compare as numbers (0.10.0 > 0.9.0), missing trailing
    // components read as zero, build metadata is ignored, and a prerelease
    // suffix sorts before the same version without one.
    static int compareVersions(const QString &a, const QString &b);

    // Reads GitHub's "latest release" payload. Drafts and prereleases come
    // back invalid, as does anything unparseable.
    static Release parseRelease(const QByteArray &payload);

    // Whether `tag` is worth putting in front of someone running `current`,
    // given the version they last skipped (empty if none).
    static bool shouldOffer(const QString &tag, const QString &current, const QString &skipped);

    // Whether the 24h window has passed. An invalid or future timestamp counts
    // as due, so a clock change cannot switch the check off for good.
    static bool isDue(const QDateTime &lastCheck, const QDateTime &now);

    static QUrl    releasesApiUrl();
    static QString releasesPageUrl();
    // The "owner/name" this project lives at, which is also where a feedback
    // issue is filed (src/ui/Feedback.cpp). Published rather than copied: the
    // slug is written down once, in UpdateCheck.cpp, and a project that changes
    // hands is still one edit.
    static QString repoSlug();
    static QByteArray userAgent();

signals:
    void updateChanged();
    void enabledChanged();

protected:
    // The only two members that know about the network, kept virtual and
    // protected so tests can drive the whole class with no connection.
    virtual void sendRequest(const QUrl &url);
    // `httpStatus` is 0 when the request never reached a server.
    void handleReply(int httpStatus, const QByteArray &body, bool rateLimited);

private:
    void recompute(bool force = false);
    void markChecked();

    QSettings m_settings;
    QNetworkAccessManager *m_net = nullptr;
    bool    m_inFlight = false;

    bool    m_enabled;
    QString m_latestVersion;
    QString m_releaseUrl;
    QString m_skippedVersion;
    bool    m_updateAvailable = false;
};
