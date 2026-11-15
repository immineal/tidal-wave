// CastSession against a fake receiver on localhost (FakeCastReceiver.h). No
// TLS, no device, no Tidal.

#include <QTest>
#include <QElapsedTimer>
#include <QSignalSpy>
#include <QSettings>
#include <QTcpServer>
#include <QTemporaryDir>

#include "FakeCastReceiver.h"
#include "cast/CastSession.h"
#include "ui/I18n.h"
#include "ui/Prefs.h"

using namespace fakecast;

namespace {

void load(CastSession &session, double startSec = 0)
{
    session.loadMedia(QStringLiteral("http://127.0.0.1:1/track/x"), QStringLiteral("audio/flac"),
                      QStringLiteral("Tone"), QStringLiteral("Artist"), QStringLiteral("Album"),
                      QString(), 180.0, startSec);
}

} // namespace

class TestCastSession : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        // The German check writes the language to settings: kept out of the real ones.
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_cast_session"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

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

    // Handing a track over to the device starts it where it was playing here.
    void aLoadStartsAtTheGivenPosition()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));

        load(session, 42.5);
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 1, 3000);
        QCOMPARE(receiver.last(kMedia, QStringLiteral("LOAD"))
                     .value(QStringLiteral("currentTime")).toDouble(), 42.5);

        // The next track starts at its beginning: no currentTime at all.
        load(session);
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 2, 3000);
        QVERIFY(!receiver.last(kMedia, QStringLiteral("LOAD"))
                     .contains(QStringLiteral("currentTime")));
    }

    // CASTV2 messages are at most 64 KiB. A longer length is a broken or
    // hostile peer, and one near 4 GiB used to wrap the buffer arithmetic.
    void aFrameLongerThanCastAllowsDropsTheConnection_data()
    {
        QTest::addColumn<quint32>("length");
        QTest::newRow("just over 64 KiB") << quint32(64 * 1024 + 1);
        QTest::newRow("near 4 GiB")       << quint32(0xFFFFFFF0u);
        QTest::newRow("4 GiB less 4")     << quint32(0xFFFFFFFCu);
    }

    void aFrameLongerThanCastAllowsDropsTheConnection()
    {
        QFETCH(quint32, length);
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy error(&session, &CastSession::error);

        QByteArray frame(4, '\0');
        qToBigEndian<quint32>(length, frame.data());
        receiver.peer->write(frame + QByteArray(64, 'x'));

        QTRY_COMPARE_WITH_TIMEOUT(gone.count(), 1, 3000);
        QVERIFY(!session.isConnected());
        QCOMPARE(error.count(), 1);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The connection to the cast device was lost."));
        QTRY_COMPARE_WITH_TIMEOUT(receiver.peer->state(), QAbstractSocket::UnconnectedState,
                                  3000);
    }

    // The receiver closing our virtual connection, or a status that no longer
    // lists our app (the user or another sender started something else),
    // ends the cast as a disconnect does, with nothing to report.
    void theDeviceEndingTheCastEndsItHere_data()
    {
        QTest::addColumn<QString>("ns");
        QTest::addColumn<QString>("source");
        QTest::addColumn<QJsonObject>("payload");

        QTest::newRow("CLOSE from the media app")
            << kConnection << kTransport << QJsonObject{{"type", "CLOSE"}};
        QTest::newRow("CLOSE from the platform")
            << kConnection << QStringLiteral("receiver-0") << QJsonObject{{"type", "CLOSE"}};
        const auto status = [](const QJsonArray &apps) {
            return QJsonObject{{"type", "RECEIVER_STATUS"}, {"requestId", 0},
                               {"status", QJsonObject{{"applications", apps}}}};
        };
        QTest::newRow("another app took over")
            << kReceiver << QStringLiteral("receiver-0")
            << status(QJsonArray{QJsonObject{{"appId", "233637DE"}, {"sessionId", "s-2"},
                                             {"transportId", "web-2"}}});
        QTest::newRow("our app relaunched by another sender")
            << kReceiver << QStringLiteral("receiver-0")
            << status(QJsonArray{QJsonObject{{"appId", kAppId}, {"sessionId", "session-2"},
                                             {"transportId", "web-2"}}});
        QTest::newRow("no app at all")
            << kReceiver << QStringLiteral("receiver-0")
            << QJsonObject{{"type", "RECEIVER_STATUS"}, {"requestId", 0},
                           {"status", QJsonObject{{"volume", QJsonObject{{"level", 0.5}}}}}};
    }

    void theDeviceEndingTheCastEndsItHere()
    {
        QFETCH(QString, ns);
        QFETCH(QString, source);
        QFETCH(QJsonObject, payload);
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        load(session);
        QTRY_COMPARE_WITH_TIMEOUT(receiver.count(kMedia, QStringLiteral("LOAD")), 1, 3000);
        QTest::qWait(100);

        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy up(&session, &CastSession::connected);
        QSignalSpy error(&session, &CastSession::error);
        receiver.send(ns, payload, source);

        QTRY_COMPARE_WITH_TIMEOUT(gone.count(), 1, 3000);
        QVERIFY(!session.isConnected());
        QTRY_COMPARE_WITH_TIMEOUT(receiver.peer->state(), QAbstractSocket::UnconnectedState,
                                  5000);
        QCOMPARE(gone.count(), 1);
        QCOMPARE(up.count(), 0);
        QVERIFY2(error.isEmpty(), qPrintable(error.isEmpty() ? QString()
                                             : error.first().at(0).toString()));
        // The app is no longer ours to stop.
        QCOMPARE(receiver.count(kReceiver, QStringLiteral("STOP")), 0);
        QCOMPARE(receiver.count(kMedia, QStringLiteral("STOP")), 0);
    }

    // A status that still lists our app, as a volume change sends, is no end.
    void aStatusThatStillListsOurAppKeepsTheCast()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy up(&session, &CastSession::connected);

        const QJsonObject app{{"appId", kAppId}, {"sessionId", "session-1"},
                              {"transportId", kTransport}};
        receiver.send(kReceiver, QJsonObject{{"type", "RECEIVER_STATUS"}, {"requestId", 0},
                                             {"status", QJsonObject{
                                                 {"applications", QJsonArray{app}},
                                                 {"volume", QJsonObject{{"level", 0.3}}}}}});
        QTest::qWait(300);
        QCOMPARE(gone.count(), 0);
        QCOMPARE(up.count(), 0);
        QVERIFY(session.isConnected());
    }

    // Once the cast is up, a dropped connection is said in the app's words,
    // not Qt's untranslated socket text.
    void aLostConnectionIsSaidInTheAppsWords()
    {
        FakeReceiver receiver;
        QVERIFY(receiver.listen(QHostAddress::LocalHost));
        CastSession session;
        QVERIFY(connectTo(session, receiver));
        QSignalSpy gone(&session, &CastSession::disconnected);
        QSignalSpy error(&session, &CastSession::error);

        receiver.peer->abort();

        QTRY_COMPARE_WITH_TIMEOUT(gone.count(), 1, 3000);
        QCOMPARE(error.count(), 1);
        QCOMPARE(error.first().at(0).toString(),
                 QStringLiteral("The connection to the cast device was lost."));
        QVERIFY(!session.isConnected());
    }

    // Without its entry in the catalogue a sentence comes out in English.
    void everySentenceHasItsGerman_data()
    {
        QTest::addColumn<QString>("sentence");
        const char *const session[] = {
            "The connection to the cast device failed.",
            "The cast device did not answer.",
            "The cast device could not play this track.",
            "The connection to the cast device was lost.",
        };
        for (const char *s : session) QTest::newRow(s) << QString::fromUtf8(s);
    }

    void everySentenceHasItsGerman()
    {
        QFETCH(QString, sentence);
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        QVERIFY(i18n.isCatalogueLoaded());
        QVERIFY(QCoreApplication::translate("CastSession", sentence.toUtf8().constData())
                != sentence);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestCastSession)
#include "tst_cast_session.moc"
