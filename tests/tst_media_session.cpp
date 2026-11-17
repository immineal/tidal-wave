// The media controls of Windows and macOS, through the one interface both
// backends implement. A fake backend stands in for the platform: it records
// what it was shown and presses buttons the way the system would.

#include <QSettings>
#include <QMediaPlayer>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "mediasession/MediaSession.h"
#include "player/Player.h"

namespace {

class FakeBackend : public MediaSessionBackend {
public:
    QList<MediaSessionState> shown;
    void update(const MediaSessionState &state) override { shown.append(state); }
};

// Never answers a stream request, so nothing is fetched or played.
class SilentClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    void fetchStreamManifest(qint64, StreamCb) override {}
};

QVariantMap trackOf(qlonglong id) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Joined");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("coverUrl")]   = QStringLiteral("https://example.invalid/%1.jpg").arg(id);
    t[QStringLiteral("duration")]   = 30;
    return t;
}

} // namespace

class TestMediaSession : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_media_session"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void noTrackIsStoppedAndEmpty() {
        const MediaSessionState s = MediaSession::stateFrom({}, false, false, 0, 0, false);
        QVERIFY(!s.hasTrack());
        QCOMPARE(s.playback, MediaSessionState::Playback::Stopped);
    }

    void aTrackIsShownWithEachArtist() {
        QVariantMap t = trackOf(7);
        t[QStringLiteral("artistList")] = QVariantList{
            QVariantMap{{QStringLiteral("name"), QStringLiteral("One")}},
            QVariantMap{{QStringLiteral("name"), QStringLiteral("Two")}}};
        const MediaSessionState s = MediaSession::stateFrom(t, true, false, 1200, 0, true);
        QCOMPARE(s.title, QStringLiteral("T7"));
        QCOMPARE(s.artist, QStringLiteral("One, Two"));
        QCOMPARE(s.album, QStringLiteral("Album"));
        QCOMPARE(s.coverUrl, QStringLiteral("https://example.invalid/7.jpg"));
        // The catalogue's length until the stream says otherwise.
        QCOMPARE(s.durationMs, 30000);
        QCOMPARE(s.positionMs, 1200);
        QCOMPARE(s.playback, MediaSessionState::Playback::Playing);
        QVERIFY(s.canNext);
        QVERIFY(s.canPrevious);
    }

    void anOlderRowKeepsItsJoinedArtists() {
        const MediaSessionState s = MediaSession::stateFrom(trackOf(7), false, false, 0, 0, false);
        QCOMPARE(s.artist, QStringLiteral("Joined"));
        QCOMPARE(s.playback, MediaSessionState::Playback::Paused);
        QVERIFY(!s.canNext);
    }

    void theLoadedLengthWins() {
        const MediaSessionState s = MediaSession::stateFrom(trackOf(7), false, true, 0, 31500, false);
        QCOMPARE(s.durationMs, 31500);
        QCOMPARE(s.playback, MediaSessionState::Playback::Stopped);
    }

    // The platform is told only what changed, and gets the state it missed
    // when it arrives late.
    void onlyAChangeIsSent() {
        MediaSession session;
        const MediaSessionState a = MediaSession::stateFrom(trackOf(1), true, false, 0, 0, true);
        session.setState(a);
        auto fake = std::make_unique<FakeBackend>();
        FakeBackend *f = fake.get();
        session.setBackend(std::move(fake));
        QCOMPARE(f->shown.size(), 1);
        QCOMPARE(f->shown.last().title, QStringLiteral("T1"));
        session.setState(a);
        QCOMPARE(f->shown.size(), 1);
        session.setState(MediaSession::stateFrom(trackOf(1), false, false, 500, 0, true));
        QCOMPARE(f->shown.size(), 2);
        QCOMPARE(f->shown.last().playback, MediaSessionState::Playback::Paused);
    }

    void eachButtonIsASignal_data() {
        QTest::addColumn<int>("command");
        QTest::addColumn<QByteArray>("signal");
        QTest::newRow("play")     << int(MediaSession::Command::Play)      << QByteArray(SIGNAL(playRequested()));
        QTest::newRow("pause")    << int(MediaSession::Command::Pause)     << QByteArray(SIGNAL(pauseRequested()));
        QTest::newRow("toggle")   << int(MediaSession::Command::PlayPause) << QByteArray(SIGNAL(playPauseRequested()));
        QTest::newRow("next")     << int(MediaSession::Command::Next)      << QByteArray(SIGNAL(nextRequested()));
        QTest::newRow("previous") << int(MediaSession::Command::Previous)  << QByteArray(SIGNAL(previousRequested()));
        QTest::newRow("stop")     << int(MediaSession::Command::Stop)      << QByteArray(SIGNAL(stopRequested()));
    }
    void eachButtonIsASignal() {
        QFETCH(int, command);
        QFETCH(QByteArray, signal);
        MediaSession session;
        QSignalSpy spy(&session, signal.constData());
        session.handle(MediaSession::Command(command));
        QCOMPARE(spy.count(), 1);
    }

    // Wired to a real Player: a queue shows up on the controls, and Next from
    // the controls moves it, leaving a paused player paused.
    void attachedToThePlayer() {
        TidalApi api;
        SilentClient client(&api);
        Player player(&client);
        player.setMuted(true);
        MediaSession session;
        auto fake = std::make_unique<FakeBackend>();
        FakeBackend *f = fake.get();
        session.setBackend(std::move(fake));
        session.attach(&player);
        // The Player builds its audio objects on the first turn of the loop.
        QVERIFY(QTest::qWaitFor([&player] { return player.findChild<QMediaPlayer *>(); }, 10000));

        player.playTracks({trackOf(11), trackOf(12)}, 0);
        QTRY_COMPARE(f->shown.last().title, QStringLiteral("T11"));
        QVERIFY(f->shown.last().canNext);

        if (player.playing()) player.playPause();
        QTRY_VERIFY(f->shown.last().playback != MediaSessionState::Playback::Playing);
        session.handle(MediaSession::Command::Next);
        QTRY_COMPARE(f->shown.last().title, QStringLiteral("T12"));
        QVERIFY(!player.playing());
        QVERIFY(!f->shown.last().canNext);
    }

    void thereIsNoPlatformBackendOnLinux() {
#ifdef Q_OS_LINUX
        MediaSession session;
        QVERIFY(!MediaSession::createPlatformBackend(&session, nullptr));
#else
        QSKIP("a platform with media controls");
#endif
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestMediaSession)
#include "tst_media_session.moc"
