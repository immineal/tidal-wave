// SPDX-License-Identifier: GPL-3.0-or-later

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
class QQmlEngine;
class QLocalServer;
class CastManager;
class Prefs;
class I18n;
class UpdateCheck;
class PinStore;
class LibraryIndex;
class SignalWatcher;

class Application : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool reallyQuit READ reallyQuit NOTIFY reallyQuitChanged)
    // Read off the desktop once at startup.
    Q_PROPERTY(bool reducedMotion READ reducedMotion NOTIFY reducedMotionChanged)
public:
    explicit Application(QObject *parent = nullptr);
    ~Application() override;
    int run(int argc, char **argv);

    bool reallyQuit() const;
    bool reducedMotion() const { return m_reducedMotion; }
    Q_INVOKABLE void quit();
    Q_INVOKABLE void openUrl(const QString &url);

    // Makes SIGTERM, SIGINT and SIGHUP quit the ordinary way, so ~Player runs.
    // Call once, after the QApplication exists. False means the handlers
    // could not be installed. Public so a test can use the same wiring.
    bool installSignalHandlers();

    void showWindow();
    void hideWindow();
    void toggleWindow();

    // ── Startup decisions, split out so tests can reach them ─────────────
    // None of these touch a QApplication or any member.

    // Where the single-instance socket lives for this user.
    static QString singleInstanceSocketName();
    // The longest socket path QLocalServer will bind here, in bytes, or 0
    // where a socket address is not a path.
    static int unixSocketPathMax();
    // Binds `server` to that socket, clearing one left by a crash but never
    // one a live instance answers on. False means the lock was not taken.
    static bool claimSingleInstanceSocket(QLocalServer *server, const QString &socketName);
    // Whether closing the last window should end the process: with no tray
    // icon, or when Prefs::quitOnClose is set.
    static bool shouldQuitOnWindowClose(bool trayAvailable, bool quitOnClose);
    // Whether a log line is an audio-server connect error.
    static bool isAudioServerStartupNoise(const QString &msg);
    // Whether a log line is the FFmpeg media backend announcing itself.
    static bool isMediaBackendStartupNoise(const QString &msg);

    // ── High-DPI scaling ─────────────────────────────────────────────────
    // Qt derives its scale factor from the logical DPI, which is 96 where the
    // display system advertises nothing. The rule defers to devicePixelRatio()
    // and never tests for a platform name. Pure functions, testable unscreened.

    struct ScreenMetrics {
        double physicalDpi = 0;  // QScreen::physicalDotsPerInch()
        double logicalDpi  = 0;  // QScreen::logicalDotsPerInch()
        double platformDpr = 1;  // QScreen::devicePixelRatio(), what Qt already has
        int    widthPx     = 0;  // QScreen::geometry(), device pixels
        int    heightPx    = 0;
    };

    // The range the app chooses from or offers, and the step both the
    // automatic rule and the Settings slider snap to.
    static constexpr double kMinScaleFactor  = 1.0;
    static constexpr double kMaxScaleFactor  = 3.0;
    static constexpr double kScaleFactorStep = 0.25;

    // The automatic rule: factor = physicalDpi / kAutoTargetDpi, snapped and
    // clamped. The target is a preferred logical density chosen by eye.
    static constexpr double kAutoTargetDpi = 142.0;

    // Below this the screen is not dense enough to scale: small fractional
    // factors only blur hairlines.
    static constexpr double kAutoEngageAt = 1.25;

    // How much of the screen the default window may take, so it stays
    // reachable and the setting can be undone.
    static constexpr double kWindowFitFraction = 0.9;

    // Main.qml's initial window size in logical pixels. Mirrored because the
    // factor is chosen before any QML loads; a test checks them against the file.
    static constexpr int kDefaultWindowWidth  = 1280;
    static constexpr int kDefaultWindowHeight = 800;

    // Snap to kScaleFactorStep and clamp into [kMin, kMax].
    static double snapScaleFactor(double factor);
    // The largest step that leaves the default window inside kWindowFitFraction
    // of this screen, never below kMinScaleFactor.
    static double scaleFactorCeilingFor(const ScreenMetrics &screen);
    // The automatic choice for this screen. 1.0 means do not scale, also for
    // a screen whose physical size is missing or absurd.
    static double autoScaleFactor(const ScreenMetrics &screen);
    // `userFactor` (the Settings slider) wins when it is not Auto (0). Auto
    // defers to a platform devicePixelRatio other than 1 and otherwise derives
    // one. Returns 0 for change nothing. The caller handles the environment.
    static double resolveScaleFactor(const ScreenMetrics &screen, double userFactor);

    // What applyScaleFactor() did, for the Settings panel. Static because the
    // decision is taken before any instance exists.
    enum class ScaleSource {
        None,          // nothing was set; Qt is following the platform
        Environment,   // QT_SCALE_FACTOR was already set; the app kept out
        User,          // the Settings slider
        Automatic,     // derived here, because the platform advertised nothing
    };
    static ScaleSource appliedScaleSource();
    // The factor in force, or 1.0 when none was applied.
    static double      appliedScaleFactor();

    // The same facts for QML. With a scale factor set in the environment the
    // slider does nothing, so the panel asks and disables it.
    Q_INVOKABLE bool   scaleIsEnvironmentOverridden() const;
    Q_INVOKABLE bool   scaleWasChosenAutomatically() const;
    Q_INVOKABLE double activeScaleFactor() const;

    // Whether the environment already carries an explicit scale decision, in
    // which case the app changes nothing.
    static bool scaleFactorSetInEnvironment();

    // The largest factor the slider should offer on the current screen, so the
    // window's controls stay on it. Needs a live QGuiApplication.
    Q_INVOKABLE double maxUsableScaleFactor() const;
    Q_INVOKABLE double minScaleFactor() const  { return kMinScaleFactor; }
    Q_INVOKABLE double scaleFactorStep() const { return kScaleFactorStep; }

    // Measures the primary screen, resolves a factor and puts it in the
    // environment. Call from main() before the QApplication exists: Qt reads
    // the scale factor once, while the QApplication is built.
    static void applyScaleFactor();

    // The UI font stack, most specific first, without families that are not
    // installed: the first missing name makes Qt build its alias table on
    // every launch. Needs a QGuiApplication.
    static QStringList uiFontFamilies();

    // Pins the Qt Quick Controls style. The app and every test harness call
    // it on their own engine, so both run the same style.
    static void applyQuickControlsStyle();

    // Puts the embedded TidalWave module's resource root on the import path,
    // which Qt 6.4 does not do itself. Every engine that loads the app's QML
    // has to call this first.
    static void addEmbeddedQmlImportPath(QQmlEngine *engine);

signals:
    void reallyQuitChanged();
    void reducedMotionChanged();

protected:
#ifdef Q_OS_MACOS
    // Brings the window back when the Dock icon is clicked with no window
    // visible.
    bool eventFilter(QObject *watched, QEvent *event) override;
#endif

private:
#ifdef Q_OS_MACOS
    bool hasVisibleWindow() const;
#endif

    // Called at startup when a tray exists, and again from the D-Bus watcher
    // if one turns up later.
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
    SignalWatcher *m_signals = nullptr;

    bool         m_reallyQuit = false;
    bool         m_reducedMotion = false;
};
