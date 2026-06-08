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

class Application : public QObject {
    Q_OBJECT
public:
    explicit Application(QObject *parent = nullptr);
    int run(int argc, char **argv);

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

    qint64       m_lastDiscordUpdatePos = 0;
    qint64       m_lastDiscordUpdateTime = 0;
};
