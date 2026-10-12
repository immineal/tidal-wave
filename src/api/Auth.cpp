// SPDX-License-Identifier: GPL-3.0-or-later

#include "Auth.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QDateTime>
#include <QPointer>
#include <utility>

namespace {

// The token is replaced this long before it runs out.
constexpr qint64 kRefreshAheadMs = 60000;

// A token issued less than this ago is not replaced because a request was
// refused: that refusal is about something else, and every further one would
// send the login host another question.
constexpr qint64 kRenewGapMs = 60000;

// How often the clock is compared with the expiry. No timer is given the
// whole wait: a timer's clock can stand still while the machine sleeps.
constexpr int kExpiryCheckMs = 30000;

} // namespace

Auth::Auth(TidalApi *api, QObject *parent)
    : QObject(parent), m_api(api)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setSingleShot(false);
    connect(m_pollTimer, &QTimer::timeout, this, &Auth::pollForToken);

    m_expiryCheck = new QTimer(this);
    m_expiryCheck->setTimerType(Qt::VeryCoarseTimer);
    m_expiryCheck->setInterval(kExpiryCheckMs);
    connect(m_expiryCheck, &QTimer::timeout, this, &Auth::refreshIfDue);

    m_api->setTokenRenewer([self = QPointer<Auth>(this)](const QString &refused,
                                                         std::function<void(bool)> done) {
        if (self) self->renewRefused(refused, std::move(done));
        else done(false);
    });
}

// UTC, so the expiry held in memory names one instant in every timezone.
QDateTime Auth::now() const { return QDateTime::currentDateTimeUtc(); }

void Auth::refreshIfDue() {
    if (now().msecsTo(m_tokenExpiry) <= kRefreshAheadMs) refreshAccessToken();
}

void Auth::renewRefused(const QString &refused, std::function<void(bool)> done) {
    const bool justIssued = !m_refreshing && m_issued.isValid()
                            && m_issued.elapsed() < kRenewGapMs;
    if (m_refreshToken.isEmpty() || refused != m_accessToken || justIssued) {
        done(false);
        return;
    }
    m_refused << std::move(done);
    refreshAccessToken();
}

void Auth::answerRefused(bool renewed) {
    const auto waiting = std::exchange(m_refused, {});
    for (const auto &done : waiting) done(renewed);
}

void Auth::endSession() {
    m_expiryCheck->stop();
    m_issued.invalidate();
    // No later request carries the dead token and asks for a refresh.
    m_accessToken.clear();
    m_api->setAccessToken({});
    clearCredentials();
    answerRefused(false);
    emit sessionExpired();
    setState(State::LoggedOut);
}

void Auth::setState(State s) {
    if (m_state == s) return;
    m_state = s;
    emit stateChanged(s);
}

void Auth::startDeviceFlow() {
    if (m_state == State::PendingDevice) return;
    setState(State::PendingDevice);

    QUrlQuery form;
    form.addQueryItem("client_id", kClientId);
    form.addQueryItem("scope", "r_usr w_usr w_sub");

    m_api->postForm("oauth2/device_authorization", form,
        [this](QJsonObject obj, QString err) {
            if (!err.isEmpty()) {
                setState(State::LoggedOut);
                emit loginFailed(err);
                return;
            }
            m_deviceCode      = obj["deviceCode"].toString();
            m_userCode        = obj["userCode"].toString();
            QString uri       = obj["verificationUriComplete"].toString(
                                obj["verificationUri"].toString());
            if (!uri.isEmpty() && !uri.startsWith("http"))
                uri = "https://" + uri;
            m_verificationUri = uri;
            m_pollInterval    = obj["interval"].toInt(5);
            emit userCodeChanged();
            m_pollTimer->start(m_pollInterval * 1000);
        });
}

void Auth::cancelDeviceFlow() {
    m_pollTimer->stop();
    m_deviceCode.clear();
    m_userCode.clear();
    m_verificationUri.clear();
    setState(State::LoggedOut);
}

void Auth::pollForToken() {
    QUrlQuery form;
    form.addQueryItem("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    form.addQueryItem("device_code", m_deviceCode);
    form.addQueryItem("client_id", kClientId);
    form.addQueryItem("client_secret", kClientSecret);
    form.addQueryItem("scope", "r_usr w_usr w_sub");

    m_api->postForm("oauth2/token", form, [this](QJsonObject obj, QString err) {
        if (!err.isEmpty()) {
            // Pending is the normal answer until the user confirms: keep polling.
            if (obj["error"].toString() == "authorization_pending") return;
            if (obj["error"].toString() == "slow_down") {
                m_pollInterval += 5;
                m_pollTimer->setInterval(m_pollInterval * 1000);
                return;
            }
            m_pollTimer->stop();
            setState(State::LoggedOut);
            emit loginFailed(err);
            return;
        }
        m_pollTimer->stop();
        m_accessToken  = obj["access_token"].toString();
        m_refreshToken = obj["refresh_token"].toString();
        emit hasSavedCredentialsChanged();
        m_tokenExpiry  = now().addSecs(obj["expires_in"].toInt(3600));
        m_issued.start();
        m_api->setAccessToken(m_accessToken);
        m_expiryCheck->start();
        fetchSession();
    });
}

void Auth::refreshAccessToken() {
    // One at a time: whoever asks meanwhile is answered by the one under way.
    if (m_refreshing) return;
    if (m_refreshToken.isEmpty()) {
        emit sessionExpired();
        setState(State::LoggedOut);
        return;
    }
    QUrlQuery form;
    form.addQueryItem("grant_type", "refresh_token");
    form.addQueryItem("refresh_token", m_refreshToken);
    form.addQueryItem("client_id", kClientId);
    form.addQueryItem("client_secret", kClientSecret);

    m_refreshing = true;
    m_api->postForm("oauth2/token", form,
                    [this, asked = m_refreshToken](QJsonObject obj, QString err) {
        m_refreshing = false;
        // Signed out while this was on its way: the answer is for no session.
        if (asked != m_refreshToken) return;
        if (!err.isEmpty()) {
            if (obj.contains("error")) {
                endSession();
            } else {
                // No error body means the network failed, e.g. right after
                // boot. Retry and keep the saved session.
                if (m_state != State::LoggedIn) {
                    QTimer::singleShot(5000, this, &Auth::refreshAccessToken);
                }
                answerRefused(false);
            }
            return;
        }
        m_accessToken = obj["access_token"].toString();
        if (obj.contains("refresh_token")) {
            m_refreshToken = obj["refresh_token"].toString();
            emit hasSavedCredentialsChanged();
        }
        m_tokenExpiry = now().addSecs(obj["expires_in"].toInt(3600));
        m_issued.start();
        m_api->setAccessToken(m_accessToken);
        saveCredentials();
        m_expiryCheck->start();
        answerRefused(true);

        if (m_state != State::LoggedIn) {
            fetchSession();
        }
    });
}

// Tidal's "username" is the email address on most accounts, so it comes last
// and an address is never shown.
QString Auth::displayNameFrom(const QJsonObject &u) {
    const QString profile = u["profileName"].toString().trimmed();
    if (!profile.isEmpty()) return profile;

    const QString full = (u["firstName"].toString() + QLatin1Char(' ')
                          + u["lastName"].toString()).trimmed();
    if (!full.isEmpty()) return full;

    const QString username = u["username"].toString().trimmed();
    if (!username.contains(QLatin1Char('@'))) return username;

    return {};
}

// Written as UTC: a bare wall clock read back in another timezone shifts the
// expiry, and with it m_refreshTimer, by the difference in offsets.
QString Auth::expiryToString(const QDateTime &when) {
    if (!when.isValid()) return {};
    return when.toUTC().toString(Qt::ISODate);
}

// A stored value without Z or offset is local time and is read as local time.
// Reading it as UTC would shift an existing install's expiry by its offset.
QDateTime Auth::expiryFromString(const QString &stored) {
    return QDateTime::fromString(stored, Qt::ISODate);
}

void Auth::fetchSession() {
    m_api->get("sessions", {}, [this](QJsonObject obj, QString err) {
        // The session ended while this was on its way.
        if (m_accessToken.isEmpty()) return;
        if (!err.isEmpty()) {
            // A refusal over the token was answered inside TidalApi. What is
            // left is the network: keep a saved session signed in.
            if (m_state != State::LoggedIn && m_userId > 0) {
                emit loginSucceeded();
                setState(State::LoggedIn);
                QTimer::singleShot(5000, this, &Auth::fetchSession);
            } else if (m_state != State::LoggedIn) {
                emit loginFailed(err);
                setState(State::LoggedOut);
            }
            return;
        }
        m_userId      = obj["userId"].toVariant().toLongLong();
        m_countryCode = obj["countryCode"].toString();
        m_api->setCountryCode(m_countryCode);

        m_api->get(QStringLiteral("users/%1").arg(m_userId), {},
            [this](QJsonObject u, QString) {
                const QString name = displayNameFrom(u);
                if (!name.isEmpty() && name != m_username) {
                    m_username = name;
                    emit usernameChanged();
                    saveCredentials();
                }
            });

        saveCredentials();

        // Emit before the state flips: QML fetches user-scoped data on the
        // state change, and TidalClient::userId is set by this signal.
        emit loginSucceeded();
        setState(State::LoggedIn);
    });
}

void Auth::loadCredentials() {
    QString path = QDir::homePath() + kCredsFile;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return;

    auto doc = QJsonDocument::fromJson(f.readAll());
    auto obj = doc.object();
    m_accessToken  = obj["access_token"].toString();
    m_refreshToken = obj["refresh_token"].toString();
    m_tokenExpiry  = expiryFromString(obj["expires_at"].toString()).toUTC();
    m_userId       = obj["user_id"].toVariant().toLongLong();
    m_countryCode  = obj["country_code"].toString();
    m_username     = obj["username"].toString();
    if (m_username.contains(QLatin1Char('@'))) m_username.clear();

    if (m_accessToken.isEmpty() || m_refreshToken.isEmpty()) return;

    emit hasSavedCredentialsChanged();

    m_api->setAccessToken(m_accessToken);
    m_api->setCountryCode(m_countryCode);

    m_expiryCheck->start();

    // An expiry that cannot be read counts as past.
    if (now().msecsTo(m_tokenExpiry) <= 0) {
        refreshAccessToken();
    } else {
        // A valid token logs in at once; the session is validated behind it.
        emit loginSucceeded();
        setState(State::LoggedIn);
        fetchSession();
        // In its last minute it is replaced now.
        refreshIfDue();
    }
}

void Auth::saveCredentials() {
    QString dir = QDir::homePath() + "/.config/tidal-wave";
    QDir().mkpath(dir);
    QString path = dir + "/credentials.json";

    QJsonObject obj;
    obj["access_token"]  = m_accessToken;
    obj["refresh_token"] = m_refreshToken;
    obj["expires_at"]    = expiryToString(m_tokenExpiry);
    obj["user_id"]       = m_userId;
    obj["country_code"]  = m_countryCode;
    obj["username"]      = m_username;

    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        f.write(QJsonDocument(obj).toJson());
    }
}

void Auth::clearCredentials() {
    QFile::remove(QDir::homePath() + kCredsFile);
    m_refreshToken.clear();
    emit hasSavedCredentialsChanged();
}

void Auth::logout() {
    m_pollTimer->stop();
    m_expiryCheck->stop();
    m_issued.invalidate();
    m_accessToken.clear();
    m_refreshToken.clear();
    m_deviceCode.clear();
    m_userCode.clear();
    m_countryCode.clear();
    m_userId = 0;
    m_api->setAccessToken({});
    clearCredentials();
    answerRefused(false);
    setState(State::LoggedOut);
}
