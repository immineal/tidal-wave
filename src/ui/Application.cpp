// SPDX-License-Identifier: GPL-3.0-or-later

#include "Application.h"
#include "ui/SignalWatcher.h"
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
#include <QGuiApplication>
#include <QScreen>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDateTime>
#include <QFont>
#include <QFontDatabase>
#include <QIcon>
#include <QFile>
#include <QDir>
#include <QSettings>
#include <QStandardPaths>
#include <QStringList>
#include <QSurfaceFormat>
#include <QFileInfo>
#include <QNetworkProxyFactory>
#include <QDebug>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QLoggingCategory>
#include <QLibrary>

#include <algorithm>
#include <cmath>
#include <QLocalServer>
#include <QLocalSocket>
#include <QWindow>
#include <QMenu>
#include <QAction>
#include <QProcess>
#include <QDesktopServices>
#include <QEvent>
#include <QUrl>
#include <QQuickStyle>

#if defined(Q_OS_UNIX)
#include <unistd.h>   // getuid(), for the per-user socket name
#include <sys/un.h>   // sockaddr_un::sun_path, whose size is the real limit
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
// Set once in silenceLogsAndAlsa().
static bool suppressAudioServerNoise = false;

// True when no audio server is offered at all. A connect error on a machine
// that runs PipeWire or PulseAudio is a real fault and stays in the log.
// An explicit server in the environment counts as having one.
static bool audioServerAbsent() {
#if defined(Q_OS_LINUX)
    if (qEnvironmentVariableIsSet("PULSE_SERVER") || qEnvironmentVariableIsSet("PIPEWIRE_REMOTE"))
        return false;
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        return false;  // nothing to go on: assume a server and keep the log
    return !QFile::exists(runtime + QStringLiteral("/pipewire-0"))
        && !QFile::exists(runtime + QStringLiteral("/pulse/native"));
#else
    return false;
#endif
}

static void myMessageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg) {
    if (msg.contains(QStringLiteral("spaVisitChoice"))) {
        return;
    }
    if (suppressAudioServerNoise && Application::isAudioServerStartupNoise(msg)) {
        return;
    }
    if (Application::isMediaBackendStartupNoise(msg)) {
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
    QLoggingCategory::setFilterRules(QStringLiteral("qt.multimedia*=false"));

    // The PipeWire and PulseAudio connect errors escape that rule. Sampled
    // here, before anything can have started an audio server.
    suppressAudioServerNoise = audioServerAbsent();

    originalMessageHandler = qInstallMessageHandler(myMessageHandler);

#ifdef Q_OS_LINUX
    silenceAlsa();
#endif
}

// The QML module's resource prefix depends on CMake policy QTP0001, so both
// prefixes are probed.
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

#ifdef Q_OS_LINUX
// Copies the bundled icon into the user's hicolor theme so a run from a build
// tree has a named icon. Linux only: macOS has no XDG icon theme. Call it only
// when the theme lacks the icon, so an installed one is never overwritten.
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
        // QFile::copy refuses to overwrite.
        QFile::remove(path);
        if (QFile::copy(res, path)) {
            QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ReadGroup | QFileDevice::ReadOther);
            wrote = true;
        }
    }

    // Makes Qt's icon-theme loader re-scan, so the new file is found now.
    if (wrote && !QIcon::themeName().isEmpty())
        QIcon::setThemeName(QIcon::themeName());
}
#endif // Q_OS_LINUX

// The icon by theme name. A StatusNotifierItem tray (Plasma 6) can render a
// pixmap-only icon blank, so the tray needs a name the theme resolves.
static QIcon loadAppIcon() {
    const QString iconName = QStringLiteral("tidal-wave");
#ifdef Q_OS_LINUX
    if (!QIcon::hasThemeIcon(iconName))
        exportIconToUserTheme(iconName);
#endif
    // The embedded pixmap is the fallback when the theme lookup fails.
    return QIcon::fromTheme(iconName,
                            QIcon(appIconResourcePath(QStringLiteral("icon.png"))));
}

// Whether the desktop asks for less animation. Qt has no hint for this up to
// 6.12, so the KDE and GTK settings are read from their INI files. Windows and
// macOS are not read; the environment override works everywhere.
static bool detectReducedMotion() {
    const QByteArray forced = qgetenv("TIDALWAVE_REDUCED_MOTION");
    if (!forced.isEmpty())
        return forced != "0" && forced.compare("false", Qt::CaseInsensitive) != 0;

#if defined(Q_OS_UNIX) && !defined(Q_OS_MACOS)
    const QString cfg =
        QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (!cfg.isEmpty()) {
        // KDE: the animation speed slider at its slowest writes a factor of 0.
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
// The longest socket path QLocalServer will bind. Taken from the header since
// sun_path differs per platform (108 bytes on Linux, 104 on macOS). Minus two:
// QLocalServer::listen() fails one byte before a raw bind() does.
static constexpr int kUnixSocketPathMax = int(sizeof(sockaddr_un::sun_path)) - 2;

// The directory has to exist and the finished path has to fit sun_path,
// counted in bytes.
static bool socketDirFits(const QString &dir, const QString &leaf) {
    if (dir.isEmpty())
        return false;
    const QString candidate = dir + QLatin1Char('/') + leaf;
    if (QFile::encodeName(candidate).size() > kUnixSocketPathMax)
        return false;
    return QFileInfo(dir).isDir();
}
#endif

int Application::unixSocketPathMax() {
#if defined(Q_OS_UNIX)
    return kUnixSocketPathMax;
#else
    return 0;
#endif
}

// The uid is in the name so two users on one machine do not share a socket.
// An absolute path, since QLocalServer resolves a bare name against $TMPDIR,
// which can push the address past sun_path.
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
    // Only reachable if even /tmp is missing; the caller reports the failure.
    return QStringLiteral("/tmp/") + leaf;
#else
    // The Windows pipe namespace is machine-wide, so the name carries the user.
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

    // A socket file outlives a crashed process. Only an address that refuses
    // a connection is stale; removing it blindly would evict a live instance.
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
    // Without a tray a hidden window cannot be brought back, so the close has
    // to quit whatever the preference says.
    return !trayAvailable || quitOnClose;
}

bool Application::isAudioServerStartupNoise(const QString &msg) {
    // Qt Multimedia logs both on the default category, which no
    // qt.multimedia rule reaches. Qt appends the reason, so match the start.
    return msg.contains(QLatin1String("Failed to connect to pipewire instance"))
        || msg.contains(QLatin1String("pa_context_connect() failed"));
}

bool Application::isMediaBackendStartupNoise(const QString &msg) {
    // The Qt 6.4 FFmpeg plugin prints this on the default category, so no
    // category rule can silence it without silencing the app's own messages.
    return msg.startsWith(QLatin1String(">>>> listing codecs"));
}

double Application::snapScaleFactor(double factor) {
    if (!(factor > 0) || !std::isfinite(factor))
        return kMinScaleFactor;
    const double snapped = std::round(factor / kScaleFactorStep) * kScaleFactorStep;
    return std::clamp(snapped, kMinScaleFactor, kMaxScaleFactor);
}

double Application::scaleFactorCeilingFor(const ScreenMetrics &screen) {
    if (screen.widthPx <= 0 || screen.heightPx <= 0)
        return kMaxScaleFactor;
    // The window is sized in logical pixels: device pixels = logical * factor.
    const double byWidth  = (screen.widthPx  * kWindowFitFraction) / kDefaultWindowWidth;
    const double byHeight = (screen.heightPx * kWindowFitFraction) / kDefaultWindowHeight;
    const double fits = std::min(byWidth, byHeight);
    // Floor to the step: rounding up could make the window too large to fit.
    const double stepped = std::floor(fits / kScaleFactorStep) * kScaleFactorStep;
    return std::clamp(stepped, kMinScaleFactor, kMaxScaleFactor);
}

double Application::autoScaleFactor(const ScreenMetrics &screen) {
    // A platform that already scales (Wayland per-output, macOS) is left alone.
    if (screen.platformDpr > 0 && !qFuzzyCompare(screen.platformDpr, 1.0))
        return kMinScaleFactor;

    // Qt reports physicalDpi equal to logicalDpi when the platform gives it no
    // physical size, so equality means there is no density to derive from.
    if (!(screen.physicalDpi > 0) || !std::isfinite(screen.physicalDpi))
        return kMinScaleFactor;
    if (screen.logicalDpi > 0
        && qFuzzyCompare(screen.physicalDpi, screen.logicalDpi))
        return kMinScaleFactor;
    // A density no panel has means a made-up physical size (projector, KVM, VM).
    constexpr double kAbsurdDpi = 1000.0;
    if (screen.physicalDpi > kAbsurdDpi)
        return kMinScaleFactor;

    const double wanted = snapScaleFactor(screen.physicalDpi / kAutoTargetDpi);
    if (wanted < kAutoEngageAt)
        return kMinScaleFactor;
    return std::min(wanted, scaleFactorCeilingFor(screen));
}

double Application::resolveScaleFactor(const ScreenMetrics &screen, double userFactor) {
    // The fit ceiling applies to the user's factor too: a window larger than
    // the screen would put the slider that undoes it out of reach.
    if (userFactor > 0) {
        const double chosen = std::min(snapScaleFactor(userFactor),
                                       scaleFactorCeilingFor(screen));
        return qFuzzyCompare(chosen, 1.0) ? 0.0 : chosen;
    }
    const double automatic = autoScaleFactor(screen);
    // 1.0 is returned as 0, meaning leave Qt alone: pinning the factor to 1
    // would stop Qt following the screen.
    return qFuzzyCompare(automatic, 1.0) ? 0.0 : automatic;
}

bool Application::scaleFactorSetInEnvironment() {
    // Any of these outranks the stored setting and the automatic rule. The
    // last two name a rule and also change what Qt computes.
    for (const char *var : { "QT_SCALE_FACTOR",
                             "QT_SCREEN_SCALE_FACTORS",
                             "QT_ENABLE_HIGHDPI_SCALING",
                             "QT_FONT_DPI",
                             "QT_USE_PHYSICAL_DPI",
                             "QT_SCALE_FACTOR_ROUNDING_POLICY" }) {
        if (!qEnvironmentVariableIsEmpty(var))
            return true;
    }
    return false;
}

double Application::maxUsableScaleFactor() const {
    const QScreen *s = QGuiApplication::primaryScreen();
    if (!s)
        return kMaxScaleFactor;
    // geometry() is already divided by the factor in force, so multiply it
    // back out to get device pixels.
    const double dpr = s->devicePixelRatio() > 0 ? s->devicePixelRatio() : 1.0;
    ScreenMetrics m;
    m.widthPx  = int(s->geometry().width()  * dpr);
    m.heightPx = int(s->geometry().height() * dpr);
    return scaleFactorCeilingFor(m);
}

namespace {
// Set once by applyScaleFactor() before any other thread exists, then only
// read, so no lock.
Application::ScaleSource g_scaleSource = Application::ScaleSource::None;
double                   g_scaleFactor = 1.0;
}

Application::ScaleSource Application::appliedScaleSource() { return g_scaleSource; }
double Application::appliedScaleFactor() { return g_scaleFactor; }

bool Application::scaleIsEnvironmentOverridden() const {
    return g_scaleSource == ScaleSource::Environment;
}
bool Application::scaleWasChosenAutomatically() const {
    return g_scaleSource == ScaleSource::Automatic;
}
double Application::activeScaleFactor() const { return g_scaleFactor; }

void Application::applyScaleFactor() {
    if (scaleFactorSetInEnvironment()) {
        g_scaleSource = ScaleSource::Environment;
        return;
    }

    // QSettings needs these to find the file Prefs opens later. They are
    // statics and work before any QCoreApplication exists.
    QCoreApplication::setOrganizationName(QStringLiteral("TidalWave"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("tidalwave.com"));
    QCoreApplication::setApplicationName(QStringLiteral("Tidal Wave"));
    // Prefs is a QObject and does not exist yet, so read the key directly.
    // 0 and anything unparseable mean Auto.
    const double userFactor =
        QSettings().value(QStringLiteral("ui/scaleFactor"), 0.0).toDouble();

    // Qt reads the scale factor once, while the application object is built.
    // Measuring the screen needs a QGuiApplication, so a throwaway one
    // measures and is destroyed before the real one exists.
    ScreenMetrics screen;
    {
        int   probeArgc = 1;
        char  probeName[] = "tidal-wave";
        char *probeArgv[] = { probeName, nullptr };
        QGuiApplication probe(probeArgc, probeArgv);
        if (const QScreen *s = QGuiApplication::primaryScreen()) {
            screen.physicalDpi = s->physicalDotsPerInch();
            screen.logicalDpi  = s->logicalDotsPerInch();
            screen.platformDpr = s->devicePixelRatio();
            screen.widthPx     = s->geometry().width();
            screen.heightPx    = s->geometry().height();
        }
        // QT_SCALE_FACTOR is one number for the whole process, so with mixed
        // densities the primary screen decides.

        // The probe has no event loop, and work Qt queued on it (such as
        // enabling delivery on a session bus) would be discarded with it.
        QCoreApplication::sendPostedEvents();
    }
    if (screen.widthPx <= 0)
        return;

    const double factor = resolveScaleFactor(screen, userFactor);
    if (factor <= 0)
        return;

    // Automatic means the platform advertised nothing and the factor was
    // derived from the panel's density.
    g_scaleSource = (userFactor > 0) ? ScaleSource::User : ScaleSource::Automatic;
    g_scaleFactor = factor;

    qputenv("QT_SCALE_FACTOR", QByteArray::number(factor));
    // PassThrough so a fractional factor is used as chosen. It is not the
    // default on Windows.
    QGuiApplication::setHighDpiScaleFactorRoundingPolicy(
        Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);
}

QStringList Application::uiFontFamilies() {
    QStringList wanted{ QStringLiteral("Inter") };
#ifdef Q_OS_MACOS
    // The system UI font is looked up by role, since its family name changes.
    const QString systemUi = QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
    if (!systemUi.isEmpty())
        wanted << systemUi;
    // Present on every macOS, in case the database cannot resolve the above.
    wanted << QStringLiteral("Helvetica Neue");
#else
    wanted << QStringLiteral("DejaVu Sans");
#endif

    // No generic name here: "sans-serif" is not a family on macOS. The caller
    // sets it as a style hint.
    QStringList present;
    for (const QString &f : std::as_const(wanted)) {
        if (QFontDatabase::hasFamily(f))
            present << f;
    }
    // Never return an empty list: the system UI font is always a real family.
    if (present.isEmpty())
        present << QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
    return present;
}

void Application::applyQuickControlsStyle() {
    // Fusion is what Qt picks on Linux and what the visual baselines are drawn
    // against. Basic on Qt 6.4, where Fusion's Popup can hang in a polish loop.
    // Has to run before the first Controls type is created.
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    QQuickStyle::setStyle(QStringLiteral("Basic"));
#else
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
#endif
}

void Application::addEmbeddedQmlImportPath(QQmlEngine *engine) {
    if (!engine)
        return;
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // "qrc:/qt/qml" became a built-in import path in Qt 6.5. On 6.4 the
    // module's qmldir is not found without it and no QML type resolves.
    // On 6.5+ addImportPath() would only move it ahead of Qt's own modules.
    engine->addImportPath(QStringLiteral("qrc:/qt/qml"));
#endif
}

bool Application::reallyQuit() const {
    // Evaluated at the moment of the close: a tray host can appear or vanish
    // at any time and Qt has no signal for it. m_prefs is null until run()
    // builds it, and QML can read this before then.
    return m_reallyQuit
        || shouldQuitOnWindowClose(QSystemTrayIcon::isSystemTrayAvailable(),
                                   m_prefs && m_prefs->quitOnClose());
}

Application::Application(QObject *parent) : QObject(parent) {
}

int Application::run(int argc, char **argv) {
    silenceLogsAndAlsa();

    QApplication::setApplicationName("Tidal Wave");
    QApplication::setApplicationVersion(QStringLiteral(TIDALWAVE_VERSION));
    QApplication::setOrganizationName("TidalWave");
    // Only macOS reads this: QSettings builds the preferences domain from it.
    // It matches the bundle identifier in CMakeLists.txt.
    QApplication::setOrganizationDomain("tidalwave.com");
    // The basename of the installed .desktop entry, which is how the taskbar
    // finds the icon. Must equal the file in packaging/ and the metainfo
    // <launchable>. X11's WM_CLASS is not built from it.
    QApplication::setDesktopFileName("io.github.immineal.TidalWave");

    // Qt ignores the system proxy by default. Has to be set before the first
    // request. Playback is not covered: the FFmpeg backend does its own HTTP
    // and never sees QNetworkProxy.
    QNetworkProxyFactory::setUseSystemConfiguration(true);

    // Before anything that owns a temp file or unsaved state exists, so a
    // SIGTERM from a logout mid-startup is still a clean quit.
    if (!installSignalHandlers()) {
#if defined(Q_OS_UNIX)
        // On Windows this is false by design, so warn on Unix only.
        qWarning().noquote()
            << QStringLiteral("tidal-wave: could not install signal handlers; "
                              "a logout or shutdown will not save the session.");
#endif
    }

    // Prefs first: QSettings needs the names above, and the scene graph backend
    // below is chosen once, before any window exists.
    m_prefs = new Prefs(this);
    // Before the engine, so the tray menu and any startup error are translated.
    m_i18n = new I18n(m_prefs, this);
    m_update = new UpdateCheck(this);

    // An explicit backend in the environment outranks the stored setting.
    const bool backendForced = qEnvironmentVariableIsSet("QT_QUICK_BACKEND")
                            || qEnvironmentVariableIsSet("QSG_RHI_BACKEND");

    if (m_prefs->softwareRendering() && !backendForced) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    } else {
        // Multisampling is GPU work, pointless under the raster backend.
        QSurfaceFormat format;
        format.setSamples(4);
        QSurfaceFormat::setDefaultFormat(format);
    }

    // Read once at startup.
    m_reducedMotion = detectReducedMotion();

    // Always off: whether a close quits depends on a tray that may not exist
    // yet, so reallyQuit() and lastWindowClosed answer it per close.
    QApplication::setQuitOnLastWindowClosed(false);
    const QIcon appIcon = loadAppIcon();
    QApplication::setWindowIcon(appIcon);

    const QString socketName = singleInstanceSocketName();
    QLocalSocket socket;
    socket.connectToServer(socketName);
    if (socket.waitForConnected(500)) {
        socket.write("show");
        socket.waitForBytesWritten(500);
        return 0; // an instance is already running
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
        // Carry on without the lock: the app still works, a second launch
        // just opens a second window. Say so on stderr.
        qWarning().noquote()
            << QStringLiteral("tidal-wave: no single-instance lock at %1 (%2). "
                              "Another launch will open a second window.")
                   .arg(socketName, server->errorString());
        server->deleteLater();
    }

    // The generic family goes in as a style hint. As a family name it is
    // missing on macOS, and Qt then builds its alias table and warns.
    const QStringList families = uiFontFamilies();
    QFont defaultFont(families.first());
    defaultFont.setFamilies(families);
    defaultFont.setStyleHint(QFont::SansSerif);
    QApplication::setFont(defaultFont);

    // The native styles (the macOS default) ignore a control's custom
    // indicator, contentItem and background, so a non-native style is set.
    // Has to happen before the first Controls type is loaded.
    applyQuickControlsStyle();

    m_api    = new TidalApi(this);
    m_auth   = new Auth(m_api, this);
    m_client = new TidalClient(m_api, this);
    m_bridge = new TidalBridge(m_client, this);
    m_player = new Player(m_client, this);
    m_player->setPrefs(m_prefs);
    m_downloader = new Downloader(m_client, this);
    // LibraryIndex asks PinStore where each row belongs, so the store is
    // built first.
    m_pins    = new PinStore(this);
    // Has to be set before any setUserId(), which runs the default pin.
    m_pins->setMixSource([client = m_client](PinStore::MixesHandler done) {
        client->fetchHomeMixes(std::move(done));
    });
    m_library = new LibraryIndex(m_client, m_pins, this);
    // The sidebar keeps its own copy of the library, separate from the
    // bridge's favourites cache, so each change is handed across by row.
    connect(m_bridge, &TidalBridge::favoriteAlbumAdded,  m_library, &LibraryIndex::addAlbum);
    connect(m_bridge, &TidalBridge::favoriteArtistAdded, m_library, &LibraryIndex::addArtist);
    connect(m_bridge, &TidalBridge::favoriteTrackAdded,  m_library, &LibraryIndex::addTrack);
    connect(m_bridge, &TidalBridge::favoriteMixAdded,    m_library, &LibraryIndex::addMix);
    connect(m_bridge, &TidalBridge::favoriteRemoved,     m_library, &LibraryIndex::removeEntry);
    connect(m_bridge, &TidalBridge::playlistCreated,     m_library, &LibraryIndex::addPlaylist);
    // Not through addPlaylist: that stamps addedAt and would lift a renamed
    // playlist to the top of the sidebar.
    connect(m_bridge, &TidalBridge::playlistUpdated,     m_library, &LibraryIndex::updatePlaylist);
    // Not through updatePlaylist: it returns early when title and description
    // match, which they do after a track add, and the count would be lost.
    connect(m_bridge, &TidalBridge::playlistStatsChanged, m_library,
            &LibraryIndex::refreshPlaylistMeta);
#ifdef Q_OS_LINUX
    // Chromecast discovery relies on Avahi, so Linux only.
    m_cast = new CastManager(m_client, m_player, this);
#endif
#ifdef Q_OS_LINUX
    // MPRIS needs a D-Bus session bus, so Linux only.
    m_mpris  = new MprisManager(m_player, this);
#endif

    connect(m_auth, &Auth::loginSucceeded, this, [this]() {
        m_client->setUserId(m_auth->userId());
        // Pins and library are per account: set the user before the first
        // page is fetched.
        m_pins->setUserId(m_auth->userId());
        m_library->setUserId(m_auth->userId());
        m_library->refresh();
    });

    connect(m_auth, &Auth::stateChanged, this, [this](Auth::State s) {
        // Do not keep indexing against an account that just signed out.
        if (s == Auth::State::LoggedOut)
            m_library->cancelIndexing();
    });

    m_auth->loadCredentials();

    if (QSystemTrayIcon::isSystemTrayAvailable())
        createTrayIcon(appIcon);

#ifdef Q_OS_MACOS
    // A Dock click is the way back from a hidden window; see eventFilter().
    qApp->installEventFilter(this);
#endif

#ifdef Q_OS_LINUX
    // The StatusNotifier host can register long after an autostarted app. Qt
    // has no signal for it and picks the tray backend when QSystemTrayIcon is
    // constructed, so the icon is built once the bus name appears.
    auto *trayWatcher = new QDBusServiceWatcher(QStringLiteral("org.kde.StatusNotifierWatcher"),
                                                QDBusConnection::sessionBus(),
                                                QDBusServiceWatcher::WatchForRegistration, this);
    connect(trayWatcher, &QDBusServiceWatcher::serviceRegistered, this, [this, appIcon]() {
        if (!m_trayIcon && QSystemTrayIcon::isSystemTrayAvailable())
            createTrayIcon(appIcon);
    });
#endif

    // Ends the process once a close was accepted with no tray. Qt emits this
    // signal whatever quitOnLastWindowClosed is set to.
    connect(qApp, &QGuiApplication::lastWindowClosed, this, [this]() {
        if (shouldQuitOnWindowClose(QSystemTrayIcon::isSystemTrayAvailable(),
                                    m_prefs->quitOnClose()))
            quit();
    });

    m_engine = new QQmlApplicationEngine(this);
    // Before anything is loaded; Qt 6.4 needs it to find the module.
    addEmbeddedQmlImportPath(m_engine);
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
    // Null off Linux, where CastManager is an incomplete type.
    QObject *castObj = nullptr;
#ifdef Q_OS_LINUX
    castObj = m_cast;
#endif
    ctx->setContextProperty(QStringLiteral("cast"), castObj);
    ctx->setContextProperty(QStringLiteral("app"),    this);
    // Not "update": QQuickItem and QQuickWindow have an update() slot, which
    // an unqualified name in QML finds before the context property.
    ctx->setContextProperty(QStringLiteral("updateCheck"), m_update);

    // loadFromModule() arrived in Qt 6.5. The URL is the same component; its
    // prefix has to match RESOURCE_PREFIX in CMakeLists.txt, and a wrong one
    // fails with no message.
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    m_engine->loadFromModule("TidalWave", "Main");
#else
    m_engine->load(QUrl(QStringLiteral("qrc:/qt/qml/TidalWave/qml/Main.qml")));
#endif
    if (m_engine->rootObjects().isEmpty()) return -1;

    // After the engine, so the request is never ahead of the first frame.
    m_update->startupCheck();

    return QApplication::exec();
}



bool Application::installSignalHandlers() {
    if (!m_signals) m_signals = new SignalWatcher(this);
    // Through quit(), so reallyQuit() is true as for the tray's Quit item.
    connect(m_signals, &SignalWatcher::quitRequested,
            this, &Application::quit, Qt::UniqueConnection);
    return m_signals->install();
}

void Application::quit() {
    m_reallyQuit = true;
    emit reallyQuitChanged();
    QCoreApplication::quit();
}

void Application::openUrl(const QString &url) {
    if (url.isEmpty()) return;
#if defined(Q_OS_LINUX)
    // On Wayland with Qt 6.12, QDesktopServices::openUrl can crash with a
    // use-after-free in its activation-token callback. xdg-open avoids it.
    if (QProcess::startDetached(QStringLiteral("xdg-open"), { url })) {
        return;
    }
#endif
    QDesktopServices::openUrl(QUrl(url));
}

void Application::createTrayIcon(const QIcon &icon) {
    if (m_trayIcon)
        return;

    QIcon trayArt = icon;
#ifdef Q_OS_MACOS
    // A mask makes Qt hand AppKit a template image, drawn in the menu bar's
    // own colour. macOS only: a Linux tray expects the coloured icon.
    trayArt.setIsMask(true);
#endif

    m_trayIcon = new QSystemTrayIcon(trayArt, this);
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

#ifdef Q_OS_MACOS
bool Application::hasVisibleWindow() const {
    if (!m_engine)
        return false;
    const auto rootObjs = m_engine->rootObjects();
    for (QObject *obj : rootObjs) {
        if (auto *window = qobject_cast<QWindow *>(obj)) {
            if (window->isVisible())
                return true;
        }
    }
    return false;
}

// Shows the window again on a Dock click. Qt reports the reopen as an
// activation and sends it only to the QApplication object, so this is a
// filter on qApp and not an override of event().
bool Application::eventFilter(QObject *watched, QEvent *event) {
    const bool becameActive =
        event->type() == QEvent::ApplicationActivate
        || (event->type() == QEvent::ApplicationStateChange
            && QGuiApplication::applicationState() == Qt::ApplicationActive);

    // Only when nothing is visible: Command-Tab to a window that is already
    // up is an activation too.
    if (watched == qApp && becameActive && !hasVisibleWindow())
        showWindow();

    return QObject::eventFilter(watched, event);
}
#endif // Q_OS_MACOS

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
