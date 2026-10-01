// Startup: the single-instance lock, the no-tray decision and the audio-server
// log filter (HANDOFF, "First-run findings").
//
// Application::run() builds the whole app, binds the real socket and never
// returns until the app exits, so it cannot be called from a test at all. The
// three decisions inside it that have a right and a wrong answer were split
// out as statics for that reason, and this file holds them to those answers.
// Nothing here needs a QApplication, hence QTEST_GUILESS_MAIN.
//
// What is deliberately not covered, and why:
//
//   * That the app really quits when the last window closes with no tray.
//     That needs an exec() loop, a QQuickWindow and two sessions, one with a
//     StatusNotifier host and one without. Offscreen reports no tray either
//     way, so the test would be asserting the platform plugin, not the code.
//     tests/firstrun/run.sh drives the real binary and is the place for it.
//   * That a second launch hands over to the first. Two processes, so it
//     belongs to the firstrun harness too.
//   * That the PipeWire and PulseAudio lines are actually gone from a run.
//     They come out of libQt6Multimedia and only when no audio server is up,
//     which cannot be reproduced on a box that has one. The matcher is tested
//     against the exact strings instead, and the gate around it (no server
//     present at all) is read off the environment in Application.cpp.

#include <QTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTemporaryDir>

#include "ui/Application.h"

#if defined(Q_OS_UNIX)
#include <unistd.h>
#endif

class TestStartup : public QObject {
    Q_OBJECT

private slots:
    void init() {
        m_tmpdir = qEnvironmentVariable("TMPDIR");
        m_runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    }

    void cleanup() {
        restore("TMPDIR", m_tmpdir);
        restore("XDG_RUNTIME_DIR", m_runtime);
    }

    // ── the socket name ──────────────────────────────────────────────────

    // Without a uid in it, two users on one machine share one address in a
    // shared /tmp and the second one to log in never gets a window.
    void socketNameCarriesTheUid() {
#if defined(Q_OS_UNIX)
        const QString name = Application::singleInstanceSocketName();
        const QString uid  = QString::number(static_cast<uint>(::getuid()));
        QVERIFY2(name.contains(uid), qPrintable(name));
        // And it names the app, so it is recognisable in a shared directory.
        QVERIFY2(name.contains(QStringLiteral("TidalWave")), qPrintable(name));
#else
        QSKIP("socket addresses are only path-shaped on Unix");
#endif
    }

    // The original bug: the address was $TMPDIR plus a fixed name, so a long
    // $TMPDIR pushed it past sun_path, bind() failed, and every later launch
    // started a second full instance.
    void socketNameFitsSunPathWithALongTmpdir() {
#if defined(Q_OS_UNIX)
        // A real directory, so length is the only thing wrong with it.
        QTemporaryDir deep;
        QVERIFY(deep.isValid());
        QString longDir = deep.path();
        while (longDir.size() < 160)
            longDir += QStringLiteral("/aaaaaaaaaaaaaaaaaaaa");
        QVERIFY(QDir().mkpath(longDir));
        QVERIFY(QFileInfo(longDir).isDir());

        // Both of the directories the name is normally built from are too
        // long, so only the last resort is left.
        qputenv("TMPDIR", longDir.toLocal8Bit());
        qputenv("XDG_RUNTIME_DIR", longDir.toLocal8Bit());

        const QString name = Application::singleInstanceSocketName();
        // 107 = sizeof(sockaddr_un::sun_path) - 1, measured in bytes.
        QVERIFY2(QFile::encodeName(name).size() <= 107, qPrintable(name));
        QVERIFY2(name.contains(QString::number(static_cast<uint>(::getuid()))), qPrintable(name));
        // Still long enough to be a usable address, not an empty string.
        QVERIFY(name.startsWith(QLatin1Char('/')));

        // And the address it picked is one a server can actually bind.
        QLocalServer server;
        QLocalServer::removeServer(name);
        QVERIFY2(Application::claimSingleInstanceSocket(&server, name),
                 qPrintable(server.errorString()));
        server.close();
        QLocalServer::removeServer(name);
#else
        QSKIP("sun_path is a Unix limit");
#endif
    }

    // A short $TMPDIR is still honoured; the fallback is not a hard-coded /tmp.
    void socketNameUsesTheRuntimeDirWhenItFits() {
#if defined(Q_OS_UNIX)
        QTemporaryDir runtime;
        QVERIFY(runtime.isValid());
        qputenv("XDG_RUNTIME_DIR", runtime.path().toLocal8Bit());
        const QString name = Application::singleInstanceSocketName();
        QVERIFY2(name.startsWith(runtime.path()), qPrintable(name));
#else
        QSKIP("XDG_RUNTIME_DIR is a Unix thing");
#endif
    }

    // ── claiming the socket ──────────────────────────────────────────────

    void listensOnAFreeAddress() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString name = dir.path() + QStringLiteral("/free");
        QLocalServer server;
        QVERIFY2(Application::claimSingleInstanceSocket(&server, name),
                 qPrintable(server.errorString()));
        QVERIFY(server.isListening());
    }

    // A crash or a kill -9 leaves the socket file behind, bind() then fails
    // with AddressInUse on a machine where nothing is listening, and the lock
    // stays broken until someone deletes the file by hand.
    void staleSocketFileDoesNotBlockListen() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString name = dir.path() + QStringLiteral("/stale");
        {
            QFile f(name);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("left behind by a crash");
        }
        QVERIFY(QFileInfo::exists(name));

        QLocalServer server;
        QVERIFY2(Application::claimSingleInstanceSocket(&server, name),
                 qPrintable(server.errorString()));
        QVERIFY(server.isListening());
    }

    // The other side of that: clearing a stale address must not evict a live
    // instance, which is what an unconditional removeServer() would do.
    void liveServerIsNotEvicted() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString name = dir.path() + QStringLiteral("/live");

        QLocalServer first;
        QVERIFY2(first.listen(name), qPrintable(first.errorString()));

        QLocalServer second;
        QVERIFY(!Application::claimSingleInstanceSocket(&second, name));
        QVERIFY(!second.isListening());

        // The first one still owns the address and still answers.
        QVERIFY(first.isListening());
        QLocalSocket client;
        client.connectToServer(name);
        QVERIFY2(client.waitForConnected(1000), qPrintable(client.errorString()));
    }

    void nullServerIsRejectedRatherThanCrashing() {
        QVERIFY(!Application::claimSingleInstanceSocket(nullptr, QStringLiteral("whatever")));
    }

    // ── the no-tray decision ─────────────────────────────────────────────

    void quitOnCloseFollowsTrayAvailability() {
        // No tray: the window is the only way in, so closing it ends the app.
        QVERIFY(Application::shouldQuitOnWindowClose(false));
        // Tray: closing hides, because the tray brings it back.
        QVERIFY(!Application::shouldQuitOnWindowClose(true));
    }

    // ── the audio-server log filter ──────────────────────────────────────

    void audioNoiseMatchesTheTwoConnectErrors() {
        QVERIFY(Application::isAudioServerStartupNoise(
            QStringLiteral("Failed to connect to pipewire instance \"Host is down\"")));
        QVERIFY(Application::isAudioServerStartupNoise(
            QStringLiteral("PulseAudioService: pa_context_connect() failed")));
    }

    void audioNoiseLeavesRealFailuresAlone() {
        QVERIFY(!Application::isAudioServerStartupNoise(QString()));
        QVERIFY(!Application::isAudioServerStartupNoise(
            QStringLiteral("Could not open audio device for playback")));
        QVERIFY(!Application::isAudioServerStartupNoise(
            QStringLiteral("QMediaPlayer::setSource: resource error")));
        // Close to the pipewire line but about a stream, not the connection.
        QVERIFY(!Application::isAudioServerStartupNoise(
            QStringLiteral("pipewire: failed to create stream")));
    }

private:
    static void restore(const char *key, const QString &value) {
        if (value.isNull())
            qunsetenv(key);
        else
            qputenv(key, value.toLocal8Bit());
    }

    QString m_tmpdir;
    QString m_runtime;
};

QTEST_GUILESS_MAIN(TestStartup)
#include "tst_startup.moc"
