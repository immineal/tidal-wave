// CastManager wiring the session, the media server and the prep together,
// against the fake receiver of FakeCastReceiver.h. Some cases run without a
// Player, the rest over a real, muted one that never fetches a track. No
// device, no Tidal (the API points at a dead port).

#include <QTest>
#include <QFile>
#include <QHostAddress>
#include <QSignalSpy>
#include <QMediaPlayer>
#include <QSettings>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrl>
#include <atomic>
#include <thread>

#include "FakeCastReceiver.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "cast/CastManager.h"
#include "cast/CastMediaPrep.h"
#include "cast/CastSession.h"
#include "player/Player.h"
#include "ui/I18n.h"
#include "ui/Prefs.h"

using namespace fakecast;

namespace {

class LocalApi : public TidalApi {
public:
    QString local = QStringLiteral("http://127.0.0.1:1/");

protected:
    QString baseUrl(const QString &) const override { return local; }
};

// The status line of the answer to `request`, from a thread of its own.
class StatusOf {
public:
    StatusOf(const QUrl &url, const QByteArray &request)
    {
        m_thread = std::thread([this, url, request] {
            QTcpSocket s;
            s.connectToHost(url.host(), quint16(url.port()));
            if (s.waitForConnected(5000)) {
                s.write(request);
                s.waitForBytesWritten(5000);
                QByteArray all;
                while (s.state() == QAbstractSocket::ConnectedState && s.waitForReadyRead(5000))
                    all += s.readAll();
                all += s.readAll();
                m_status = all.split(' ').value(1).toInt();
            }
            m_done = true;
        });
    }
    ~StatusOf() { m_thread.join(); }
    bool done() const { return m_done; }
    int  status() const { return m_status; }

private:
    std::thread       m_thread;
    std::atomic<bool> m_done{false};
    std::atomic<int>  m_status{0};
};

// A port nobody listens on.
quint16 deadPort()
{
    QTcpServer probe;
    if (!probe.listen(QHostAddress::LocalHost)) return 0;
    return probe.serverPort();
}

// A manager over a real, muted Player, with the fake receivers it may pick.
struct Rig {
    LocalApi    api;
    TidalClient client{&api};
    Player      player{&client};
    CastManager manager{&client, &player};

    bool start()
    {
        player.setMuted(true);
        player.setVolume(0.0);
        auto *session = manager.findChild<CastSession *>();
        if (!session) return false;
        session->setPlainTextForTest(true);
        // The Player builds its audio objects on the first turn of the loop.
        return QTest::qWaitFor([this] { return player.findChild<QMediaPlayer *>() != nullptr; },
                               10000);
    }

    bool add(const QString &id, const QString &name, quint16 port)
    {
        return QMetaObject::invokeMethod(&manager, "onDeviceFound", Q_ARG(QString, id),
                                         Q_ARG(QString, name),
                                         Q_ARG(QString, QStringLiteral("127.0.0.1")),
                                         Q_ARG(int, int(port)));
    }

    bool castTo(const QString &id)
    {
        manager.connectToDevice(id);
        return QTest::qWaitFor([this] { return manager.connected(); }, 5000);
    }
};

} // namespace

class TestCastManager : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_cast_manager"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // The receiver fetches from the URL in LOAD, so its host has to be the
    // address the device was reached from, not whichever interface (docker0,
    // a VPN, a VM bridge) the system happens to list first.
    void theMediaUrlUsesTheAddressTheDeviceIsReachedFrom()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("track.flac"));
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(QByteArray(4096, 'x'));
        f.close();

        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        LocalApi    api;
        TidalClient client{&api};
        CastManager manager(&client, nullptr);
        auto *session = manager.findChild<CastSession *>();
        auto *prep    = manager.findChild<CastMediaPrep *>();
        QVERIFY(session && prep);
        session->setPlainTextForTest(true);

        QVERIFY(QMetaObject::invokeMethod(&manager, "onDeviceFound",
                                          Q_ARG(QString, QStringLiteral("device-1")),
                                          Q_ARG(QString, QStringLiteral("Speaker")),
                                          Q_ARG(QString, QStringLiteral("127.0.0.1")),
                                          Q_ARG(int, receiver.serverPort())));
        QSignalSpy error(&manager, &CastManager::error);
        manager.connectToDevice(QStringLiteral("device-1"));
        QTRY_VERIFY_WITH_TIMEOUT(manager.connected() || !error.isEmpty(), 5000);
        QVERIFY2(error.isEmpty(), qPrintable(error.isEmpty() ? QString()
                                             : error.first().at(0).toString()));

        // What prep hands over once a track is ready.
        emit prep->ready(path, QStringLiteral("audio/flac"));
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 1, 3000);
        const QUrl url(receiver.last(kMedia, QStringLiteral("LOAD"))
                           .value(QStringLiteral("media")).toObject()
                           .value(QStringLiteral("contentId")).toString());
        QCOMPARE(url.host(), QStringLiteral("127.0.0.1"));

        // And the server is there to answer on it.
        StatusOf head(url, "HEAD " + url.path().toUtf8() + " HTTP/1.1\r\nHost: x\r\n\r\n");
        QTRY_VERIFY_WITH_TIMEOUT(head.done(), 5000);
        QCOMPARE(head.status(), 200);

        manager.disconnect();
    }

    // A device that ends the cast itself ends it here: the Player goes back
    // to local and the picker stops showing the device.
    void theDeviceEndingTheCastEndsItForThePlayer()
    {
        FakeReceiver first;
        QVERIFY(first.listen(QHostAddress::LocalHost));
        Rig r;
        QVERIFY(r.start());
        QVERIFY(r.add(QStringLiteral("device-1"), QStringLiteral("Kitchen"), first.serverPort()));
        QVERIFY(r.castTo(QStringLiteral("device-1")));

        QSignalSpy error(&r.manager, &CastManager::error);
        first.send(kConnection, QJsonObject{{"type", "CLOSE"}}, kTransport);
        QTRY_VERIFY_WITH_TIMEOUT(!r.manager.connected(), 3000);
        QVERIFY(!r.player.casting());
        QCOMPARE(r.manager.deviceName(), QString());
        QCOMPARE(error.count(), 0);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestCastManager)
#include "tst_cast_manager.moc"
