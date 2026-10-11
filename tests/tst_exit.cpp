// Quitting prints no QML error. The child is this binary re-executed with
// --child: it starts the program as main() does, offscreen, with a home and a
// runtime directory of its own and no session bus. Only that pid is signalled.

#include <QTest>
#include <QApplication>
#include <QByteArray>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QList>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSettings>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QTimer>
#include <QWindow>

#include <csignal>
#include <memory>
#include <vector>
#include <unistd.h>

#include "ui/Application.h"

namespace {

const char kChildFlag[] = "--child";
// Written through qWarning() just before the quit, so its arrival shows that
// warnings from the child reach the pipe this test reads.
const char kMarker[] = "tst_exit: about to quit";

// Time for the work that follows the first expose, so the quit meets the
// program at rest.
constexpr int kSettleMs        = 300;
constexpr int kChildWatchdogMs = 60000;

void writeReady(const QString &path)
{
    const QString part = path + QStringLiteral(".part");
    QFile f(part);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write("OK\n");
    f.close();
    QFile::rename(part, path);
}

QWindow *exposedWindow()
{
    const QList<QWindow *> windows = QGuiApplication::topLevelWindows();
    for (QWindow *w : windows)
        if (w->isExposed()) return w;
    return nullptr;
}

int runChild(int argc, char **argv)
{
    const QByteArray how       = argv[2];
    const QString    readyPath = QString::fromLocal8Bit(argv[3]);

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

    // A second launch returns from run() before its event loop starts, so
    // none of this runs there.
    auto *poll = new QTimer(&qapp);
    poll->setInterval(20);
    QObject::connect(poll, &QTimer::timeout, &qapp, [poll, how, readyPath, &app] {
        if (!exposedWindow()) return;
        poll->stop();
        QTimer::singleShot(kSettleMs, &app, [how, readyPath, &app] {
            qWarning("%s", kMarker);
            if (how == "tray") {
                // The slot the tray's Quit action is connected to.
                app.quit();
            } else if (how == "mpris") {
                // What MprisPlayer::Quit() calls.
                QCoreApplication::quit();
            } else if (how == "close") {
                if (QWindow *w = exposedWindow()) w->close();
            } else {
                writeReady(readyPath);
            }
        });
    });
    poll->start();

    return app.run(argc, argv);
}

} // namespace

class TestExit : public QObject {
    Q_OBJECT

private slots:
    void cleanup() { stopAll(); }

    void quittingPrintsNoQmlError_data()
    {
        QTest::addColumn<QByteArray>("how");
        QTest::newRow("SIGTERM")                      << QByteArrayLiteral("signal");
        QTest::newRow("the tray's Quit")              << QByteArrayLiteral("tray");
        QTest::newRow("Quit over MPRIS")              << QByteArrayLiteral("mpris");
        QTest::newRow("closing the window, no tray")  << QByteArrayLiteral("close");
    }

    void quittingPrintsNoQmlError()
    {
        QFETCH(QByteArray, how);

        QVERIFY(makeSandbox());
        QProcess *child = startChild(how);
        QVERIFY2(child, "the child process would not start");

        if (how == "signal") {
            QVERIFY2(waitForReady(child), "the child never showed its window");
            QVERIFY(::kill(static_cast<pid_t>(child->processId()), SIGTERM) == 0);
        }

        QVERIFY2(child->waitForFinished(45000), "the process did not quit");
        const QByteArray err = child->readAllStandardError();

        QCOMPARE(child->exitStatus(), QProcess::NormalExit);
        QCOMPARE(child->exitCode(), 0);
        QVERIFY2(err.contains(kMarker),
                 "the child's warnings did not reach this test, so an empty "
                 "stderr would prove nothing");
        const QStringList errors = qmlErrors(err);
        QVERIFY2(errors.isEmpty(), qPrintable(describe(errors)));
    }

    // The second launch hands over to the first and leaves before it has an
    // engine. The first stays up and still quits cleanly afterwards.
    void aSecondLaunchPrintsNoQmlErrorAndTheFirstStillQuitsCleanly()
    {
        QVERIFY(makeSandbox());
        QProcess *first = startChild(QByteArrayLiteral("signal"));
        QVERIFY2(first, "the first process would not start");
        QVERIFY2(waitForReady(first), "the first process never showed its window");

        QProcess *second = startChild(QByteArrayLiteral("second"));
        QVERIFY2(second, "the second process would not start");
        QVERIFY2(second->waitForFinished(30000),
                 "the second launch stayed up, so it did not find the first");
        QCOMPARE(second->exitStatus(), QProcess::NormalExit);
        QCOMPARE(second->exitCode(), 0);
        const QStringList secondErrors = qmlErrors(second->readAllStandardError());
        QVERIFY2(secondErrors.isEmpty(), qPrintable(describe(secondErrors)));

        QCOMPARE(first->state(), QProcess::Running);
        QVERIFY(::kill(static_cast<pid_t>(first->processId()), SIGTERM) == 0);
        QVERIFY2(first->waitForFinished(45000), "the first process did not quit");
        const QByteArray err = first->readAllStandardError();
        QCOMPARE(first->exitCode(), 0);
        QVERIFY(err.contains(kMarker));
        const QStringList errors = qmlErrors(err);
        QVERIFY2(errors.isEmpty(), qPrintable(describe(errors)));
    }

private:
    std::unique_ptr<QTemporaryDir>         m_box;
    std::vector<std::unique_ptr<QProcess>> m_children;

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

    QString readyPath() const { return m_box->filePath(QStringLiteral("ready")); }

    QProcessEnvironment sandboxEnvironment() const
    {
        const QString home = m_box->filePath(QStringLiteral("home"));
        const QString run  = m_box->filePath(QStringLiteral("run"));
        const QString tmp  = m_box->filePath(QStringLiteral("tmp"));

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), home);
        env.insert(QStringLiteral("TMPDIR"), tmp);
        // The single-instance socket lives here, so a running copy of the
        // program is never reached.
        env.insert(QStringLiteral("XDG_RUNTIME_DIR"), run);
        env.insert(QStringLiteral("XDG_CONFIG_HOME"), home + QStringLiteral("/.config"));
        env.insert(QStringLiteral("XDG_CACHE_HOME"),  home + QStringLiteral("/.cache"));
        env.insert(QStringLiteral("XDG_DATA_HOME"),   home + QStringLiteral("/.local/share"));
        env.insert(QStringLiteral("XDG_STATE_HOME"),  home + QStringLiteral("/.local/state"));
        // A dead address: unset, libdbus would look for the session's own bus.
        env.insert(QStringLiteral("DBUS_SESSION_BUS_ADDRESS"),
                   QStringLiteral("unix:path=") + run + QStringLiteral("/absent-session-bus"));
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
        // Qt may log to the journal when stderr is a pipe.
        env.insert(QStringLiteral("QT_FORCE_STDERR_LOGGING"), QStringLiteral("1"));
        for (const char *name : { "QT_LOGGING_RULES", "QT_LOGGING_CONF", "QT_MESSAGE_PATTERN",
                                  "QT_SCALE_FACTOR" })
            env.remove(QString::fromLatin1(name));
        return env;
    }

    QProcess *startChild(const QByteArray &how)
    {
        auto child = std::make_unique<QProcess>();
        child->setProcessEnvironment(sandboxEnvironment());
        child->setProgram(QCoreApplication::applicationFilePath());
        child->setArguments({ QString::fromLatin1(kChildFlag), QString::fromLatin1(how),
                              readyPath() });
        child->start();
        if (!child->waitForStarted(10000)) return nullptr;
        m_children.push_back(std::move(child));
        return m_children.back().get();
    }

    bool waitForReady(QProcess *child) const
    {
        QElapsedTimer t;
        t.start();
        while (!QFile::exists(readyPath()) && t.elapsed() < 45000) {
            if (child->state() != QProcess::Running) return false;
            QTest::qWait(25);
        }
        return QFile::exists(readyPath());
    }

    static QStringList qmlErrors(const QByteArray &err)
    {
        static const QRegularExpression re(QStringLiteral("\\b(TypeError|ReferenceError)\\b"));
        QStringList hits;
        const QStringList lines = QString::fromLocal8Bit(err).split(QLatin1Char('\n'));
        for (const QString &line : lines)
            if (re.match(line).hasMatch()) hits << line;
        return hits;
    }

    static QString describe(const QStringList &errors)
    {
        return QStringLiteral("%1 QML error line(s) on stderr, the first: %2")
            .arg(errors.size())
            .arg(errors.value(0));
    }

    void stopAll()
    {
        for (const auto &child : m_children) {
            if (child->state() == QProcess::NotRunning) continue;
            const qint64 pid = child->processId();
            if (pid > 0) ::kill(static_cast<pid_t>(pid), SIGKILL);
            child->waitForFinished(5000);
        }
        m_children.clear();
        m_box.reset();
    }
};

int main(int argc, char **argv)
{
    if (argc >= 4 && qstrcmp(argv[1], kChildFlag) == 0)
        return runChild(argc, argv);

    QCoreApplication app(argc, argv);
    TestExit tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_exit.moc"
