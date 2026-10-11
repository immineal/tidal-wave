// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QDateTime>
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QString>
#include <QUrl>

class QNetworkAccessManager;

// Asks GitHub whether there is a release newer than this build, at most once
// a day, and caches the answer. It never downloads or installs anything and
// only publishes state: QML shows the prompt at the next launch.
class UpdateCheck : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the updateCheck context property")

    // True when a release is newer than this build, not a prerelease, not
    // skipped by the user, and the check is switched on.
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateChanged)
    // The tag as GitHub spells it, with its leading "v".
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY updateChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)

public:
    explicit UpdateCheck(QObject *parent = nullptr);

    // An empty tag means nothing to offer: a draft, a prerelease or a broken
    // payload.
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

    // Honours the switch and the 24h throttle. Asynchronous, and silent on
    // failure.
    void startupCheck();

    // Ignores the throttle. Does nothing when the check is off.
    Q_INVOKABLE void checkNow();
    // Never offer this version again. Anything newer is still offered.
    Q_INVOKABLE void skipThisVersion();
    // Drop the offer until the next check succeeds.
    Q_INVOKABLE void remindLater();

    // ── pure, so they are testable offline ───────────────────────────────

    // -1, 0 or +1 for two semver-like tags. A leading "v" and build metadata
    // are ignored, missing components read as zero, and a prerelease sorts
    // before the same version without the suffix.
    static int compareVersions(const QString &a, const QString &b);

    // Reads GitHub's "latest release" payload. Drafts, prereleases and
    // anything unparseable come back invalid.
    static Release parseRelease(const QByteArray &payload);

    // Whether `tag` should be offered to someone running `current`, given
    // the version they last skipped (empty if none).
    static bool shouldOffer(const QString &tag, const QString &current, const QString &skipped);

    // Whether the 24h window has passed. An invalid or future timestamp
    // counts as due, so a clock change cannot switch the check off.
    static bool isDue(const QDateTime &lastCheck, const QDateTime &now);

    static QUrl    releasesApiUrl();
    static QString releasesPageUrl();
    // The repository's GitHub slug, also used by Feedback.
    static QString repoSlug();
    static QByteArray userAgent();

signals:
    void updateChanged();
    void enabledChanged();

protected:
    // The only two members that touch the network. Virtual and protected so
    // tests can drive the class with no connection.
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
