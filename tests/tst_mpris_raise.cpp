// Raise over MPRIS brings the window back. The child is this binary re-executed
// with --child: it starts the program as main() does, offscreen, with a home
// and a runtime directory of its own, on a bus that only this test uses.

#include <QApplication>
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSettings>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QWindow>

#include <csignal>
#include <memory>
#include <unistd.h>

#include "ui/Application.h"

namespace {

const char kChildFlag[] = "--child";
constexpr int kSettleMs        = 300;
constexpr int kChildWatchdogMs = 90000;

const QString kService = QStringLiteral("org.mpris.MediaPlayer2.tidalwave");
const QString kPath    = QStringLiteral("/org/mpris/MediaPlayer2");
const QString kRoot    = QStringLiteral("org.mpris.MediaPlayer2");

void touch(const QString &path)
{
    const QString part = path + QStringLiteral(".part");
    QFile f(part);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write("OK\n");
    f.close();
    QFile::rename(part, path);
}

bool anyWindow(bool (QWindow::*is)() const)
{
    const QList<QWindow *> windows = QGuiApplication::topLevelWindows();
    for (QWindow *w : windows)
        if ((w->*is)()) return true;
    return false;
}

int runChild(int argc, char **argv)
{
    const QString hiddenPath = QString::fromLocal8Bit(argv[2]);
    const QString shownPath  = QString::fromLocal8Bit(argv[3]);

    // Keeps the test off the network. The names are the ones run() sets.
    {
        QSettings s(QStringLiteral("TidalWave"), QStringLiteral("Tidal Wave"));
        s.setValue(QStringLiteral("update/enabled"), false);
    }

    // The same order as main(): the Application dies before the QApplication.
    Application::applyScaleFactor();
    QApplication qapp(argc, argv);
    Application  app;

    QTimer::singleShot(kChildWatchdogMs, &qapp, [] { ::_exit(97); });

    // Hides the window as the tray's Hide item does, says so once it has
    // stayed hidden, and says again when something shows it.
    enum { Starting, Hiding, Hidden } phase = Starting;
    QElapsedTimer since;
    auto *poll = new QTimer(&qapp);
    poll->setInterval(20);
    QObject::connect(poll, &QTimer::timeout, &qapp, [&] {
        const bool visible = anyWindow(&QWindow::isVisible);
        if (phase == Starting && anyWindow(&QWindow::isExposed)) {
            app.hideWindow();
            since.start();
            phase = Hiding;
        } else if (phase == Hiding && visible) {
            ::_exit(96);
        } else if (phase == Hiding && since.elapsed() >= kSettleMs) {
            touch(hiddenPath);
            phase = Hidden;
        } else if (phase == Hidden && visible) {
            poll->stop();
            touch(shownPath);
        }
    });
    poll->start();

    return app.run(argc, argv);
}

} // namespace

class TestMprisRaise : public QObject {
    Q_OBJECT

public:
    QString busAddress;

private slots:
    void cleanup() { stopChild(); }

    // What a click on the player in a desktop widget sends. The window was
    // hidden the way the tray hides it.
    void raiseShowsAHiddenWindow()
    {
        if (busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");
        QVERIFY(makeSandbox());
        QVERIFY2(startChild(), "the child process would not start");
        QVERIFY2(waitFor(QStringLiteral("hidden"), 60000), "the program never hid its window");

        QDBusConnection bus = QDBusConnection::connectToBus(busAddress, QStringLiteral("desktop"));
        QVERIFY(bus.isConnected());

        QDBusMessage can = QDBusMessage::createMethodCall(
            kService, kPath, QStringLiteral("org.freedesktop.DBus.Properties"),
            QStringLiteral("Get"));
        can.setArguments({ kRoot, QStringLiteral("CanRaise") });
        const QDBusMessage offered = bus.call(can, QDBus::Block, 10000);
        QCOMPARE(offered.type(), QDBusMessage::ReplyMessage);
        QVERIFY(offered.arguments().value(0).value<QDBusVariant>().variant().toBool());

        const QDBusMessage raised = bus.call(
            QDBusMessage::createMethodCall(kService, kPath, kRoot, QStringLiteral("Raise")),
            QDBus::Block, 10000);
        QCOMPARE(raised.type(), QDBusMessage::ReplyMessage);
        QVERIFY2(waitFor(QStringLiteral("shown"), 5000), "Raise left the window hidden");
    }

private:
    std::unique_ptr<QTemporaryDir> m_box;
    std::unique_ptr<QProcess>      m_child;

    bool makeSandbox()
    {
        m_box = std::make_unique<QTemporaryDir>();
        if (!m_box->isValid()) return false;
        QDir root(m_box->path());
        for (const char *sub : { "home/.config", "home/.cache", "home/.local/share",
                                 "home/.local/state", "run", "tmp" }) {
            if (!root.mkpath(QString::fromLatin1(sub))) return false;
        }
        // Qt rejects a runtime directory that others can read.
        return QFile::setPermissions(root.filePath(QStringLiteral("run")),
                                     QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                         | QFileDevice::ExeOwner);
    }

    bool startChild()
    {
        const QString home = m_box->filePath(QStringLiteral("home"));

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), home);
        env.insert(QStringLiteral("TMPDIR"), m_box->filePath(QStringLiteral("tmp")));
        // The single-instance socket lives here, so a running copy of the
        // program is never reached.
        env.insert(QStringLiteral("XDG_RUNTIME_DIR"), m_box->filePath(QStringLiteral("run")));
        env.insert(QStringLiteral("XDG_CONFIG_HOME"), home + QStringLiteral("/.config"));
        env.insert(QStringLiteral("XDG_CACHE_HOME"),  home + QStringLiteral("/.cache"));
        env.insert(QStringLiteral("XDG_DATA_HOME"),   home + QStringLiteral("/.local/share"));
        env.insert(QStringLiteral("XDG_STATE_HOME"),  home + QStringLiteral("/.local/state"));
        env.insert(QStringLiteral("DBUS_SESSION_BUS_ADDRESS"), busAddress);
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
        env.remove(QStringLiteral("QT_SCALE_FACTOR"));

        m_child = std::make_unique<QProcess>();
        m_child->setProcessEnvironment(env);
        m_child->setProgram(QCoreApplication::applicationFilePath());
        m_child->setArguments({ QString::fromLatin1(kChildFlag),
                                m_box->filePath(QStringLiteral("hidden")),
                                m_box->filePath(QStringLiteral("shown")) });
        m_child->setProcessChannelMode(QProcess::ForwardedErrorChannel);
        m_child->start();
        return m_child->waitForStarted(10000);
    }

    bool waitFor(const QString &file, int ms) const
    {
        const QString path = m_box->filePath(file);
        QElapsedTimer t;
        t.start();
        while (!QFile::exists(path) && t.elapsed() < ms) {
            if (m_child->state() != QProcess::Running) return false;
            QTest::qWait(25);
        }
        return QFile::exists(path);
    }

    void stopChild()
    {
        if (m_child && m_child->state() != QProcess::NotRunning) {
            const qint64 pid = m_child->processId();
            if (pid > 0) ::kill(static_cast<pid_t>(pid), SIGKILL);
            m_child->waitForFinished(5000);
        }
        m_child.reset();
        m_box.reset();
    }
};

int main(int argc, char **argv)
{
    if (argc >= 4 && qstrcmp(argv[1], kChildFlag) == 0)
        return runChild(argc, argv);

    QCoreApplication app(argc, argv);

    // A bus of this test's own. Its configuration names no service directory,
    // so nothing the program asks for is started on it.
    QTemporaryDir busDir;
    QFile conf(busDir.filePath(QStringLiteral("bus.conf")));
    if (conf.open(QIODevice::WriteOnly)) {
        conf.write("<busconfig><type>session</type><listen>unix:path="
                   + QFile::encodeName(busDir.filePath(QStringLiteral("bus")))
                   + "</listen><policy context=\"default\">"
                     "<allow send_destination=\"*\" eavesdrop=\"true\"/>"
                     "<allow eavesdrop=\"true\"/><allow own=\"*\"/>"
                     "</policy></busconfig>\n");
        conf.close();
    }
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"),
                 { QStringLiteral("--config-file=") + conf.fileName(),
                   QStringLiteral("--nofork"), QStringLiteral("--print-address") });

    TestMprisRaise test;
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        test.busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();

    const int rc = QTest::qExec(&test, argc, argv);
    daemon.kill();
    daemon.waitForFinished(3000);
    return rc;
}

#include "tst_mpris_raise.moc"
