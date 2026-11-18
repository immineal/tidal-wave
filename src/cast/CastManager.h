// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QHash>

class Player;
class TidalClient;
class CastDiscovery;
class CastSession;
class CastMediaServer;
class CastMediaPrep;

// Ties together mDNS discovery, the CASTV2 session, the local media server, and
// per-track media prep, and coordinates handoff with the Player. Exposed to QML
// as the `cast` context property.
class CastManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString deviceName READ deviceName NOTIFY connectedChanged)
public:
    CastManager(TidalClient *client, Player *player, QObject *parent = nullptr);
    ~CastManager() override;

    QVariantList devices() const;
    bool         connected() const { return m_connected; }
    QString      deviceName() const { return m_deviceName; }

    Q_INVOKABLE void startScan();
    Q_INVOKABLE void connectToDevice(const QString &id);
    Q_INVOKABLE void disconnect();

    // (Re)cast the player's current track, on connect and on track change.
    void castCurrentTrack();

signals:
    void devicesChanged();
    void connectedChanged();
    void error(const QString &msg);
    // The device ended the cast, not the user; deviceName is the one it was on.
    void endedOnDevice(const QString &deviceName);

private slots:
    void onDeviceFound(const QString &id, const QString &name, const QString &host, int port);
    void onDeviceRemoved(const QString &id);
    void onSessionConnected();
    void onSessionDisconnected();

private:
    struct Device { QString id, name, host; int port = 0; };

    TidalClient     *m_client   = nullptr;
    Player          *m_player   = nullptr;
    CastDiscovery   *m_discovery = nullptr;
    CastSession     *m_session  = nullptr;
    CastMediaServer *m_server   = nullptr;
    CastMediaPrep   *m_prep     = nullptr;

    QHash<QString, Device> m_devices;
    bool    m_connected = false;
    // Between beginCast() and endCast(). Outlasts m_connected while a cast
    // moves from one device to the next.
    bool    m_playerCasting = false;
    QString m_deviceId;
    QString m_deviceName;
    // The local track and position when the cast began, for its first LOAD.
    qlonglong m_startTrackId = 0;
    double    m_startSec     = 0;
};
