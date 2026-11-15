// CastManager wiring the session, the media server and the prep together,
// against the fake receiver of FakeCastReceiver.h. No Player: the manager
// runs without one. No device, no Tidal (the API points at a dead port).

#include <QTest>
#include <QFile>
#include <QHostAddress>
#include <QSignalSpy>
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

} // namespace

class TestCastManager : public QObject {
    Q_OBJECT

private slots:
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
};

QTEST_MAIN(TestCastManager)
#include "tst_cast_manager.moc"
