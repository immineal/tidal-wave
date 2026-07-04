#include "Application.h"
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
#include <QStandardPaths>
#include <QSurfaceFormat>
#include <QLoggingCategory>
#include <QLibrary>
#include <QLocalServer>
#include <QLocalSocket>
#include <QWindow>
#include <QMenu>
#include <QAction>
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

Application::Application(QObject *parent) : QObject(parent) {
}

int Application::run(int argc, char **argv) {
    silenceLogsAndAlsa();

    QApplication::setApplicationName("Tidal Wave");
    QApplication::setApplicationVersion("0.3.0");
    QApplication::setOrganizationName("TidalWave");
    QApplication::setDesktopFileName("tidal-wave");

    QSurfaceFormat format;
    format.setSamples(4);
    QSurfaceFormat::setDefaultFormat(format);

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
    m_downloader = new Downloader(m_client, this);
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
    });

    m_auth->loadCredentials();

    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon = new QSystemTrayIcon(appIcon, this);
        m_trayIcon->setToolTip(QStringLiteral("Tidal Wave"));

        QMenu *trayMenu = new QMenu();
        QAction *showAction = trayMenu->addAction(QStringLiteral("Show"));
        connect(showAction, &QAction::triggered, this, &Application::showWindow);

        QAction *hideAction = trayMenu->addAction(QStringLiteral("Hide"));
        connect(hideAction, &QAction::triggered, this, &Application::hideWindow);

        trayMenu->addSeparator();

        QAction *quitAction = trayMenu->addAction(QStringLiteral("Quit"));
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
    m_engine->addImageProvider(QStringLiteral("tidal"), new TidalImageProvider());

    QQmlContext *ctx = m_engine->rootContext();
    ctx->setContextProperty(QStringLiteral("auth"),   m_auth);
    ctx->setContextProperty(QStringLiteral("bridge"), m_bridge);
    ctx->setContextProperty(QStringLiteral("player"), m_player);
    ctx->setContextProperty(QStringLiteral("downloader"), m_downloader);
    // `cast` is Linux-only; register it as null elsewhere (m_cast is an
    // incomplete type off-Linux since CastManager.h isn't included there).
    QObject *castObj = nullptr;
#ifdef Q_OS_LINUX
    castObj = m_cast;
#endif
    ctx->setContextProperty(QStringLiteral("cast"), castObj);
    ctx->setContextProperty(QStringLiteral("app"),    this);

    m_engine->loadFromModule("TidalWave", "Main");
    if (m_engine->rootObjects().isEmpty()) return -1;

    return QApplication::exec();
}



void Application::quit() {
    m_reallyQuit = true;
    emit reallyQuitChanged();
    QCoreApplication::quit();
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
