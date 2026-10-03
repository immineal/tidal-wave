// The busy flag around a track change.
//
// `loading` is what the now-playing spinner and the player bar read, and it is
// the one piece of player state that is set and cleared from two directions at
// once: loadAndPlay() raises it, and QMediaPlayer's own media-status changes
// lower it. The order of those two is the whole of this file - raising it
// before stop() means stop() reports LoadedMedia and lowers it again, leaving
// the app "not loading" for the entire fetch of the next track.
//
// The QMediaPlayer under test is the real one the Player owns, reached as its
// child, and it is fed a locally generated silent WAV. No network and no
// fixture out of the user's library.

#include <QTest>
#include <QDataStream>
#include <QFile>
#include <QMediaPlayer>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QSettings>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

QVariantMap trackOf(qlonglong id) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("A Title");
    t[QStringLiteral("artists")]    = QStringLiteral("An Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("A Record");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 200;
    return t;
}

// Half a minute of silence: valid and decodable by any backend, and long
// enough that nothing here races its end of media (which would advance the
// queue underneath the measurement).
bool writeSilentWav(const QString &path) {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * 30 * channels * bits / 8;

    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };

    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16)                            // chunk size
      << quint16(1) << quint16(channels)        // PCM, mono
      << rate << quint32(rate * channels * bits / 8)
      << quint16(channels * bits / 8) << quint16(bits);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(bytes, '\0').constData(), int(bytes));

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    return f.write(d) == d.size();
}

} // namespace

class TestPlayerLoading : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_player_loading"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        m_wav = m_dir.filePath(QStringLiteral("silence.wav"));
        QVERIFY2(writeSilentWav(m_wav), "the test could not write its own audio file");
    }

    void startingATrackStaysLoadingUntilSomethingSaysOtherwise() {
        TidalApi    api;
        TidalClient client{&api};
        Player      player{&client};
        // Player defers its audio init to the event loop (a PipeWire deadlock
        // guard), so the QMediaPlayer does not exist until that has run.
        QTest::qWait(30);

        auto *mp = player.findChild<QMediaPlayer *>();
        QVERIFY2(mp, "the Player has no QMediaPlayer");

        // Get the player into the state a user is actually in when they pick
        // the next track: something is loaded and playing.
        mp->setSource(QUrl::fromLocalFile(m_wav));
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::LoadedMedia
                                 || mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);
        mp->play();
        QTRY_VERIFY_WITH_TIMEOUT(mp->mediaStatus() == QMediaPlayer::BufferedMedia, 5000);
        QVERIFY2(!player.loading(), "the player is still busy with the file it has loaded");

        // Picking a track. The manifest fetch behind it is a network call that
        // cannot complete here, which is exactly the window being measured:
        // for as long as it is out, the app has to say it is loading.
        player.playTracks(QVariantList{ trackOf(4242) }, 0);

        QVERIFY2(player.loading(),
                 "the player stopped reporting a load the instant it started one: "
                 "stop()/setSource() reported LoadedMedia and cleared the flag");
    }

private:
    QTemporaryDir m_dir;
    QString       m_wav;
};

QTEST_MAIN(TestPlayerLoading)
#include "tst_player_loading.moc"
