// CastSession against a fake receiver on localhost (FakeCastReceiver.h). No
// TLS, no device, no Tidal.

#include <QTest>
#include <QElapsedTimer>
#include <QSignalSpy>
#include <QTcpServer>

#include "FakeCastReceiver.h"
#include "cast/CastSession.h"

using namespace fakecast;

namespace {

void load(CastSession &session)
{
    session.loadMedia(QStringLiteral("http://127.0.0.1:1/track/x"), QStringLiteral("audio/flac"),
                      QStringLiteral("Tone"), QStringLiteral("Artist"), QStringLiteral("Album"),
                      QString(), 180.0);
}

} // namespace

class TestCastSession : public QObject {
    Q_OBJECT

private slots:
    // Leaving a cast sends the receiver its STOP and CLOSE and does not wait
    // for them on the GUI thread, even when the device has stopped reading.
    void disconnectingDoesNotWaitForASlowReceiver()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        load(session);
        QTRY_VERIFY_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")) == 1, 3000);
        QTest::qWait(100);   // the media session id is in

        // Enough queued that the loopback buffers fill and some stays in Qt's.
        receiver.stopReading();
        const QString big(1024 * 1024, QLatin1Char('a'));
        for (int i = 0; i < 30; ++i)
            session.loadMedia(QStringLiteral("http://127.0.0.1:1/track/x"),
                              QStringLiteral("audio/flac"), big, QString(), QString(),
                              QString(), 180.0);
        QTest::qWait(300);

        QElapsedTimer clock;
        clock.start();
        session.disconnectFromDevice();
        const qint64 took = clock.elapsed();
        QVERIFY2(took < 100, qPrintable(QStringLiteral("disconnecting took %1 ms").arg(took)));

        receiver.resumeReading();
        QTRY_VERIFY_WITH_TIMEOUT(receiver.count(kConnection, QStringLiteral("CLOSE")) > 0, 5000);
        QCOMPARE(receiver.count(kMedia, QStringLiteral("STOP")), 1);
        QCOMPARE(receiver.count(kReceiver, QStringLiteral("STOP")), 1);
        // Both virtual connections, the media app's and the platform's.
        QCOMPARE(receiver.count(kConnection, QStringLiteral("CLOSE")), 2);
        // And the socket does close, without anyone waiting for it.
        QTRY_COMPARE_WITH_TIMEOUT(receiver.peer->state(), QAbstractSocket::UnconnectedState,
                                  5000);
    }
};

QTEST_MAIN(TestCastSession)
#include "tst_cast_session.moc"
