// The session bus still delivers to the app after Application::applyScaleFactor().
//
// applyScaleFactor() measures the screen with a throwaway QGuiApplication. On a
// desktop the platform theme opens the session bus while that object is built,
// and Qt holds delivery on it until work queued on the application has run.
// A probe that dies with that work undone leaves MPRIS deaf for the session.

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QGuiApplication>
#include <QProcess>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "ui/Application.h"

namespace {

QString g_busAddress;

// Stands in for a desktop's platform theme: it opens the session bus during
// the construction of every application object, the probe included.
void openSessionBus() {
    if (!g_busAddress.isEmpty())
        QDBusConnection::sessionBus();
}
Q_COREAPP_STARTUP_FUNCTION(openSessionBus)

} // namespace

class TestSessionBus : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        if (g_busAddress.isEmpty())
            QSKIP("dbus-daemon is not installed, so there is no private bus to test on");
    }

    void aCallToTheAppIsAnsweredAfterTheScaleProbe() {
        const QString service = QStringLiteral("io.github.immineal.TidalWave.Test");
        QDBusConnection bus = QDBusConnection::sessionBus();
        QVERIFY2(bus.isConnected(), qPrintable(bus.lastError().message()));
        QObject exported;
        QVERIFY(bus.registerService(service));
        QVERIFY(bus.registerObject(QStringLiteral("/probe"), &exported,
                                   QDBusConnection::ExportAllContents));

        // A second connection plays the desktop asking the app something.
        QDBusConnection desktop =
            QDBusConnection::connectToBus(g_busAddress, QStringLiteral("desktop"));
        QVERIFY2(desktop.isConnected(), qPrintable(desktop.lastError().message()));
        const QDBusMessage call = QDBusMessage::createMethodCall(
            service, QStringLiteral("/probe"),
            QStringLiteral("org.freedesktop.DBus.Introspectable"),
            QStringLiteral("Introspect"));
        QDBusPendingCallWatcher watcher(desktop.asyncCall(call, 3000));
        QSignalSpy finished(&watcher, &QDBusPendingCallWatcher::finished);
        QVERIFY2(finished.wait(6000), "the call was neither answered nor timed out");
        QVERIFY2(!watcher.isError(), qPrintable(watcher.error().message()));
    }
};

int main(int argc, char **argv) {
    // A bus of this test's own, so nothing here reaches the session it runs in.
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"),
                 { QStringLiteral("--session"), QStringLiteral("--nofork"),
                   QStringLiteral("--print-address") });
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        g_busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();
    if (!g_busAddress.isEmpty())
        qputenv("DBUS_SESSION_BUS_ADDRESS", g_busAddress.toLocal8Bit());

    // The probe is skipped when any of these is set, and it reads QSettings.
    for (const char *var : { "QT_SCALE_FACTOR", "QT_SCREEN_SCALE_FACTORS",
                             "QT_ENABLE_HIGHDPI_SCALING", "QT_FONT_DPI",
                             "QT_USE_PHYSICAL_DPI", "QT_SCALE_FACTOR_ROUNDING_POLICY" })
        qunsetenv(var);
    QTemporaryDir config;
    qputenv("XDG_CONFIG_HOME", config.path().toLocal8Bit());

    Application::applyScaleFactor();

    int rc = 0;
    {
        QGuiApplication app(argc, argv);
        TestSessionBus test;
        rc = QTest::qExec(&test, argc, argv);
    }
    daemon.kill();
    daemon.waitForFinished(3000);
    return rc;
}

#include "tst_session_bus.moc"
