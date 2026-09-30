#include "Auth.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QDateTime>

Auth::Auth(TidalApi *api, QObject *parent)
    : QObject(parent), m_api(api)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setSingleShot(false);
    connect(m_pollTimer, &QTimer::timeout, this, &Auth::pollForToken);

    m_refreshTimer = new QTimer(this);
    m_refreshTimer->setSingleShot(true);
    connect(m_refreshTimer, &QTimer::timeout, this, &Auth::refreshAccessToken);
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
            // "authorization_pending" is normal - keep polling
            if (obj["error"].toString() == "authorization_pending") return;
            // "slow_down" means increase interval
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
        m_tokenExpiry  = QDateTime::currentDateTime().addSecs(obj["expires_in"].toInt(3600));
        m_api->setAccessToken(m_accessToken);
        fetchSession();
    });
}

void Auth::refreshAccessToken() {
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

    m_api->postForm("oauth2/token", form, [this](QJsonObject obj, QString err) {
        if (!err.isEmpty()) {
            if (obj.contains("error")) {
                clearCredentials();
                emit sessionExpired();
                setState(State::LoggedOut);
            } else {
                // Transient network failure (e.g. system just booted and network is not yet up).
                // Retry in 5 seconds if not yet logged in without discarding saved session.
                if (m_state != State::LoggedIn && !m_refreshToken.isEmpty()) {
                    QTimer::singleShot(5000, this, &Auth::refreshAccessToken);
                }
            }
            return;
        }
        m_accessToken = obj["access_token"].toString();
        if (obj.contains("refresh_token")) {
            m_refreshToken = obj["refresh_token"].toString();
            emit hasSavedCredentialsChanged();
        }
        m_tokenExpiry = QDateTime::currentDateTime().addSecs(obj["expires_in"].toInt(3600));
        m_api->setAccessToken(m_accessToken);
        saveCredentials();
        // Schedule next refresh 60s before expiry
        qint64 msec = QDateTime::currentDateTime().msecsTo(m_tokenExpiry) - 60000;
        if (msec > 0) m_refreshTimer->start(msec);

        if (m_state != State::LoggedIn) {
            fetchSession();
        }
    });
}

void Auth::fetchSession() {
    m_api->get("sessions", {}, [this](QJsonObject obj, QString err) {
        if (!err.isEmpty()) {
            if (obj.contains("error") || obj["status"].toInt() == 401) {
                if (!m_refreshToken.isEmpty()) {
                    refreshAccessToken();
                    return;
                }
                emit loginFailed(err);
                setState(State::LoggedOut);
            } else {
                // Network error: don't log out if we have saved user credentials
                if (m_state != State::LoggedIn && m_userId > 0) {
                    emit loginSucceeded();
                    setState(State::LoggedIn);
                    QTimer::singleShot(5000, this, &Auth::fetchSession);
                } else if (m_state != State::LoggedIn) {
                    emit loginFailed(err);
                    setState(State::LoggedOut);
                }
            }
            return;
        }
        m_userId      = obj["userId"].toVariant().toLongLong();
        m_countryCode = obj["countryCode"].toString();
        m_api->setCountryCode(m_countryCode);

        m_api->get(QStringLiteral("users/%1").arg(m_userId), {},
            [this](QJsonObject u, QString) {
                QString name = u["username"].toString();
                if (name.isEmpty()) {
                    QString first = u["firstName"].toString();
                    QString last  = u["lastName"].toString();
                    name = (first + " " + last).trimmed();
                }
                if (!name.isEmpty() && name != m_username) {
                    m_username = name;
                    emit usernameChanged();
                    saveCredentials();
                }
            });

        saveCredentials();

        // Schedule token refresh
        qint64 msec = QDateTime::currentDateTime().msecsTo(m_tokenExpiry) - 60000;
        if (msec > 0) m_refreshTimer->start(msec);

        // Emit before flipping state to LoggedIn: QML reacts to the state
        // change by immediately fetching user-scoped data (playlists, etc),
        // which requires TidalClient::userId to already be set via this signal.
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
    m_tokenExpiry  = QDateTime::fromString(obj["expires_at"].toString(), Qt::ISODate);
    m_userId       = obj["user_id"].toVariant().toLongLong();
    m_countryCode  = obj["country_code"].toString();
    m_username     = obj["username"].toString();

    if (m_accessToken.isEmpty() || m_refreshToken.isEmpty()) return;

    emit hasSavedCredentialsChanged();

    m_api->setAccessToken(m_accessToken);
    m_api->setCountryCode(m_countryCode);

    // If token already expired, refresh immediately
    if (QDateTime::currentDateTime() >= m_tokenExpiry) {
        refreshAccessToken();
    } else {
        // Valid token: transition to LoggedIn immediately so UI renders home page
        emit loginSucceeded();
        setState(State::LoggedIn);
        // Validate session and refresh user info in the background
        fetchSession();
        qint64 msec = QDateTime::currentDateTime().msecsTo(m_tokenExpiry) - 60000;
        if (msec > 0) m_refreshTimer->start(msec);
    }
}

void Auth::saveCredentials() {
    QString dir = QDir::homePath() + "/.config/tidal-wave";
    QDir().mkpath(dir);
    QString path = dir + "/credentials.json";

    QJsonObject obj;
    obj["access_token"]  = m_accessToken;
    obj["refresh_token"] = m_refreshToken;
    obj["expires_at"]    = m_tokenExpiry.toString(Qt::ISODate);
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
    m_refreshTimer->stop();
    m_accessToken.clear();
    m_refreshToken.clear();
    m_deviceCode.clear();
    m_userCode.clear();
    m_countryCode.clear();
    m_userId = 0;
    m_api->setAccessToken({});
    clearCredentials();
    setState(State::LoggedOut);
}
