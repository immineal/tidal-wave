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
#include <QFile>
#include <QDir>
#include <QSettings>
#include <QStandardPaths>
#include <QSurfaceFormat>
#include <QFileInfo>
#include <QNetworkProxyFactory>
#include <QDebug>
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

#if defined(Q_OS_UNIX)
#include <unistd.h>   // getuid(), for the per-user socket name
#endif
#ifdef Q_OS_LINUX
#include <QDBusConnection>
#include <QDBusServiceWatcher>
#endif

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
// Decided once in silenceLogsAndAlsa(); see audioServerAbsent() for the rule.
static bool suppressAudioServerNoise = false;

// Whether this machine is offering no audio server at all.
//
// The two connect errors below are only noise when there is nothing to connect
// to. Someone who is running PipeWire or PulseAudio and still cannot reach it
// has a real fault, and the one line saying so is the only clue they get, so
// that case is left alone and only a machine with no server anywhere goes
// quiet. Env first: being pointed at a server explicitly counts as having one.
static bool audioServerAbsent() {
#if defined(Q_OS_LINUX)
    if (qEnvironmentVariableIsSet("PULSE_SERVER") || qEnvironmentVariableIsSet("PIPEWIRE_REMOTE"))
        return false;
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        return false;  // nothing to go on, so assume there is a server and keep the log
    return !QFile::exists(runtime + QStringLiteral("/pipewire-0"))
        && !QFile::exists(runtime + QStringLiteral("/pulse/native"));
#else
    // Neither server exists on Windows or macOS, so nothing to suppress.
    return false;
#endif
}

static void myMessageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg) {
    if (msg.contains(QStringLiteral("spaVisitChoice"))) {
        return; // Ignore and silence this log message completely
    }
    if (suppressAudioServerNoise && Application::isAudioServerStartupNoise(msg)) {
        return;
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

    // The PipeWire and PulseAudio connect errors escape that rule, so they get
    // their own gate in the handler below. Sampled here, before anything has
    // had a chance to start an audio server, which is also when the answer is
    // cheapest to get.
    suppressAudioServerNoise = audioServerAbsent();

    // Intercept and filter out "spaVisitChoice" log messages
    originalMessageHandler = qInstallMessageHandler(myMessageHandler);

    // Silence ALSA stderr warnings/errors (e.g. spaVisitChoice: parse error).
    // ALSA is Linux-only; the dlopen is a no-op elsewhere but skip it for clarity.
#ifdef Q_OS_LINUX
    silenceAlsa();
#endif
}

// Locates one of the bundled icon files in the Qt resource system.
//
// The QML module's RESOURCES prefix moved from ":/TidalWave/..." to
// ":/qt/qml/TidalWave/..." when QTP0001 was set to NEW (commit 749527a). A
// hardcoded single path silently broke the tray icon when that happened, so we
// probe both prefixes and return whichever actually exists - future policy
// churn can't blank the tray again.
static QString appIconResourcePath(const QString &fileName) {
    const QStringList candidates = {
        QStringLiteral(":/qt/qml/TidalWave/assets/") + fileName,
        QStringLiteral(":/TidalWave/assets/") + fileName,
    };
    for (const QString &p : candidates) {
        if (QFile::exists(p))
            return p;
    }
    return candidates.first();
}

// Copies the bundled icon into the user's hicolor theme, so an app started
// straight out of a build tree still has a named icon to hand the tray.
//
// This only ever runs when the theme has no "tidal-wave" in it, which is the
// important part. It used to run on every single launch and rescale the
// embedded PNG over whatever `cmake --install` had written, so one stale binary
// left in ~/.local/bin would stamp old artwork back over a freshly installed
// icon on every start. That is the loop the old logo kept coming back through,
// and why fixing the asset alone never stuck. An installed icon now wins.
//
// The files are copied, never rescaled: the SVG is what the desktop should
// render at an arbitrary size, and a raster upscaled from the 128 (the old code
// wrote a 256 that way) is worse than letting it do that, while still being
// preferred over the SVG by the icon lookup.
static void exportIconToUserTheme(const QString &iconName) {
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
                         + QStringLiteral("/icons/hicolor");
    struct Copy { const char *resource; const char *themeDir; const char *suffix; };
    static constexpr Copy copies[] = {
        { "icon.svg", "scalable", "svg" },
        { "icon.png", "128x128",  "png" },
    };

    bool wrote = false;
    for (const Copy &c : copies) {
        const QString res = appIconResourcePath(QString::fromLatin1(c.resource));
        if (!QFile::exists(res))
            continue;
        const QString dir = QStringLiteral("%1/%2/apps").arg(base, QString::fromLatin1(c.themeDir));
        if (!QDir().mkpath(dir))
            continue;
        const QString path = QStringLiteral("%1/%2.%3")
                                 .arg(dir, iconName, QString::fromLatin1(c.suffix));
        // QFile::copy refuses to overwrite, and a half-written file from a
        // previous run would otherwise be kept for ever.
        QFile::remove(path);
        if (QFile::copy(res, path)) {
            QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ReadGroup | QFileDevice::ReadOther);
            wrote = true;
        }
    }

    // Force Qt's icon-theme loader to re-scan, so the file just written is
    // found on this launch rather than the next one; the index it built a
    // moment ago does not have it.
    if (wrote && !QIcon::themeName().isEmpty())
        QIcon::setThemeName(QIcon::themeName());
}

// Returns the application icon as a *named* theme icon ("tidal-wave").
//
// KDE Plasma's system tray uses the StatusNotifierItem (SNI) protocol. A tray
// icon supplied only as a serialized pixmap (what you get from QIcon(":/...png"))
// frequently renders blank on Plasma 6, even though the same QIcon works fine for
// the window/taskbar icon (those go through X11's native _NET_WM_ICON). SNI hosts
// render reliably when the icon is referenced by NAME and resolved from the icon
// theme. So the icon has to be in the theme, and the tray has to be handed a
// named icon rather than a pixmap. Normally `cmake --install` puts it there (see
// the hicolor install rules in CMakeLists.txt); exportIconToUserTheme() is the
// fallback for when nobody has.
static QIcon loadAppIcon() {
    const QString iconName = QStringLiteral("tidal-wave");
    if (!QIcon::hasThemeIcon(iconName))
        exportIconToUserTheme(iconName);
    // Named themed icon (so SNI sends IconName), with the embedded pixmap as a
    // fallback for non-KDE trays / if theme lookup fails.
    return QIcon::fromTheme(iconName,
                            QIcon(appIconResourcePath(QStringLiteral("icon.png"))));
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

#if defined(Q_OS_UNIX)
// A Unix socket address is a path in a fixed-size field: sockaddr_un::sun_path
// is 108 bytes including the terminator, and bind() refuses anything longer.
static constexpr int kUnixSocketPathMax = 107;

// Candidate directory for the socket: it has to exist and the finished path
// has to fit sun_path, measured in bytes, not characters.
static bool socketDirFits(const QString &dir, const QString &leaf) {
    if (dir.isEmpty())
        return false;
    const QString candidate = dir + QLatin1Char('/') + leaf;
    if (QFile::encodeName(candidate).size() > kUnixSocketPathMax)
        return false;
    return QFileInfo(dir).isDir();
}
#endif

// Where the single-instance rendezvous socket lives for this user.
//
// The old flat "TidalWaveSingleInstanceSocket" had two faults. It carried no
// uid, so two people signed into one machine fought over one file in a shared
// /tmp and the loser never got a window. And QLocalServer resolves a bare name
// against $TMPDIR, so a long enough $TMPDIR pushes the address past sun_path,
// bind() fails, and every launch from then on is a fresh instance.
//
// Hence the uid in the name, and on Unix an explicit directory: $XDG_RUNTIME_DIR
// first, which is per-user, mode 0700, short, and where runtime sockets belong;
// then the temp dir, honouring $TMPDIR the way the old code did; then /tmp,
// which always fits. The result is an absolute path, which QLocalServer and
// QLocalSocket both take as the address itself.
QString Application::singleInstanceSocketName() {
#if defined(Q_OS_UNIX)
    const QString leaf = QStringLiteral("TidalWave-%1").arg(static_cast<uint>(::getuid()));
    const QString candidates[] = {
        qEnvironmentVariable("XDG_RUNTIME_DIR"),
        QDir::cleanPath(QDir::tempPath()),
        QStringLiteral("/tmp"),
    };
    for (const QString &dir : candidates) {
        if (socketDirFits(dir, leaf))
            return dir + QLatin1Char('/') + leaf;
    }
    // Only reachable if even /tmp is missing. Hand back the shortest address
    // there is and let the caller report the failure.
    return QStringLiteral("/tmp/") + leaf;
#else
    // Windows named pipes are a flat namespace under \\.\pipe\ with no path
    // length worth guarding, but the namespace is machine-wide, so the name
    // still has to say who it belongs to.
    const QString name = qEnvironmentVariable("USERNAME");
    QString user;
    for (const QChar c : name) {
        if (c.isLetterOrNumber())
            user += c;
    }
    if (user.isEmpty())
        user = QStringLiteral("user");
    return QStringLiteral("TidalWave-") + user;
#endif
}

bool Application::claimSingleInstanceSocket(QLocalServer *server, const QString &socketName) {
    if (!server)
        return false;
    if (server->listen(socketName))
        return true;
    if (server->serverError() != QAbstractSocket::AddressInUseError)
        return false;

    // The address is taken. A socket file outlives the process that made it,
    // so after a crash or a kill -9 this fails on a machine where nothing is
    // listening at all, and the old blind removeServer() before listen() cured
    // that by being willing to evict a live instance too. Knock first instead:
    // only an address that refuses a connection is stale.
    QLocalSocket probe;
    probe.connectToServer(socketName);
    if (probe.waitForConnected(250)) {
        probe.abort();
        return false;
    }
    if (!QLocalServer::removeServer(socketName))
        return false;
    return server->listen(socketName);
}

bool Application::shouldQuitOnWindowClose(bool trayAvailable, bool quitOnClose) {
    // With a tray icon, closing the window hides it and the tray brings it
    // back. With no tray there is nothing to click and no way to quit short of
    // killing the process, so the close has to be a quit.
    //
    // The preference is the other way into the same answer, for the people who
    // read a close button on a Linux desktop as "quit" and were surprised to
    // find the app still running. It cannot turn the no-tray rule off, which is
    // why it is an or and not the whole condition.
    return !trayAvailable || quitOnClose;
}

bool Application::isAudioServerStartupNoise(const QString &msg) {
    // Both come out of libQt6Multimedia through qInfo()/qWarning() on the
    // *default* logging category, which is exactly why the qt.multimedia*=false
    // rule in silenceLogsAndAlsa() never touched them. Matched on the stable
    // half of each line; the reason ("Host is down") is appended by Qt.
    return msg.contains(QLatin1String("Failed to connect to pipewire instance"))
        || msg.contains(QLatin1String("pa_context_connect() failed"));
}

bool Application::reallyQuit() const {
    // Main.qml reads this in onClosing, imperatively, which is why the missing
    // notify on the tray half of the answer costs nothing, and merely hides
    // the window whenever it is false. That is right only while a tray icon can bring the window
    // back, so with no tray a close counts as a quit. Asked here, at the
    // moment of the close, rather than cached at startup: a StatusNotifier
    // host can appear or vanish long after login and Qt has no signal for it.
    // The preference is read at that same moment and for the same reason, so a
    // close right after the switch was flipped does what the switch says. Null
    // until run() builds it, and this is a property QML can reach, so the
    // dereference is guarded rather than assumed.
    return m_reallyQuit
        || shouldQuitOnWindowClose(QSystemTrayIcon::isSystemTrayAvailable(),
                                   m_prefs && m_prefs->quitOnClose());
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

    // Behind a corporate proxy every request used to hang with nothing said,
    // because Qt ignores the system proxy unless asked. This only flips a
    // switch; the configuration is read lazily, per query, so it costs nothing
    // here and has to be set before the first request goes out.
    //
    // What it does not cover: on Unix, Qt reads http_proxy/https_proxy/
    // all_proxy/no_proxy from the environment, and a PAC script or the
    // GNOME/KDE proxy dialogs only reach it when Qt was built against
    // libproxy. Windows and macOS read the real system settings, PAC included.
    // Nowhere does it cover a proxy that wants credentials, since the app has
    // no dialog to ask for them (credentials inside the proxy URL do work).
    // Nor does it cover playback: QMediaPlayer streams through the FFmpeg
    // backend, which does its own HTTP and never sees QNetworkProxy.
    QNetworkProxyFactory::setUseSystemConfiguration(true);

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

    // Left off, always: Qt samples this flag when the last window goes and
    // cannot be asked to reconsider, while whether a close should quit depends
    // on a tray that may not exist yet. So the decision is made per close, in
    // reallyQuit() and in the lastWindowClosed handler further down.
    QApplication::setQuitOnLastWindowClosed(false);
    const QIcon appIcon = loadAppIcon();
    QApplication::setWindowIcon(appIcon);

    // Single-instance check
    const QString socketName = singleInstanceSocketName();
    QLocalSocket socket;
    socket.connectToServer(socketName);
    if (socket.waitForConnected(500)) {
        socket.write("show");
        socket.waitForBytesWritten(500);
        return 0; // exit since an instance is already running
    }

    QLocalServer *server = new QLocalServer(QCoreApplication::instance());
    if (claimSingleInstanceSocket(server, socketName)) {
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
    } else {
        // Carry on deliberately. Single instance is a convenience, not a
        // requirement: without the lock the app still works, it just stops
        // handing a second launch to the first window. Refusing to start over
        // a socket would turn a cosmetic problem into "it does not launch".
        // What is not acceptable is the silence the old code had, where it
        // ignored listen()'s return value and an address too long for sun_path
        // turned every launch into a new copy with nothing on stderr to say so.
        qWarning().noquote()
            << QStringLiteral("tidal-wave: no single-instance lock at %1 (%2). "
                              "Another launch will open a second window.")
                   .arg(socketName, server->errorString());
        server->deleteLater();
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

    if (QSystemTrayIcon::isSystemTrayAvailable())
        createTrayIcon(appIcon);

#ifdef Q_OS_LINUX
    // A tray that is not there yet. On Plasma, or any session whose bar starts
    // after the autostarted app, the StatusNotifier host registers seconds or
    // minutes late, and the old code sampled availability once and gave up for
    // the rest of the session. Qt has no signal for it, and it picks the tray
    // backend when QSystemTrayIcon is constructed, so an icon built before the
    // host exists stays inert for good and has to be built again afterwards.
    // Watching the bus name is what is left. Constructing it unconditionally
    // instead is not: on a platform with no native tray at all (Wayland with
    // no host, offscreen) Qt falls back to its X11 implementation and warns
    // about a signal the plugin does not have, on every launch.
    auto *trayWatcher = new QDBusServiceWatcher(QStringLiteral("org.kde.StatusNotifierWatcher"),
                                                QDBusConnection::sessionBus(),
                                                QDBusServiceWatcher::WatchForRegistration, this);
    connect(trayWatcher, &QDBusServiceWatcher::serviceRegistered, this, [this, appIcon]() {
        if (!m_trayIcon && QSystemTrayIcon::isSystemTrayAvailable())
            createTrayIcon(appIcon);
    });
#endif

    // The other half of the no-tray case, and what keeps the app from being
    // stranded while the paragraph above is still waiting. reallyQuit() makes
    // Main.qml accept the close instead of hiding it, and this ends the
    // process once that window is gone. Both ask about the tray at that
    // moment, so a host that turned up, or died, since startup gets the right
    // answer. Qt emits this signal whatever quitOnLastWindowClosed is set to,
    // which is why that flag can stay off.
    connect(qApp, &QGuiApplication::lastWindowClosed, this, [this]() {
        if (shouldQuitOnWindowClose(QSystemTrayIcon::isSystemTrayAvailable(),
                                    m_prefs->quitOnClose()))
            quit();
    });

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

    // loadFromModule() is the right call - it asks the module for its root
    // component instead of naming a resource path - but it only arrived in Qt
    // 6.5, and a build on Debian bookworm's Qt 6.4.2 got to 143 of 149 objects
    // before stopping on exactly this line. The URL below is the same component
    // reached the long way round. The prefix is the one CMakeLists.txt now pins
    // with RESOURCE_PREFIX so that it is the same on every Qt - see the comment
    // there, and note that getting this prefix wrong does not fail loudly: the
    // import resolves nothing, every type reports "is not a type", and the line
    // below this one returns -1 with no window and no message. The file keeps
    // the "qml/" of its path in the source tree (the generated qmldir maps Main
    // to qml/Main.qml).
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    m_engine->loadFromModule("TidalWave", "Main");
#else
    m_engine->load(QUrl(QStringLiteral("qrc:/qt/qml/TidalWave/qml/Main.qml")));
#endif
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

void Application::createTrayIcon(const QIcon &icon) {
    if (m_trayIcon)
        return;

    m_trayIcon = new QSystemTrayIcon(icon, this);
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
