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
#include <QIcon>

class QQmlApplicationEngine;
class QLocalServer;
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

    bool reallyQuit() const;
    bool reducedMotion() const { return m_reducedMotion; }
    Q_INVOKABLE void quit();
    Q_INVOKABLE void openUrl(const QString &url);

    void showWindow();
    void hideWindow();
    void toggleWindow();

    // ── Startup decisions, split out so tests can reach them ─────────────
    // None of these touch a QApplication or any member, so tst_startup.cpp
    // can call them straight, without bringing an application up first.

    // Where the single-instance rendezvous socket lives for this user.
    static QString singleInstanceSocketName();
    // Binds `server` to that socket, clearing one left behind by a crash but
    // never one a live instance still answers on. False means the lock could
    // not be taken, which run() treats as non-fatal.
    static bool claimSingleInstanceSocket(QLocalServer *server, const QString &socketName);
    // Whether closing the last window should end the process. It should when
    // there is no tray icon to bring it back from, and whenever the user has
    // asked for a close to be a quit (Prefs::quitOnClose).
    static bool shouldQuitOnWindowClose(bool trayAvailable, bool quitOnClose);
    // Whether a log line is one of the audio-server connect errors a machine
    // with no sound server prints on every single launch.
    static bool isAudioServerStartupNoise(const QString &msg);

signals:
    void reallyQuitChanged();
    void reducedMotionChanged();

private:
    // Builds the tray icon and its menu. Called at startup when a tray is
    // already there, and again from the D-Bus watcher if one turns up later.
    void createTrayIcon(const QIcon &icon);

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
