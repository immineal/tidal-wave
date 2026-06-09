#pragma once
#include <QObject>
#include "api/TidalApi.h"
#include "api/Auth.h"
#include "api/TidalClient.h"
#include "api/TidalBridge.h"
#include "player/Player.h"
#include "mpris/MprisPlayer.h"
#include "ui/ImageProvider.h"
#include "ui/discordrpc.h"
#include <QSystemTrayIcon>

class QQmlApplicationEngine;

class Application : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool reallyQuit READ reallyQuit NOTIFY reallyQuitChanged)
public:
    explicit Application(QObject *parent = nullptr);
    int run(int argc, char **argv);

    bool reallyQuit() const { return m_reallyQuit; }
    Q_INVOKABLE void quit();

    void showWindow();
    void hideWindow();
    void toggleWindow();

signals:
    void reallyQuitChanged();

private slots:
    void updateDiscordRPC();
    void onPlayerPositionChanged(qint64 ms);

private:
    TidalApi    *m_api    = nullptr;
    Auth        *m_auth   = nullptr;
    TidalClient *m_client = nullptr;
    TidalBridge *m_bridge = nullptr;
    Player      *m_player = nullptr;
    MprisManager*m_mpris  = nullptr;
    DiscordRPC  *m_discord = nullptr;
    QSystemTrayIcon *m_trayIcon = nullptr;
    QQmlApplicationEngine *m_engine = nullptr;

    bool         m_reallyQuit = false;
    qint64       m_lastDiscordUpdatePos = 0;
    qint64       m_lastDiscordUpdateTime = 0;
};
