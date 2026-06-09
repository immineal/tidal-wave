#pragma once
#include <QObject>
#include <QTimer>
#include "TidalApi.h"

class Auth : public QObject {
    Q_OBJECT
    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString userCode READ userCode NOTIFY userCodeChanged)
    Q_PROPERTY(QString verificationUrl READ verificationUrl NOTIFY userCodeChanged)
    Q_PROPERTY(QString username READ username NOTIFY usernameChanged)

public:
    enum class State { LoggedOut, PendingDevice, LoggedIn };
    Q_ENUM(State)

    explicit Auth(TidalApi *api, QObject *parent = nullptr);

    State   state()           const { return m_state; }
    QString userCode()        const { return m_userCode; }
    QString verificationUrl() const { return m_verificationUri; }
    QString username()        const { return m_username; }
    QString accessToken()     const { return m_accessToken; }
    QString refreshToken()    const { return m_refreshToken; }
    qint64  userId()          const { return m_userId; }
    QString countryCode()     const { return m_countryCode; }

    // Attempt device flow login
    Q_INVOKABLE void startDeviceFlow();
    // Cancel pending auth
    Q_INVOKABLE void cancelDeviceFlow();
    // Log out
    Q_INVOKABLE void logout();

    // Called on startup with persisted tokens
    void loadCredentials();

signals:
    void stateChanged(State state);
    void userCodeChanged();
    void usernameChanged();
    void loginSucceeded();
    void loginFailed(const QString &reason);
    void sessionExpired();

private slots:
    void pollForToken();
    void refreshAccessToken();

private:
    void setState(State s);
    void fetchSession();
    void saveCredentials();
    void clearCredentials();

    TidalApi  *m_api;
    QTimer    *m_pollTimer;
    QTimer    *m_refreshTimer;
    State      m_state = State::LoggedOut;

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
