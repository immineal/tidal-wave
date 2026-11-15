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

    // A device that refuses the connection ends the attempt: "Connecting" in
    // the UI waits for disconnected().
    void aRefusedConnectionEndsTheAttempt()
    {
        quint16 port = 0;
        {
            QTcpServer probe;
            QVERIFY(probe.listen(QHostAddress::LocalHost));
            port = probe.serverPort();
        }
        CastSession session;
        session.setPlainTextForTest(true);
        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy error(&session, &CastSession::error);
        session.connectToDevice(QStringLiteral("127.0.0.1"), port);
        QTRY_COMPARE_WITH_TIMEOUT(gone.count(), 1, 5000);
        QCOMPARE(error.count(), 1);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The connection to the cast device failed."));
        QTest::qWait(100);
        QCOMPARE(gone.count(), 1);
    }

    // A device that takes the connection and never launches the app.
    void aDeviceThatNeverAnswersTimesOut()
    {
        QTcpServer silent;
        QVERIFY(silent.listen(QHostAddress::LocalHost));
        CastSession session;
        session.setPlainTextForTest(true);
        session.setConnectTimeoutForTest(500);
        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy error(&session, &CastSession::error);
        session.connectToDevice(QStringLiteral("127.0.0.1"), silent.serverPort());
        QTRY_COMPARE_WITH_TIMEOUT(gone.count(), 1, 5000);
        QCOMPARE(error.count(), 1);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The cast device did not answer."));
    }

    // LOAD_FAILED used to be dropped, which left the app paused with nothing
    // said. It has to reach error(), which CastManager passes on.
    void aLoadTheDeviceRefusesIsReported()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        receiver.loadAnswer = FakeReceiver::LoadAnswer::Fails;
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        QSignalSpy error(&session, &CastSession::error);
        QSignalSpy playing(&session, &CastSession::playingChanged);

        load(session);
        QTRY_COMPARE_WITH_TIMEOUT(error.count(), 1, 3000);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The cast device could not play this track."));
        QVERIFY(!playing.isEmpty());
        QCOMPARE(playing.last().at(0).toBool(), false);
    }

    // A track that fails while it plays ends IDLE with idleReason ERROR. Polls
    // repeat that status, and it is one error.
    void aPlaybackErrorOnTheDeviceIsReportedOnce()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        load(session);
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 1, 3000);
        QTest::qWait(100);

        QSignalSpy error(&session, &CastSession::error);
        QSignalSpy finished(&session, &CastSession::mediaFinished);
        const QJsonObject failedStatus{{"mediaSessionId", 7}, {"playerState", "IDLE"},
                                       {"idleReason", "ERROR"}};
        receiver.sendMediaStatus(failedStatus);
        receiver.sendMediaStatus(failedStatus);
        QTRY_COMPARE_WITH_TIMEOUT(error.count(), 1, 3000);
        QTest::qWait(200);
        QCOMPARE(error.count(), 1);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The cast device could not play this track."));
        QCOMPARE(finished.count(), 0);
    }

    // The status poll repeats IDLE/FINISHED until the next LOAD lands, and
    // each repeat used to skip another track.
    void theEndOfATrackIsReportedOncePerLoad()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        load(session);   // media session 7
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 1, 3000);
        QTest::qWait(100);

        QSignalSpy finished(&session, &CastSession::mediaFinished);
        const auto ended = [](int mediaSession) {
            return QJsonObject{{"mediaSessionId", mediaSession}, {"playerState", "IDLE"},
                               {"idleReason", "FINISHED"}};
        };
        for (int i = 0; i < 3; ++i) receiver.sendMediaStatus(ended(7));
        QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, 3000);
        QTest::qWait(200);
        QCOMPARE(finished.count(), 1);

        load(session);   // media session 8
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 2, 3000);
        QTest::qWait(100);
        receiver.sendMediaStatus(ended(7));   // a late answer to a poll of the last one
        receiver.sendMediaStatus(ended(8));
        receiver.sendMediaStatus(ended(8));
        QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 2, 3000);
        QTest::qWait(200);
        QCOMPARE(finished.count(), 2);

        // The late status did not point transport back at the last track.
        session.pause();
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("PAUSE")), 1, 3000);
        QCOMPARE(receiver.last(kMedia, QStringLiteral("PAUSE"))
                     .value(QStringLiteral("mediaSessionId")).toInt(), 8);
    }
};

QTEST_MAIN(TestCastSession)
#include "tst_cast_session.moc"
