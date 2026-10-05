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

    // Makes SIGTERM, SIGINT and SIGHUP quit the app the ordinary way, so that
    // ~Player runs and gets to save the session and remove the temp media
    // file. Call it once, after the QApplication exists; run() does.
    //
    // Separate from run() and public so a test can bring up this exact
    // wiring - the real SignalWatcher connected to the real quit() - in a
    // child process without a QML engine or an account. False means the
    // handlers could not be installed, which run() treats as non-fatal.
    bool installSignalHandlers();

    void showWindow();
    void hideWindow();
    void toggleWindow();

    // ── Startup decisions, split out so tests can reach them ─────────────
    // None of these touch a QApplication or any member, so tst_startup.cpp
    // can call them straight, without bringing an application up first.

    // Where the single-instance rendezvous socket lives for this user.
    static QString singleInstanceSocketName();
    // The longest socket path QLocalServer will bind on this platform, in bytes,
    // or 0 where a socket address is not a path at all. It is derived from
    // sizeof(sockaddr_un::sun_path), which is 108 on Linux and 104 on Apple's
    // platforms, less the two bytes the comment at kUnixSocketPathMax explains.
    // tst_startup.cpp asks for the number rather than writing one of those down
    // a second time, which is how the old hard-coded 107 came to be wrong in the
    // code and in its own test at once.
    static int unixSocketPathMax();
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
    // Whether a log line is the FFmpeg media backend announcing itself. Unlike
    // the audio-server lines this appears on every machine, because it is
    // unconditional in the plugin rather than a symptom of anything.
    static bool isMediaBackendStartupNoise(const QString &msg);

    // ── High-DPI scaling ─────────────────────────────────────────────────
    // Qt 6 derives its scale factor from the screen's *logical* DPI. Where the
    // display system advertises one, Qt is already right. Where it advertises
    // nothing the logical DPI is the 96 default, Qt computes 96/96 = 1, and the
    // app draws one logical pixel per device pixel: on the 3840x2400 / 344x215 mm
    // panel this was reported from - 283.5 ppi - the login button's 48 logical px
    // comes out 4.3 mm tall.
    //
    // Nothing below asks which desktop or windowing system it is running on, and
    // nothing should. "Does the platform advertise a scale factor" is a question
    // with a direct answer - QScreen::devicePixelRatio() - and that answer is
    // what gets deferred to. Testing for a platform *name* would both miss a
    // dense panel under a compositor that happens to report 1 and wrongly skip
    // one under a compositor that does not, which is the same bug in two
    // directions.
    //
    // These are pure functions of the numbers so they can be tested without a
    // screen; applyScaleFactor() is the one that touches the process.

    // What one screen looks like, as much of it as the decision needs.
    struct ScreenMetrics {
        double physicalDpi = 0;  // QScreen::physicalDotsPerInch()
        double logicalDpi  = 0;  // QScreen::logicalDotsPerInch()
        double platformDpr = 1;  // QScreen::devicePixelRatio(), what Qt already has
        int    widthPx     = 0;  // QScreen::geometry(), device pixels
        int    heightPx    = 0;
    };

    // The lowest and highest factor the app will ever choose or offer, and the
    // granularity both the automatic rule and the Settings slider snap to.
    static constexpr double kMinScaleFactor  = 1.0;
    static constexpr double kMaxScaleFactor  = 3.0;
    static constexpr double kScaleFactorStep = 0.25;

    // The automatic rule, and the only place the rule lives.
    //
    // It aims at a comfortable *logical* resolution rather than at preserving
    // the design's millimetre sizes: scaling is about how much fits on the
    // screen at a normal viewing distance, which is why reproducing 48 px at
    // 96 dpi exactly (factor 2.95 here) was judged too large by eye on the real
    // panel. kAutoTargetDpi is that judgement, as a number: factor =
    // physicalDpi / kAutoTargetDpi, snapped to kScaleFactorStep and clamped.
    // Changing the preferred density is a one-line change to this constant.
    //
    // 142 is not arithmetic, it is the user's eye on a real 283.5 dpi panel.
    // All three candidates were rendered at native pixels and compared: 3.0
    // (95 dpi, 12.90 mm button) was called too big, and between the other two
    // he chose 2.0 over 2.5. 142 is what puts that panel on 2.0. Two earlier
    // rules, both derived rather than looked at, produced 2.95 and then 2.5;
    // neither survived contact with the screen, which is why this is a
    // measured constant and not a formula.
    static constexpr double kAutoTargetDpi = 142.0;

    // Below this the screen is not dense enough to be worth scaling and the
    // small fractional factors are worse than none - they only blur hairlines.
    static constexpr double kAutoEngageAt = 1.25;

    // How much of the screen the default window is allowed to want. At 3.0 on
    // the reported panel the window came out 3840 px wide against a 3840 px
    // screen and the window manager clamped it, which is a window the user
    // cannot get hold of to undo the setting.
    static constexpr double kWindowFitFraction = 0.9;

    // Main.qml's initial window size, in logical pixels. Mirrored rather than
    // read because the factor has to be chosen before any QML is loaded;
    // tests/tst_startup.cpp checks the two against the file so they cannot
    // drift apart silently.
    static constexpr int kDefaultWindowWidth  = 1280;
    static constexpr int kDefaultWindowHeight = 800;

    // Snap to kScaleFactorStep and clamp into [kMin, kMax].
    static double snapScaleFactor(double factor);
    // The largest step that leaves the default window inside kWindowFitFraction
    // of this screen, never below kMinScaleFactor.
    static double scaleFactorCeilingFor(const ScreenMetrics &screen);
    // The automatic choice for this screen, or 1.0 for "do not scale". Returns
    // 1.0 for a screen whose physical size is missing or absurd: Qt synthesises
    // a physical size from the logical DPI when the platform reports none, so
    // that case arrives here as physicalDpi == logicalDpi and falls out as 1.0.
    static double autoScaleFactor(const ScreenMetrics &screen);
    // The whole order of authority, highest first:
    //   1. an explicit factor in the environment - handled by the caller, since
    //      it is a property of the process rather than of the screen;
    //   2. `userFactor`, the Settings slider, when it is not Auto (0). It applies
    //      on every platform: the user's eye is the only thing that can overrule
    //      a physical size we have no reliable way to learn;
    //   3. Auto, which defers to a platform that has actually told us something
    //      (devicePixelRatio other than 1) and otherwise derives one.
    // Returns 0 for "change nothing".
    static double resolveScaleFactor(const ScreenMetrics &screen, double userFactor);

    // What applyScaleFactor() actually did, so the Settings panel can explain
    // itself instead of presenting a control that may or may not be doing
    // anything. Statics, because the decision is taken before any instance of
    // this class exists.
    enum class ScaleSource {
        None,          // nothing was set; Qt is following the platform
        Environment,   // QT_SCALE_FACTOR was already set; the app kept out
        User,          // the Settings slider
        Automatic,     // derived here, because the platform advertised nothing
    };
    static ScaleSource appliedScaleSource();
    // The factor in force, or 1.0 when none was applied.
    static double      appliedScaleFactor();

    // The same three facts, for QML.
    //
    // The first one matters: when QT_SCALE_FACTOR is set outside the process the
    // app deliberately keeps its hands off entirely, which leaves the slider
    // doing nothing at all. A control that looks live and is not is worse than
    // one that is visibly disabled, so the panel asks.
    Q_INVOKABLE bool   scaleIsEnvironmentOverridden() const;
    Q_INVOKABLE bool   scaleWasChosenAutomatically() const;
    Q_INVOKABLE double activeScaleFactor() const;

    // Whether the environment already carries an explicit scale decision, in
    // which case the app keeps its hands off entirely.
    static bool scaleFactorSetInEnvironment();

    // The largest factor the Settings slider should offer on the screen the app
    // is on right now, so the user cannot pick one that opens a window whose
    // controls are off the edge. Needs a live QGuiApplication, unlike everything
    // above it, which is why it is an instance method the panel can call.
    Q_INVOKABLE double maxUsableScaleFactor() const;
    // The step and the ends of the range, for the slider to lay itself out
    // against the same numbers the resolution above uses.
    Q_INVOKABLE double minScaleFactor() const  { return kMinScaleFactor; }
    Q_INVOKABLE double scaleFactorStep() const { return kScaleFactorStep; }

    // Measures the primary screen, resolves a factor and puts it in the
    // environment. Call it from main() *before* the QApplication exists; Qt
    // reads the scale factor once, while the QApplication is being built, and
    // never looks again.
    static void applyScaleFactor();

    // The UI font stack, most specific first, with every family that is not
    // actually installed removed.
    //
    // Naming a family that does not exist is not free. Qt answers the first
    // missing family it meets by populating its font-family alias table, which
    // the Mac measured at 37 ms on every single launch - about 8% of the 470 ms
    // to first frame. The measurement also killed the obvious fix: dropping
    // "Inter" on macOS changed nothing, because the very same 37 ms line came
    // back naming "Monospace" instead. Whichever missing name comes first pays,
    // so the rule has to be "name nothing that is missing", not "drop the one
    // we know about".
    //
    // Needs a QGuiApplication, because it asks the font database.
    static QStringList uiFontFamilies();

    // Pins the Qt Quick Controls style, where this platform needs it pinned.
    // The app calls it before the engine runs and every test harness calls it on
    // its own engine, so the two can never be looking at different styles -
    // which they were, and which made the macOS suite fail on style warnings
    // while the app itself was silent. Whatever the decision below becomes, it
    // becomes it for both at once.
    static void applyQuickControlsStyle();

    // Puts the resource root that holds the embedded TidalWave module on
    // `engine`'s import path, where Qt 6.4 does not put it itself. Every engine
    // that is going to load any of the app's QML has to call this first - the
    // app's in run(), and the tests' in installTestStubs() - which is why it
    // lives here rather than being written out at each call site.
    static void addEmbeddedQmlImportPath(QQmlEngine *engine);

signals:
    void reallyQuitChanged();
    void reducedMotionChanged();

protected:
#ifdef Q_OS_MACOS
    // Watches the QApplication for the activation macOS sends when the Dock
    // icon of an app with no visible window is clicked, and brings the window
    // back the same way the tray's "Show" does. Apple-only: no other platform
    // hides the window behind a Dock icon like this, and on Linux the tray is
    // the way back.
    bool eventFilter(QObject *watched, QEvent *event) override;
#endif

private:
#ifdef Q_OS_MACOS
    bool hasVisibleWindow() const;
#endif

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
    SignalWatcher *m_signals = nullptr;

    bool         m_reallyQuit = false;
    bool         m_reducedMotion = false;
};
