// Seeking inside a lossless track, through the app's own Player. The fixture is
// FLAC in fragmented MP4, the layout DashFetcher writes. The Player's output is
// muted before it opens, so nothing here is audible.

#include <QTest>
#include <QByteArray>
#include <QFile>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QUrl>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

#include "progressive_fixture.inc"

// What one Player's QMediaPlayer did, as the test needs to ask about it.
struct Watch {
    explicit Watch(QMediaPlayer *mp)
    {
        QObject::connect(mp, &QMediaPlayer::positionChanged, mp, [this](qint64 pos) {
            if (pos > furthest) furthest = pos;
        });
        QObject::connect(mp, &QMediaPlayer::mediaStatusChanged, mp,
                         [this](QMediaPlayer::MediaStatus s) {
            if (s == QMediaPlayer::EndOfMedia) ended = true;
        });
    }
    // The Player stops at the end of an empty queue, which resets the position.
    qint64 furthest = 0;
    bool   ended    = false;
};

} // namespace

class TestSeek : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_seek"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        m_track = m_dir.filePath(QStringLiteral("joined.mp4"));
        QFile f(m_track);
        QVERIFY(f.open(QIODevice::WriteOnly));
        for (int i = 0; i < kProgSegmentCount; ++i)
            f.write(QByteArray::fromBase64(QByteArray(kProgSegmentsB64[i])));
    }

    // Twice, because the second seek is the one made after a seek.
    void aSeekWhilePlayingPlaysOnToTheEndOfTheTrack()
    {
        if (const char *why = obstacle()) QSKIP(why);
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QMediaPlayer *mp = startPlaying(player);
        QVERIFY(mp);
        Watch watch(mp);

        // Long enough for a backend to have read all of so small a file.
        QTRY_VERIFY_WITH_TIMEOUT(mp->position() >= 500, 10000);

        QSignalSpy told(&player, &Player::playingChanged);
        player.seek(2000);
        QCOMPARE(told.count(), 0);
        QCOMPARE(mp->playbackState(), QMediaPlayer::PlayingState);
        QTRY_VERIFY2_WITH_TIMEOUT(watch.furthest >= 2500,
                                  "the position stayed where the seek put it", 5000);

        watch.furthest = 0;
        player.seek(1000);
        QCOMPARE(told.count(), 0);
        QTRY_VERIFY2_WITH_TIMEOUT(watch.furthest >= 1500,
                                  "the position stayed where the second seek put it", 5000);

        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
        QVERIFY2(watch.furthest >= kProgDurationMs - 500,
                 qPrintable(QStringLiteral("the track ended at %1 ms").arg(watch.furthest)));
    }

    void aSeekWhilePausedStaysPaused()
    {
        if (const char *why = obstacle()) QSKIP(why);
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        QMediaPlayer *mp = startPlaying(player);
        QVERIFY(mp);
        Watch watch(mp);

        QTRY_VERIFY_WITH_TIMEOUT(mp->position() >= 300, 10000);
        mp->pause();
        QTRY_COMPARE_WITH_TIMEOUT(mp->playbackState(), QMediaPlayer::PausedState, 5000);

        player.seek(2000);
        QTest::qWait(400);
        QCOMPARE(mp->playbackState(), QMediaPlayer::PausedState);
        QVERIFY2(mp->position() < 2300,
                 qPrintable(QStringLiteral("paused, and yet at %1 ms").arg(mp->position())));

        mp->play();
        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
    }

private:
    // Why this Qt on this machine cannot run these tests, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // With no audio device one backend crashes in play() and the other
        // runs through the track unpaced.
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
        if (qgetenv("QT_MEDIA_BACKEND") != "ffmpeg")
            return "Qt 6.4's GStreamer backend loses its place in fragments that have no index";
#endif
        return nullptr;
    }

    // Loads the fixture into the Player's own QMediaPlayer and starts it.
    QMediaPlayer *startPlaying(Player &player)
    {
        player.setMuted(true);
        player.setVolume(0.0);
        // The Player builds its audio objects on the first turn of the loop.
        QTest::qWait(30);
        auto *mp = player.findChild<QMediaPlayer *>();
        if (!mp) return nullptr;
        mp->setSource(QUrl::fromLocalFile(m_track));
        mp->play();
        return mp;
    }

    QTemporaryDir m_dir;
    QString       m_track;
};

QTEST_MAIN(TestSeek)
#include "tst_seek.moc"
