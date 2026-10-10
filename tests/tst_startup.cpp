// Startup: the single-instance lock, the no-tray decision, the audio-server
// log filter and the high-DPI scale rule. Application::run() never returns
// until the app exits, so the decisions inside it are statics and are tested
// here. Nothing needs a QApplication. Behaviour that needs a real session,
// such as quitting with no tray or a second launch handing over, is driven by
// tests/firstrun/run.sh.

#include <QTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTemporaryDir>

#include "ui/Application.h"
#include <cmath>
#include <QRegularExpression>

#if defined(Q_OS_UNIX)
#include <unistd.h>
#endif

// Shorthand for the high-DPI tests below; moc will not take a using-declaration
// inside a slots section.
using Screen = Application::ScreenMetrics;

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

    // The address must fit sun_path however long $TMPDIR is, or bind() fails
    // and every later launch starts a second full instance.
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
        // The limit is asked for: sizeof(sun_path) is 108 on Linux and 104 on
        // Apple's platforms.
        QVERIFY2(QFile::encodeName(name).size() <= Application::unixSocketPathMax(),
                 qPrintable(name));
        QVERIFY2(name.contains(QString::number(static_cast<uint>(::getuid()))), qPrintable(name));
        // Still a usable absolute address.
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

    // A runtime directory that fits is used.
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

    // The exact edge of sun_path, from both sides. A directory is built that
    // puts the finished address exactly on the limit, and then one byte over
    // it. Apple's limit differs from Linux's, so neither number is assumed.
    void socketDirIsAcceptedUpToTheLimitAndNotPastIt() {
#if defined(Q_OS_UNIX)
        const int limit = Application::unixSocketPathMax();
        QVERIFY(limit > 0);

        // The leaf the implementation appends, which the address has to leave
        // room for: "/" + "TidalWave-<uid>".
        const QString leaf = QStringLiteral("/TidalWave-%1")
                                 .arg(static_cast<uint>(::getuid()));
        const int leafBytes = QFile::encodeName(leaf).size();

        QTemporaryDir base;
        QVERIFY(base.isValid());
        // Somewhere short to grow from, so the padding below is what decides the
        // length. ASCII throughout, so one character is one byte.
        QString exact = base.path();
        QVERIFY(QFile::encodeName(exact).size() + leafBytes < limit);
        exact += QLatin1Char('/');
        while (QFile::encodeName(exact).size() + leafBytes < limit)
            exact += QLatin1Char('a');
        QCOMPARE(QFile::encodeName(exact).size() + leafBytes, limit);
        QVERIFY(QDir().mkpath(exact));

        // A real directory one byte longer, so length is the only thing wrong
        // with it.
        const QString tooLong = exact + QLatin1Char('a');
        QVERIFY(QDir().mkpath(tooLong));

        // Exactly on the limit: taken, and the address is the one it was given.
        qputenv("XDG_RUNTIME_DIR", exact.toLocal8Bit());
        const QString fits = Application::singleInstanceSocketName();
        QCOMPARE(fits, exact + leaf);
        QCOMPARE(QFile::encodeName(fits).size(), limit);

        // And it is an address a server can really bind.
        QLocalServer server;
        QLocalServer::removeServer(fits);
        QVERIFY2(Application::claimSingleInstanceSocket(&server, fits),
                 qPrintable(server.errorString()));
        server.close();
        QLocalServer::removeServer(fits);

        // One byte over: refused, and the fall-through picks somewhere else.
        qputenv("XDG_RUNTIME_DIR", tooLong.toLocal8Bit());
        const QString overflows = Application::singleInstanceSocketName();
        QVERIFY2(!overflows.startsWith(tooLong), qPrintable(overflows));
        QVERIFY2(QFile::encodeName(overflows).size() <= limit, qPrintable(overflows));
#else
        QSKIP("sun_path is a Unix limit");
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

    // ── what the close button does ───────────────────────────────────────

    void quitOnCloseFollowsTrayAvailability_data() {
        QTest::addColumn<bool>("trayAvailable");
        QTest::addColumn<bool>("quitOnClose");
        QTest::addColumn<bool>("quits");
        // No tray: the window is the only way in, so closing it ends the app,
        // and the preference has nothing left to decide.
        QTest::newRow("no tray, default")        << false << false << true;
        QTest::newRow("no tray, asked to quit")  << false << true  << true;
        // Tray: closing hides, because the tray brings it back, unless the
        // preference makes the close button quit.
        QTest::newRow("tray, default")           << true  << false << false;
        QTest::newRow("tray, asked to quit")     << true  << true  << true;
    }

    void quitOnCloseFollowsTrayAvailability() {
        QFETCH(bool, trayAvailable);
        QFETCH(bool, quitOnClose);
        QFETCH(bool, quits);
        QCOMPARE(Application::shouldQuitOnWindowClose(trayAvailable, quitOnClose), quits);
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
        // Close to the pipewire line, but about a stream.
        QVERIFY(!Application::isAudioServerStartupNoise(
            QStringLiteral("pipewire: failed to create stream")));
    }

    // ── high-DPI scale factor ────────────────────────────────────────────
    // The rule is a pure function of the screen's numbers. The dense case below
    // is a 3840x2400 panel at 283.5 ppi whose desktop reports logical 96.

    void mediaBackendNoiseIsTheOneLineAndNotTheRest() {
        QVERIFY(Application::isMediaBackendStartupNoise(
            QStringLiteral(">>>> listing codecs")));
        QVERIFY(!Application::isMediaBackendStartupNoise(QString()));
        // Anything that merely mentions codecs is a real message.
        QVERIFY(!Application::isMediaBackendStartupNoise(
            QStringLiteral("QMediaPlayer: no decoder for this codec")));
    }

    void scaleFactorSnapsToTheStepAndClamps() {
        QCOMPARE(Application::snapScaleFactor(2.4),  2.5);
        QCOMPARE(Application::snapScaleFactor(2.6),  2.5);
        QCOMPARE(Application::snapScaleFactor(2.13), 2.25);
        // Outside the offered range in both directions.
        QCOMPARE(Application::snapScaleFactor(0.2),  Application::kMinScaleFactor);
        QCOMPARE(Application::snapScaleFactor(99.0), Application::kMaxScaleFactor);
        // Garbage in: a factor is never NaN or negative.
        QCOMPARE(Application::snapScaleFactor(-1.0), Application::kMinScaleFactor);
        QCOMPARE(Application::snapScaleFactor(std::nan("")), Application::kMinScaleFactor);
    }

    void theWindowHasToFitTheScreen() {
        // 3840 px wide with a default window of 1280 logical: 3.0 would ask for
        // exactly the screen width. 2400/800 is the tighter axis, same answer.
        const Screen panel{ 283.5, 96.0, 1.0, 3840, 2400 };
        QCOMPARE(Application::scaleFactorCeilingFor(panel), 2.5);
        // A 1920x1080 screen cannot take any scaling at all with this default
        // window: 1080 * 0.9 / 800 is below one step above 1.
        const Screen small{ 141.0, 96.0, 1.0, 1920, 1080 };
        QCOMPARE(Application::scaleFactorCeilingFor(small), Application::kMinScaleFactor);
        // No geometry: do not let the ceiling be the thing that refuses.
        QCOMPARE(Application::scaleFactorCeilingFor(Screen{}), Application::kMaxScaleFactor);
    }

    void autoScaleFactorDerivesFromTheReportedPanel() {
        const Screen panel{ 283.5, 96.0, 1.0, 3840, 2400 };
        // physicalDpi / kAutoTargetDpi, snapped, then held under the fit ceiling.
        // 2.0 is pinned as a design decision: moving kAutoTargetDpi should fail
        // here.
        QCOMPARE(Application::autoScaleFactor(panel), 2.0);
    }

    void autoScaleFactorLeavesOrdinaryScreensAlone() {
        // A 24in 1920x1080 desk monitor, about 92 ppi.
        QCOMPARE(Application::autoScaleFactor(Screen{ 92.0, 96.0, 1.0, 1920, 1080 }),
                 Application::kMinScaleFactor);
        // A 1440p 27in, about 109 ppi: under kAutoEngageAt, so not worth a
        // fractional factor that only blurs hairlines.
        QCOMPARE(Application::autoScaleFactor(Screen{ 109.0, 96.0, 1.0, 2560, 1440 }),
                 Application::kMinScaleFactor);
    }

    void autoScaleFactorRefusesANonsensePhysicalSize() {
        // Qt synthesises a physical size from the logical DPI when the platform
        // reports none, which arrives here as the two being equal (Xvfb does).
        QCOMPARE(Application::autoScaleFactor(Screen{ 96.0, 96.0, 1.0, 3840, 2400 }),
                 Application::kMinScaleFactor);
        // A projector or KVM claiming a postage-stamp screen.
        QCOMPARE(Application::autoScaleFactor(Screen{ 4877.0, 96.0, 1.0, 3840, 2400 }),
                 Application::kMinScaleFactor);
        QCOMPARE(Application::autoScaleFactor(Screen{ 0.0, 96.0, 1.0, 3840, 2400 }),
                 Application::kMinScaleFactor);
    }

    void anExplicitSettingOutranksTheAutomaticRule() {
        const Screen panel{ 283.5, 96.0, 1.0, 3840, 2400 };
        // 1.5, because the automatic answer for this panel is 2.0: only a value
        // the rule cannot produce shows that the setting was consulted.
        QCOMPARE(Application::resolveScaleFactor(panel, 1.5), 1.5);
        // 0 is Auto.
        QCOMPARE(Application::resolveScaleFactor(panel, 0.0), 2.0);
        // ...but not even an explicit setting may put the window out of reach.
        QCOMPARE(Application::resolveScaleFactor(panel, 3.0), 2.5);
    }

    void aFactorOfOneChangesNothingAtAll() {
        // 0 out means "touch no environment variable": pinning QT_SCALE_FACTOR=1
        // would stop Qt following a screen change it would otherwise have
        // followed.
        QCOMPARE(Application::resolveScaleFactor(Screen{ 92.0, 96.0, 1.0, 1920, 1080 }, 0.0), 0.0);
        QCOMPARE(Application::resolveScaleFactor(Screen{ 283.5, 96.0, 1.0, 3840, 2400 }, 1.0), 0.0);
    }

    void anExplicitEnvironmentVariableOutranksBothOfThem() {
        // Every one of these means somebody already decided, so the app must not
        // touch the scale at all.
        for (const char *var : { "QT_SCALE_FACTOR", "QT_SCREEN_SCALE_FACTORS",
                                 "QT_ENABLE_HIGHDPI_SCALING", "QT_FONT_DPI",
                                 "QT_USE_PHYSICAL_DPI",
                                 "QT_SCALE_FACTOR_ROUNDING_POLICY" }) {
            const QString saved = qEnvironmentVariable(var);
            qputenv(var, QByteArrayLiteral("1"));
            QVERIFY2(Application::scaleFactorSetInEnvironment(), var);
            restore(var, saved);
        }
    }

    // The decision does not ask what desktop or windowing system this is. The
    // one question is whether the platform reported a ratio of its own.
    void aPlatformThatReportsARatioIsTrusted() {
        // The dense panel, but with a compositor that already scales it. Whatever
        // that compositor decided, it is better informed than this rule.
        Screen scaled{ 283.5, 96.0, 1.0, 3840, 2400 };
        scaled.platformDpr = 2.0;
        QCOMPARE(Application::autoScaleFactor(scaled), Application::kMinScaleFactor);
        QCOMPARE(Application::resolveScaleFactor(scaled, 0.0), 0.0);
        // The same panel with the platform reporting nothing gets the rule.
        Screen unscaled{ 283.5, 96.0, 1.0, 3840, 2400 };
        unscaled.platformDpr = 1.0;
        QCOMPARE(Application::autoScaleFactor(unscaled), 2.0);
    }

    void theUsersSettingAppliesEvenWhenThePlatformScales() {
        // The slider wins everywhere: no platform can be trusted about the
        // panel's true physical size.
        Screen scaled{ 283.5, 96.0, 1.0, 3840, 2400 };
        scaled.platformDpr = 2.0;
        QCOMPARE(Application::resolveScaleFactor(scaled, 1.5), 1.5);
    }

    void aStaleSettingCannotStrandTheWindowOffScreen() {
        // 3.0 chosen on the 4K panel, then launched on a projector.
        const Screen projector{ 96.0, 96.0, 1.0, 1366, 768 };
        QCOMPARE(Application::resolveScaleFactor(projector, 3.0), 0.0);
    }

    // The automatic rule is chosen before any QML is loaded, so the default
    // window size is written down in C++ as well as in Main.qml. This keeps
    // the two in step.
    void theDefaultWindowSizeMatchesMainQml() {
        QFile main(QStringLiteral(TIDALWAVE_QML_DIR "/Main.qml"));
        QVERIFY2(main.open(QIODevice::ReadOnly), qPrintable(main.fileName()));
        const QString text = QString::fromUtf8(main.readAll());
        QRegularExpression width(QStringLiteral("^\\s*width:\\s*(\\d+)\\s*$"),
                                 QRegularExpression::MultilineOption);
        QRegularExpression height(QStringLiteral("^\\s*height:\\s*(\\d+)\\s*$"),
                                  QRegularExpression::MultilineOption);
        const auto w = width.match(text);
        const auto h = height.match(text);
        QVERIFY2(w.hasMatch(), "no window width in Main.qml");
        QVERIFY2(h.hasMatch(), "no window height in Main.qml");
        QCOMPARE(w.captured(1).toInt(), Application::kDefaultWindowWidth);
        QCOMPARE(h.captured(1).toInt(), Application::kDefaultWindowHeight);
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
