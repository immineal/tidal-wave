// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QDateTime>
#include <QElapsedTimer>
#include <QTimer>
#include "TidalApi.h"

class Auth : public QObject {
    Q_OBJECT
    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString userCode READ userCode NOTIFY userCodeChanged)
    Q_PROPERTY(QString verificationUrl READ verificationUrl NOTIFY userCodeChanged)
    Q_PROPERTY(QString username READ username NOTIFY usernameChanged)
    Q_PROPERTY(bool hasSavedCredentials READ hasSavedCredentials NOTIFY hasSavedCredentialsChanged)

public:
    enum class State { LoggedOut, PendingDevice, LoggedIn };
    Q_ENUM(State)

    explicit Auth(TidalApi *api, QObject *parent = nullptr);

    State   state()               const { return m_state; }
    bool    hasSavedCredentials() const { return !m_refreshToken.isEmpty(); }
    QString userCode()            const { return m_userCode; }
    QString verificationUrl() const { return m_verificationUri; }
    QString username()        const { return m_username; }
    QString accessToken()     const { return m_accessToken; }
    QString refreshToken()    const { return m_refreshToken; }
    qint64  userId()          const { return m_userId; }
    QString countryCode()     const { return m_countryCode; }

    Q_INVOKABLE void startDeviceFlow();
    Q_INVOKABLE void cancelDeviceFlow();
    Q_INVOKABLE void logout();

    // Called on startup with persisted tokens
    void loadCredentials();

    // What the sidebar shows for the signed-in account. Public for tst_auth.
    static QString displayNameFrom(const QJsonObject &u);

    // How the token expiry is stored in credentials.json. Public for tst_auth.
    static QString   expiryToString(const QDateTime &when);
    static QDateTime expiryFromString(const QString &stored);

signals:
    void stateChanged(State state);
    void userCodeChanged();
    void usernameChanged();
    void loginSucceeded();
    void loginFailed(const QString &reason);
    void sessionExpired();
    void hasSavedCredentialsChanged();

protected:
    // The wall clock. Virtual as a test seam only: a test moves it.
    virtual QDateTime now() const;

private slots:
    void pollForToken();
    void refreshAccessToken();
    // Compares the wall clock with the expiry. The wake-up calls it.
    void refreshIfDue();

private:
    void setState(State s);
    void fetchSession();
    void saveCredentials();
    void clearCredentials();
    // A request was refused over `refused`: one refresh answers all of them.
    void renewRefused(const QString &refused, std::function<void(bool)> done);
    void answerRefused(bool renewed);
    // The way a refresh goes that the login host refuses.
    void endSession();

    TidalApi  *m_api;
    QTimer    *m_pollTimer;
    QTimer    *m_expiryCheck;
    State      m_state = State::LoggedOut;
    bool       m_refreshing = false;
    // Runs since the token in hand was issued to this process.
    QElapsedTimer m_issued;
    QList<std::function<void(bool)>> m_refused;

    QString m_deviceCode;
    QString m_userCode;
    QString m_verificationUri;
    int     m_pollInterval = 5;

    QString m_accessToken;
    QString m_refreshToken;
    QDateTime m_tokenExpiry;
    qint64  m_userId     = 0;
    QString m_countryCode;
    QString m_username;

    static constexpr auto kClientId     = "fX2JxdmntZWK0ixT";
    static constexpr auto kClientSecret = "1Nn9AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAzxAg=";
    static constexpr auto kCredsFile    = "/.config/tidal-wave/credentials.json";
};
