// The track-change notification: when it is shown, what it says, and on Linux
// what goes to org.freedesktop.Notifications, against a fake server on a
// private bus.

#include <QCoreApplication>
#include <QSettings>
#include <QTemporaryDir>
#include <QTest>

#include "ui/Prefs.h"
#include "ui/TrackNotifier.h"

#ifdef Q_OS_LINUX
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QFile>
#include <QProcess>
#endif

namespace {

QVariantMap track(qint64 id, const QString &title = QStringLiteral("A Song")) {
    return {
        {QStringLiteral("id"), id},
        {QStringLiteral("title"), title},
        {QStringLiteral("artists"), QStringLiteral("A Band & Friends")},
        {QStringLiteral("albumTitle"), QStringLiteral("An Album")},
        {QStringLiteral("coverUrl"), QStringLiteral("https://resources.example/1/320x320.jpg")},
    };
}

#ifdef Q_OS_LINUX
// Stands in for the desktop's notification server.
class FakeNotifications : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.Notifications")
public:
    struct Call {
        uint replacesId;
        QString summary, body;
        QVariantMap hints;
    };
    QList<Call> calls;
    QStringList capabilities{QStringLiteral("body"), QStringLiteral("body-markup")};

public slots:
    QStringList GetCapabilities() { return capabilities; }
    uint Notify(const QString &, uint replacesId, const QString &, const QString &summary,
                const QString &body, const QStringList &, const QVariantMap &hints, int) {
        calls.append({replacesId, summary, body, hints});
        return replacesId ? replacesId : 41 + uint(calls.size());
    }
};
#endif

} // namespace

class TestTrackNotifier : public QObject {
    Q_OBJECT

public:
    QString busAddress;

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_track_notifier"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void offByDefault() {
        Prefs prefs;
        QVERIFY(!prefs.trackNotifications());
        prefs.setTrackNotifications(true);
        QVERIFY(Prefs().trackNotifications());
        prefs.setTrackNotifications(false);
    }

    void announcesEachNewTrackOnce() {
        TrackNotifier n;
        QList<TrackNotifier::Notification> sent;
        n.setEnabled([] { return true; });
        n.setSender([&](const TrackNotifier::Notification &x) { sent << x; });

        // A restored queue loads paused: nothing yet.
        n.update(track(1), false);
        QCOMPARE(sent.size(), 0);
        n.update(track(1), true);
        QCOMPARE(sent.size(), 1);
        QCOMPARE(sent[0].title, QStringLiteral("A Song"));
        QCOMPARE(sent[0].body, QStringLiteral("A Band & Friends\nAn Album"));
        // Pause and resume is the same track.
        n.update(track(1), false);
        n.update(track(1), true);
        QCOMPARE(sent.size(), 1);
        n.update(track(2, QStringLiteral("Next")), true);
        QCOMPARE(sent.size(), 2);
        QCOMPARE(sent[1].title, QStringLiteral("Next"));
        // An emptied queue announces nothing.
        n.update({}, true);
        QCOMPARE(sent.size(), 2);
    }

    void quietWhileOffOrInFront() {
        TrackNotifier n;
        int sent = 0;
        bool enabled = false, inFront = false;
        n.setEnabled([&] { return enabled; });
        n.setWindowActive([&] { return inFront; });
        n.setSender([&](const TrackNotifier::Notification &) { ++sent; });

        n.update(track(1), true);
        QCOMPARE(sent, 0);
        enabled = true;
        inFront = true;
        n.update(track(2), true);
        QCOMPARE(sent, 0);
        inFront = false;
        n.update(track(3), true);
        QCOMPARE(sent, 1);
    }

    void waitsForTheCoverAndDropsAStaleOne() {
        TrackNotifier n;
        QList<TrackNotifier::Notification> sent;
        QList<std::function<void(const QImage &)>> pending;
        n.setEnabled([] { return true; });
        n.setSender([&](const TrackNotifier::Notification &x) { sent << x; });
        n.setCoverFetcher([&](const QUrl &, std::function<void(const QImage &)> done) {
            pending << done;
        });

        n.update(track(1), true);
        n.update(track(2, QStringLiteral("Second")), true);
        QCOMPARE(sent.size(), 0);
        QImage img(4, 4, QImage::Format_RGB32);
        img.fill(Qt::red);
        // The first track's cover lands after the second track started.
        pending[0](img);
        QCOMPARE(sent.size(), 0);
        pending[1](img);
        QCOMPARE(sent.size(), 1);
        QCOMPARE(sent[0].title, QStringLiteral("Second"));
        QVERIFY(!sent[0].cover.isNull());
        // A failed download still notifies, without a picture.
        n.update(track(3), true);
        pending[2](QImage());
        QCOMPARE(sent.size(), 2);
        QVERIFY(sent[1].cover.isNull());
    }

#ifdef Q_OS_LINUX
    void sendsToTheNotificationServer() {
        if (busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");
        QDBusConnection serverBus = QDBusConnection::connectToBus(busAddress, QStringLiteral("server"));
        QDBusConnection appBus = QDBusConnection::connectToBus(busAddress, QStringLiteral("app"));
        QVERIFY(serverBus.isConnected() && appBus.isConnected());
        FakeNotifications server;
        QVERIFY(serverBus.registerObject(QStringLiteral("/org/freedesktop/Notifications"), &server,
                                         QDBusConnection::ExportAllSlots));
        QVERIFY(serverBus.registerService(QStringLiteral("org.freedesktop.Notifications")));

        QObject context;
        const TrackNotifier::Sender send = TrackNotifier::freedesktopSender(appBus, &context);
        QImage cover(300, 300, QImage::Format_RGB32);
        cover.fill(Qt::blue);
        send({QStringLiteral("A <Song>"), QStringLiteral("A Band & Friends"), cover});
        QTRY_COMPARE(server.calls.size(), 1);
        const auto &first = server.calls[0];
        QCOMPARE(first.replacesId, 0u);
        // The summary is plain text; the body is markup on this server.
        QCOMPARE(first.summary, QStringLiteral("A <Song>"));
        QCOMPARE(first.body, QStringLiteral("A Band &amp; Friends"));
        QCOMPARE(first.hints.value(QStringLiteral("suppress-sound")).toBool(), true);
        QCOMPARE(first.hints.value(QStringLiteral("desktop-entry")).toString(),
                 QStringLiteral("io.github.immineal.TidalWave"));
        QVERIFY(first.hints.contains(QStringLiteral("image-data")));

        // Wait for the reply that carries the id, then the next one replaces it.
        QTest::qWait(200);
        send({QStringLiteral("Next"), QStringLiteral("B"), QImage()});
        QTRY_COMPARE(server.calls.size(), 2);
        QCOMPARE(server.calls[1].replacesId, 42u);
        QVERIFY(!server.calls[1].hints.contains(QStringLiteral("image-data")));

        serverBus.unregisterService(QStringLiteral("org.freedesktop.Notifications"));
        QDBusConnection::disconnectFromBus(QStringLiteral("server"));
        QDBusConnection::disconnectFromBus(QStringLiteral("app"));
    }

    void plainBodyWithoutMarkup() {
        if (busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");
        QDBusConnection serverBus = QDBusConnection::connectToBus(busAddress, QStringLiteral("server2"));
        QDBusConnection appBus = QDBusConnection::connectToBus(busAddress, QStringLiteral("app2"));
        FakeNotifications server;
        server.capabilities = {QStringLiteral("body")};
        QVERIFY(serverBus.registerObject(QStringLiteral("/org/freedesktop/Notifications"), &server,
                                         QDBusConnection::ExportAllSlots));
        QVERIFY(serverBus.registerService(QStringLiteral("org.freedesktop.Notifications")));

        QObject context;
        const TrackNotifier::Sender send = TrackNotifier::freedesktopSender(appBus, &context);
        QTest::qWait(200);
        send({QStringLiteral("T"), QStringLiteral("A & B"), QImage()});
        QTRY_COMPARE(server.calls.size(), 1);
        QCOMPARE(server.calls[0].body, QStringLiteral("A & B"));

        serverBus.unregisterService(QStringLiteral("org.freedesktop.Notifications"));
        QDBusConnection::disconnectFromBus(QStringLiteral("server2"));
        QDBusConnection::disconnectFromBus(QStringLiteral("app2"));
    }
#endif

private:
    QTemporaryDir m_dir;
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    TestTrackNotifier test;
#ifdef Q_OS_LINUX
    // A bus of this test's own, as tst_mpris_raise starts one.
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
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        test.busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();
#endif
    const int rc = QTest::qExec(&test, argc, argv);
#ifdef Q_OS_LINUX
    daemon.kill();
    daemon.waitForFinished(3000);
#endif
    return rc;
}

#include "tst_track_notifier.moc"
