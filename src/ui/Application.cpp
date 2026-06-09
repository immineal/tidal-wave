#include "Application.h"
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDateTime>
#include <QFont>
#include <QIcon>
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

    // Silence ALSA stderr warnings/errors (e.g. spaVisitChoice: parse error)
    silenceAlsa();
}

Application::Application(QObject *parent) : QObject(parent) {
}

int Application::run(int argc, char **argv) {
    silenceLogsAndAlsa();

    QApplication::setApplicationName("Tidal Wave");
    QApplication::setApplicationVersion("0.2.1-beta");
    QApplication::setOrganizationName("TidalWave");
    QApplication::setDesktopFileName("tidal-wave");

    QSurfaceFormat format;
    format.setSamples(4);
    QSurfaceFormat::setDefaultFormat(format);

    QApplication::setQuitOnLastWindowClosed(false);
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/TidalWave/assets/icon.png")));

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
    m_mpris  = new MprisManager(m_player, this);

    connect(m_auth, &Auth::loginSucceeded, this, [this]() {
        m_client->setUserId(m_auth->userId());
    });

    m_auth->loadCredentials();

    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon = new QSystemTrayIcon(QIcon(QStringLiteral(":/TidalWave/assets/icon.png")), this);
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
    ctx->setContextProperty(QStringLiteral("app"),    this);

    m_engine->load(QUrl(QStringLiteral("qrc:/TidalWave/qml/main.qml")));
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
