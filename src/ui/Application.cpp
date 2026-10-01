#include "Application.h"
#include "ui/I18n.h"
#include "ui/PinStore.h"
#include "ui/Prefs.h"
#include "ui/ThemePalette.h"
#include "ui/UpdateCheck.h"
#include "api/LibraryIndex.h"
#ifdef Q_OS_LINUX
#include "cast/CastManager.h"
#endif
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDateTime>
#include <QFont>
#include <QIcon>
#include <QImage>
#include <QFile>
#include <QDir>
#include <QSettings>
#include <QStandardPaths>
#include <QSurfaceFormat>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QLoggingCategory>
#include <QLibrary>
#include <QLocalServer>
#include <QLocalSocket>
#include <QWindow>
#include <QMenu>
#include <QAction>
#include <QProcess>
#include <QDesktopServices>
#include <QUrl>
// #include <QQuickStyle>

typedef int (*snd_lib_error_handler_t)(const char *file, int line, const char *function, int err, const char *fmt, ...);
typedef int (*snd_lib_error_set_handler_t)(snd_lib_error_handler_t handler);

static int dummyAlsaErrorHandler(const char *, int, const char *, int, const char *, ...) {
    return 0;
}

static void silenceAlsa() {
    QLibrary alsaLib(QStringLiteral("asound"));
    if (!alsaLib.load()) {
        alsaLib.setFileName(QStringLiteral("asound.so.2"));
        alsaLib.load();
    }
    if (alsaLib.isLoaded()) {
        auto set_handler = reinterpret_cast<snd_lib_error_set_handler_t>(alsaLib.resolve("snd_lib_error_set_handler"));
        if (set_handler) {
            set_handler(dummyAlsaErrorHandler);
        }
    }
}

static QtMessageHandler originalMessageHandler = nullptr;

static void myMessageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg) {
    if (msg.contains(QStringLiteral("spaVisitChoice"))) {
        return; // Ignore and silence this log message completely
    }
    if (originalMessageHandler) {
        originalMessageHandler(type, context, msg);
    } else {
        QByteArray localMsg = msg.toLocal8Bit();
        fprintf(stderr, "%s\n", localMsg.constData());
    }
}

static void silenceLogsAndAlsa() {
    // Silence Qt Multimedia / FFmpeg logs
    QLoggingCategory::setFilterRules(QStringLiteral("qt.multimedia*=false"));

    // Intercept and filter out "spaVisitChoice" log messages
    originalMessageHandler = qInstallMessageHandler(myMessageHandler);

    // Silence ALSA stderr warnings/errors (e.g. spaVisitChoice: parse error).
    // ALSA is Linux-only; the dlopen is a no-op elsewhere but skip it for clarity.
#ifdef Q_OS_LINUX
    silenceAlsa();
#endif
}

// Locates the bundled app icon in the Qt resource system.
//
// The QML module's RESOURCES prefix moved from ":/TidalWave/..." to
// ":/qt/qml/TidalWave/..." when QTP0001 was set to NEW (commit 749527a). A
// hardcoded single path silently broke the tray icon when that happened, so we
// probe both prefixes and return whichever actually exists — future policy
// churn can't blank the tray again.
static QString appIconResourcePath() {
    const QStringList candidates = {
        QStringLiteral(":/qt/qml/TidalWave/assets/icon.png"),
        QStringLiteral(":/TidalWave/assets/icon.png"),
    };
    for (const QString &p : candidates) {
        if (QFile::exists(p))
            return p;
    }
    return candidates.first();
}

// Returns the application icon as a *named* theme icon ("tidal-wave").
//
// KDE Plasma's system tray uses the StatusNotifierItem (SNI) protocol. A tray
// icon supplied only as a serialized pixmap (what you get from QIcon(":/...png"))
// frequently renders blank on Plasma 6, even though the same QIcon works fine for
// the window/taskbar icon (those go through X11's native _NET_WM_ICON). SNI hosts
// render reliably when the icon is referenced by NAME and resolved from the icon
// theme. So we export the bundled icon into the user's hicolor theme and hand the
// tray a named icon; KDE then finds "tidal-wave" in ~/.local/share/icons/hicolor.
static QIcon loadAppIcon() {
    const QString iconName = QStringLiteral("tidal-wave");
    const QString resPath = appIconResourcePath();
    const QImage src(resPath);
    if (!src.isNull()) {
        const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
                             + QStringLiteral("/icons/hicolor");
        for (int s : {16, 22, 24, 32, 48, 64, 128, 256}) {
            const QString dir  = QStringLiteral("%1/%2x%2/apps").arg(base).arg(s);
            const QString path = QStringLiteral("%1/%2.png").arg(dir, iconName);
            QDir().mkpath(dir);
            src.scaled(s, s, Qt::KeepAspectRatio, Qt::SmoothTransformation).save(path);
        }
        // Force Qt's icon-theme loader to re-scan so the just-written file is
        // found on first launch (otherwise the cached index misses it).
        if (!QIcon::themeName().isEmpty())
            QIcon::setThemeName(QIcon::themeName());
    }
    // Named themed icon (so SNI sends IconName), with the embedded pixmap as a
    // fallback for non-KDE trays / if theme lookup fails.
    return QIcon::fromTheme(iconName, QIcon(resPath));
}

// Whether the desktop has asked for less animation (SPEC X6).
//
// Qt has no cross-platform hint for this - QStyleHints carries nothing of the
// kind as of 6.12 - so the two Linux desktops that do expose one are read
// directly out of their config files. Both are plain INI, so there is no new
// dependency and nothing to fail at runtime; an absent or unreadable file just
// means "no preference". Windows (SPI_GETCLIENTAREAANIMATION) and macOS
// (NSWorkspace.accessibilityDisplayShouldReduceMotion) expose one too and are
// not read yet; the environment override below works everywhere in the
// meantime.
static bool detectReducedMotion() {
    const QByteArray forced = qgetenv("TIDALWAVE_REDUCED_MOTION");
    if (!forced.isEmpty())
        return forced != "0" && forced.compare("false", Qt::CaseInsensitive) != 0;

#if defined(Q_OS_UNIX) && !defined(Q_OS_MACOS)
    const QString cfg =
        QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (!cfg.isEmpty()) {
        // KDE: System Settings > Accessibility, the animation speed slider at
        // its left-hand end, which writes a factor of 0.
        QSettings kde(cfg + QStringLiteral("/kdeglobals"), QSettings::IniFormat);
        const QVariant factor = kde.value(QStringLiteral("KDE/AnimationDurationFactor"));
        if (factor.isValid() && factor.toDouble() <= 0.0)
            return true;

        // GNOME and anything else GTK: "Reduce animation".
        QSettings gtk(cfg + QStringLiteral("/gtk-3.0/settings.ini"), QSettings::IniFormat);
        const QVariant anim = gtk.value(QStringLiteral("Settings/gtk-enable-animations"));
        if (anim.isValid() && !anim.toBool())
            return true;
    }
#endif
    return false;
}

Application::Application(QObject *parent) : QObject(parent) {
}

int Application::run(int argc, char **argv) {
    silenceLogsAndAlsa();

    QApplication::setApplicationName("Tidal Wave");
    // R1: the real version, so Settings and the About line cannot drift.
    QApplication::setApplicationVersion(QStringLiteral(TIDALWAVE_VERSION));
    QApplication::setOrganizationName("TidalWave");
    QApplication::setDesktopFileName("tidal-wave");

    // Prefs first: QSettings needs the names above, and the scene graph backend
    // below is chosen once, before any window exists, and never revisited.
    m_prefs = new Prefs(this);
    // Before the engine, so the tray menu and any startup error are already
    // translated. The engine is handed over below for live retranslation.
    m_i18n = new I18n(m_prefs, this);
    // Only reads QSettings here, so it needs nothing but the org/app names set
    // above. The network request waits until the engine has loaded, below.
    m_update = new UpdateCheck(this);

    // Someone debugging a graphics problem from the shell outranks the stored
    // setting, so an explicit backend in the environment is left alone.
    const bool backendForced = qEnvironmentVariableIsSet("QT_QUICK_BACKEND")
                            || qEnvironmentVariableIsSet("QSG_RHI_BACKEND");

    if (m_prefs->softwareRendering() && !backendForced) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    } else {
        // 4x multisampling is GPU work, so it is pointless once the raster
        // backend is drawing.
        QSurfaceFormat format;
        format.setSamples(4);
        QSurfaceFormat::setDefaultFormat(format);
    }

    // Read once: the desktop's animation setting is not something that has to
    // be followed live, and a binding that changes mid-slide is worse than one
    // that does not.
    m_reducedMotion = detectReducedMotion();

    QApplication::setQuitOnLastWindowClosed(false);
    const QIcon appIcon = loadAppIcon();
    QApplication::setWindowIcon(appIcon);

    // Single-instance check
    QString socketName = QStringLiteral("TidalWaveSingleInstanceSocket");
    QLocalSocket socket;
    socket.connectToServer(socketName);
    if (socket.waitForConnected(500)) {
        socket.write("show");
        socket.waitForBytesWritten(500);
        return 0; // exit since an instance is already running
    }

    QLocalServer *server = new QLocalServer(QCoreApplication::instance());
    QLocalServer::removeServer(socketName);
    if (server->listen(socketName)) {
        connect(server, &QLocalServer::newConnection, this, [this, server]() {
            QLocalSocket *clientSocket = server->nextPendingConnection();
            connect(clientSocket, &QLocalSocket::readyRead, this, [this, clientSocket]() {
                QByteArray data = clientSocket->readAll();
                if (data == "show") {
                    this->showWindow();
                }
                clientSocket->disconnectFromServer();
            });
        });
    }

    QFont defaultFont("Inter");
    defaultFont.setFamilies({"Inter", "DejaVu Sans", "sans-serif"});
    QApplication::setFont(defaultFont);
    // QQuickStyle::setStyle("Basic");

    m_api    = new TidalApi(this);
    m_auth   = new Auth(m_api, this);
    m_client = new TidalClient(m_api, this);
    m_bridge = new TidalBridge(m_client, this);
    m_player = new Player(m_client, this);
    // Follows the system default output live, or the device chosen in Settings.
    m_player->setPrefs(m_prefs);
    m_downloader = new Downloader(m_client, this);
    // The sidebar's model and the pins it orders itself by. LibraryIndex asks
    // PinStore where each row belongs, so the store is built first.
    m_pins    = new PinStore(this);
    m_library = new LibraryIndex(m_client, m_pins, this);
#ifdef Q_OS_LINUX
    // Chromecast output relies on Avahi (Linux mDNS); build/enable only there.
    m_cast = new CastManager(m_client, m_player, this);
#endif
#ifdef Q_OS_LINUX
    // MPRIS is a Linux/D-Bus-only desktop-integration protocol. There's no
    // session bus on Windows/macOS, so constructing it there is dead init.
    m_mpris  = new MprisManager(m_player, this);
#endif

    connect(m_auth, &Auth::loginSucceeded, this, [this]() {
        m_client->setUserId(m_auth->userId());
        // Pins are stored per account and the library is that account's
        // library, so both have to know who signed in before the first page is
        // fetched.
        m_pins->setUserId(m_auth->userId());
        m_library->setUserId(m_auth->userId());
        m_library->refresh();
    });

    connect(m_auth, &Auth::stateChanged, this, [this](Auth::State s) {
        // Stop the background tracklist index where it stands rather than let
        // it keep running against an account that just signed out. It resumes
        // from the disk cache on the next sign-in.
        if (s == Auth::State::LoggedOut)
            m_library->cancelIndexing();
    });

    m_auth->loadCredentials();

    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon = new QSystemTrayIcon(appIcon, this);
        m_trayIcon->setToolTip(QStringLiteral("Tidal Wave"));

        QMenu *trayMenu = new QMenu();
        QAction *showAction = trayMenu->addAction(tr("Show"));
        connect(showAction, &QAction::triggered, this, &Application::showWindow);

        QAction *hideAction = trayMenu->addAction(tr("Hide"));
        connect(hideAction, &QAction::triggered, this, &Application::hideWindow);

        trayMenu->addSeparator();

        QAction *quitAction = trayMenu->addAction(tr("Quit"));
        connect(quitAction, &QAction::triggered, this, &Application::quit);

        m_trayIcon->setContextMenu(trayMenu);

        connect(m_trayIcon, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
            if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
                this->toggleWindow();
            }
        });

        m_trayIcon->show();
    }

    m_engine = new QQmlApplicationEngine(this);
    m_i18n->setEngine(m_engine);
    m_engine->addImageProvider(QStringLiteral("tidal"), new TidalImageProvider());

    // The palette singleton is created by the engine, so it has to know about
    // Prefs before the first QML file binds Theme.*.
    ThemePalette::instance()->setPrefs(m_prefs);

    QQmlContext *ctx = m_engine->rootContext();
    ctx->setContextProperty(QStringLiteral("prefs"),  m_prefs);
    ctx->setContextProperty(QStringLiteral("i18n"),   m_i18n);
    ctx->setContextProperty(QStringLiteral("auth"),   m_auth);
    ctx->setContextProperty(QStringLiteral("bridge"), m_bridge);
    ctx->setContextProperty(QStringLiteral("player"), m_player);
    ctx->setContextProperty(QStringLiteral("downloader"), m_downloader);
    ctx->setContextProperty(QStringLiteral("pins"),    m_pins);
    ctx->setContextProperty(QStringLiteral("library"), m_library);
    // `cast` is Linux-only; register it as null elsewhere (m_cast is an
    // incomplete type off-Linux since CastManager.h isn't included there).
    QObject *castObj = nullptr;
#ifdef Q_OS_LINUX
    castObj = m_cast;
#endif
    ctx->setContextProperty(QStringLiteral("cast"), castObj);
    ctx->setContextProperty(QStringLiteral("app"),    this);
    // Not "update": QQuickItem and QQuickWindow both have an update() slot,
    // and an unqualified name in QML finds the enclosing objects before it
    // reaches the context. Under the ApplicationWindow - which is every
    // object in the app - a bare `update` is that slot, so the context
    // property would be shadowed everywhere and silently read as undefined.
    ctx->setContextProperty(QStringLiteral("updateCheck"), m_update);

    m_engine->loadFromModule("TidalWave", "Main");
    if (m_engine->rootObjects().isEmpty()) return -1;

    // After the engine, so the GitHub request is never in front of the first
    // frame. It throttles itself to once a day, is asynchronous, and fails
    // silently, so there is nothing here to guard. Whatever it learns is for
    // the next launch: the prompt Main.qml just decided on read the cache.
    m_update->startupCheck();

    return QApplication::exec();
}



void Application::quit() {
    m_reallyQuit = true;
    emit reallyQuitChanged();
    QCoreApplication::quit();
}

void Application::openUrl(const QString &url) {
    if (url.isEmpty()) return;
#if defined(Q_OS_LINUX)
    // On Linux/Wayland with Qt 6.12, QDesktopServices::openUrl triggers a use-after-free
    // crash in QDesktopUnixServices::openUrl due to an asynchronous xdgActivationTokenCreated
    // callback accessing a destroyed stack frame. Using xdg-open directly avoids this completely.
    if (QProcess::startDetached(QStringLiteral("xdg-open"), { url })) {
        return;
    }
#endif
    QDesktopServices::openUrl(QUrl(url));
}

void Application::showWindow() {
    if (m_engine) {
        const auto rootObjs = m_engine->rootObjects();
        if (!rootObjs.isEmpty()) {
            QWindow *window = qobject_cast<QWindow*>(rootObjs.first());
            if (window) {
                window->show();
                window->raise();
                window->requestActivate();
            }
        }
    }
}

void Application::hideWindow() {
    if (m_engine) {
        const auto rootObjs = m_engine->rootObjects();
        if (!rootObjs.isEmpty()) {
            QWindow *window = qobject_cast<QWindow*>(rootObjs.first());
            if (window) {
                window->hide();
            }
        }
    }
}

void Application::toggleWindow() {
    if (m_engine) {
        const auto rootObjs = m_engine->rootObjects();
        if (!rootObjs.isEmpty()) {
            QWindow *window = qobject_cast<QWindow*>(rootObjs.first());
            if (window) {
                if (window->isVisible() && window->windowState() != Qt::WindowMinimized) {
                    window->hide();
                } else {
                    window->show();
                    window->raise();
                    window->requestActivate();
                }
            }
        }
    }
}
