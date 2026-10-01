#pragma once
#include <QObject>
#include "api/TidalApi.h"
#include "api/Auth.h"
#include "api/TidalClient.h"
#include "api/TidalBridge.h"
#include "player/Player.h"
#include "player/Downloader.h"
#include "mpris/MprisPlayer.h"
#include "ui/ImageProvider.h"
#include <QSystemTrayIcon>

class QQmlApplicationEngine;
class CastManager;
class Prefs;
class I18n;
class UpdateCheck;
class PinStore;
class LibraryIndex;

class Application : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool reallyQuit READ reallyQuit NOTIFY reallyQuitChanged)
    // X6. Qt exposes no reduced-motion hint of its own, so this is read off the
    // desktop once at startup; see the comment on detectReducedMotion().
    Q_PROPERTY(bool reducedMotion READ reducedMotion NOTIFY reducedMotionChanged)
public:
    explicit Application(QObject *parent = nullptr);
    int run(int argc, char **argv);

    bool reallyQuit() const { return m_reallyQuit; }
    bool reducedMotion() const { return m_reducedMotion; }
    Q_INVOKABLE void quit();
    Q_INVOKABLE void openUrl(const QString &url);

    void showWindow();
    void hideWindow();
    void toggleWindow();

signals:
    void reallyQuitChanged();
    void reducedMotionChanged();

private:
    Prefs       *m_prefs  = nullptr;
    I18n        *m_i18n   = nullptr;
    UpdateCheck *m_update = nullptr;
    TidalApi    *m_api    = nullptr;
    Auth        *m_auth   = nullptr;
    TidalClient *m_client = nullptr;
    TidalBridge *m_bridge = nullptr;
    Player      *m_player = nullptr;
    Downloader  *m_downloader = nullptr;
    CastManager *m_cast   = nullptr;
    PinStore    *m_pins   = nullptr;
    LibraryIndex *m_library = nullptr;
    MprisManager*m_mpris  = nullptr;
    QSystemTrayIcon *m_trayIcon = nullptr;
    QQmlApplicationEngine *m_engine = nullptr;

    bool         m_reallyQuit = false;
    bool         m_reducedMotion = false;
};
