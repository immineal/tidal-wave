// Loudness normalisation, the format badge's text and autoplay at the end of
// the queue. The tracks are silent WAV files handed out as Tidal's lossy tier
// hands out a whole file; the Player is muted throughout.

#include <QTest>
#include <QAudio>
#include <QAudioOutput>
#include <QDataStream>
#include <QFile>
#include <QLocale>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <cmath>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "ui/Prefs.h"

namespace {

QByteArray silentWav(int ms) {
    const quint32 rate = 8000;
    const quint32 bytes = rate * quint32(ms) / 1000 * 2;
    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };
    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16) << quint16(1) << quint16(1) << rate << quint32(rate * 2)
      << quint16(2) << quint16(16);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(int(bytes), '\0').constData(), int(bytes));
    return d;
}

class FileClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    QString file;
    StreamManifest base;
    QList<Track> radio;
    int radioAsked = 0;
    qint64 radioSeed = 0;
    void fetchStreamManifest(qint64, StreamCb cb) override {
        StreamManifest m = base;
        m.type     = StreamManifest::BTS;
        m.url      = QUrl::fromLocalFile(file).toString();
        m.mimeType = QStringLiteral("audio/wav");
        if (m.codec.isEmpty()) m.codec = QStringLiteral("HIGH");
        cb(m, {});
    }
    void fetchTrackRadio(qint64 trackId, TracksCallback cb) override {
        ++radioAsked;
        radioSeed = trackId;
        cb(radio, {});
    }
};

QVariantMap row(qlonglong id, qlonglong albumId = 7, int seconds = 1) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumId")]    = albumId;
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("duration")]   = seconds;
    return t;
}

Track radioTrack(qlonglong id) {
    Track t;
    t.id = id;
    t.title = QStringLiteral("R%1").arg(id);
    t.duration = 1;
    Artist a; a.name = QStringLiteral("Artist"); a.id = 3;
    t.artists.append(a);
    t.streamable = true;
    return t;
}

double level(double slider) {
    return QAudio::convertVolume(float(slider), QAudio::LogarithmicVolumeScale,
                                 QAudio::LinearVolumeScale);
}

} // namespace

class TestPlaybackOptions : public QObject {
    Q_OBJECT

    struct Rig {
        TidalApi   api;
        FileClient client{&api};
        Prefs      prefs;
        Player     player{&client};
        explicit Rig(const QString &file) {
            client.file = file;
            player.setPrefs(&prefs);
            player.setMuted(true);
            player.setVolume(0.5);
        }
        QAudioOutput *out() { return player.findChild<QAudioOutput *>(); }
        bool up() { return QTest::qWaitFor([this] { return out() != nullptr; }, 10000); }
        // The track's manifest has come and its file is loaded.
        bool loaded() {
            return QTest::qWaitFor([this] {
                auto *mp = player.findChild<QMediaPlayer *>();
                return mp && mp->duration() > 0 && !player.audioQuality().isEmpty();
            }, 10000);
        }
    };

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_playback_options"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        // The kHz figure is written in the user's locale; these expect English.
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif
        auto write = [this](const QString &name, int ms) {
            QFile f(m_dir.filePath(name));
            const QByteArray b = silentWav(ms);
            return f.open(QIODevice::WriteOnly) && f.write(b) == b.size();
        };
        QVERIFY(write(QStringLiteral("short.wav"), 1000));
        QVERIFY(write(QStringLiteral("long.wav"), 6500));
    }

    void init() { QSettings().clear(); }

    // ── loudness ────────────────────────────────────────────────────────────

    void theTracksGainScalesTheOutput_data() {
        QTest::addColumn<double>("gainDb");
        QTest::addColumn<double>("peak");
        QTest::addColumn<bool>("on");
        QTest::addColumn<double>("factor");
        QTest::newRow("-6 dB")              << -6.0 << 0.3 << true  << std::pow(10.0, -6.0 / 20.0);
        QTest::newRow("+6 dB, peak caps it") << 6.0 << 0.8 << true  << 1.25;
        QTest::newRow("+2 dB, room to spare") << 2.0 << 0.5 << true << std::pow(10.0, 2.0 / 20.0);
        QTest::newRow("switched off")       << -6.0 << 0.3 << false << 1.0;
        QTest::newRow("no gain from Tidal")  << 0.0 << 0.0 << true  << 1.0;
    }
    void theTracksGainScalesTheOutput() {
        QFETCH(double, gainDb);
        QFETCH(double, peak);
        QFETCH(bool, on);
        QFETCH(double, factor);
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.prefs.setNormalizeLoudness(on);
        r.client.base.replayGainTrack = gainDb;
        r.client.base.peakTrack       = peak;
        r.client.base.replayGainAlbum = -1.0;
        QVERIFY(r.up());
        r.player.playTracks({ row(1) }, 0);
        QVERIFY(r.loaded());
        QVERIFY2(std::fabs(r.player.trackGain() - factor) < 1e-3,
                 qPrintable(QStringLiteral("gain %1, wanted %2").arg(r.player.trackGain()).arg(factor)));
        QVERIFY(std::fabs(r.out()->volume() - level(0.5) * factor) < 1e-3);
        // The slider still moves it.
        r.player.setVolume(0.2);
        QVERIFY(std::fabs(r.out()->volume() - level(0.2) * factor) < 1e-3);
        // Switched over while it plays.
        r.prefs.setNormalizeLoudness(!on);
        const double other = on ? 1.0 : std::pow(10.0, gainDb / 20.0);
        QVERIFY(std::fabs(r.out()->volume() - qMin(1.0, level(0.2) * qMin(other, peak > 0 ? 1.0 / peak : 1e9))) < 1e-3);
    }

    // An album played from its page in its order takes the album's gain, so
    // its quiet tracks stay quiet. Shuffled, each track has its own.
    void anAlbumInOrderTakesTheAlbumGain() {
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.client.base.replayGainTrack = -8.0;
        r.client.base.replayGainAlbum = -3.0;
        QVERIFY(r.up());
        r.player.setPlaybackSource(QStringLiteral("album"), QStringLiteral("7"), QStringLiteral("Album"));
        r.player.playTracks({ row(1), row(2) }, 0);
        QVERIFY(r.loaded());
        QVERIFY(std::fabs(r.player.trackGain() - std::pow(10.0, -3.0 / 20.0)) < 1e-3);
        r.player.setShuffle(true);
        QVERIFY(std::fabs(r.player.trackGain() - std::pow(10.0, -8.0 / 20.0)) < 1e-3);
    }

    // ── the badge ───────────────────────────────────────────────────────────

    void theFormatReadsAsTheStreamIs_data() {
        QTest::addColumn<QString>("format");
        QTest::addColumn<QString>("tier");
        QTest::addColumn<int>("rate");
        QTest::addColumn<int>("depth");
        QTest::addColumn<int>("bandwidth");
        QTest::addColumn<QString>("label");
        QTest::newRow("CD")      << "FLAC" << "LOSSLESS" << 44100 << 16 << 0 << "16-bit / 44.1 kHz FLAC";
        QTest::newRow("hi-res")  << "FLAC_HIRES" << "HI_RES_LOSSLESS" << 96000 << 24 << 0 << "24-bit / 96 kHz FLAC";
        QTest::newRow("192")     << "FLAC_HIRES" << "HI_RES_LOSSLESS" << 192000 << 24 << 0 << "24-bit / 192 kHz FLAC";
        QTest::newRow("AAC, stated") << "AACLC" << "HIGH" << 44100 << 16 << 320000 << "AAC 320 kbps";
        QTest::newRow("AAC, tier")   << "AACLC" << "HIGH" << 44100 << 16 << 0 << "AAC 320 kbps";
        QTest::newRow("HE-AAC")      << "HEAACV1" << "LOW" << 44100 << 16 << 0 << "HE-AAC 96 kbps";
        QTest::newRow("v1, no format") << "" << "HIGH" << 44100 << 16 << 0 << "AAC 320 kbps";
        QTest::newRow("unknown")     << "" << "SOMETHING" << 0 << 0 << 0 << "";
    }
    void theFormatReadsAsTheStreamIs() {
        QFETCH(QString, format);
        QFETCH(QString, tier);
        QFETCH(int, rate);
        QFETCH(int, depth);
        QFETCH(int, bandwidth);
        QFETCH(QString, label);
        StreamManifest m;
        m.format = format; m.codec = tier; m.sampleRate = rate; m.bitDepth = depth;
        m.bandwidth = bandwidth;
        QCOMPARE(Player::formatLabel(m), label);
    }

    // The Player puts the playing stream's format on its property.
    void thePlayerTellsTheFormatOfItsStream() {
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.client.base.codec = QStringLiteral("HI_RES_LOSSLESS");
        r.client.base.format = QStringLiteral("FLAC_HIRES");
        r.client.base.sampleRate = 96000;
        r.client.base.bitDepth = 24;
        QVERIFY(r.up());
        QCOMPARE(r.player.audioFormat(), QString());
        r.player.playTracks({ row(1) }, 0);
        QVERIFY(r.loaded());
        QCOMPARE(r.player.audioFormat(), QStringLiteral("24-bit / 96 kHz FLAC"));
    }

    // ── autoplay ────────────────────────────────────────────────────────────

    // The last track ran out before its radio was asked for: the radio is
    // asked then, its tracks join the queue, and the first of them plays.
    void theQueueGoesOnWithTheRadioOfItsLastTrack() {
        if (const char *why = obstacle()) QSKIP(why);
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.client.radio = { radioTrack(1), radioTrack(21), radioTrack(22) };
        r.prefs.setAutoplay(true);
        QVERIFY(r.up());
        r.player.playTracks({ row(1) }, 0);
        QTRY_COMPARE_WITH_TIMEOUT(r.client.radioAsked, 1, 10000);
        QCOMPARE(r.client.radioSeed, qint64(1));
        // The seed itself is in the queue already and is not added again.
        QTRY_COMPARE_WITH_TIMEOUT(r.player.queueCount(), 3, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(r.player.currentTrackMap().value(QStringLiteral("id")).toLongLong(),
                                  qlonglong(21), 10000);
        QVERIFY(r.player.currentTrackMap().value(QStringLiteral("autoplay")).toBool());
        QVERIFY(!r.player.stopped());
    }

    // A track long enough asks for the radio while it plays, so the queue
    // never runs out.
    void theRadioIsFetchedWhileTheLastTrackPlays() {
        if (const char *why = obstacle()) QSKIP(why);
        Rig r(m_dir.filePath(QStringLiteral("long.wav")));
        r.client.radio = { radioTrack(31) };
        r.prefs.setAutoplay(true);
        QVERIFY(r.up());
        r.player.playTracks({ row(1, 7, 7) }, 0);
        QTRY_COMPARE_WITH_TIMEOUT(r.client.radioAsked, 1, 12000);
        QCOMPARE(r.player.queueCount(), 2);
        QCOMPARE(r.player.currentTrackMap().value(QStringLiteral("id")).toLongLong(), qlonglong(1));
    }

    void withAutoplayOffTheQueueStops() {
        if (const char *why = obstacle()) QSKIP(why);
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.prefs.setAutoplay(false);
        r.client.radio = { radioTrack(21) };
        QVERIFY(r.up());
        r.player.playTracks({ row(1) }, 0);
        QTRY_VERIFY_WITH_TIMEOUT(r.player.stopped(), 10000);
        QTest::qWait(300);
        QCOMPARE(r.client.radioAsked, 0);
        QCOMPARE(r.player.queueCount(), 1);
    }

    // Repeat goes round the queue, so autoplay has no end to follow.
    void repeatTakesPrecedence() {
        Rig r(m_dir.filePath(QStringLiteral("short.wav")));
        r.prefs.setAutoplay(true);
        r.player.setRepeatMode(1);
        r.client.radio = { radioTrack(21) };
        QVERIFY(r.up());
        r.player.playTracks({ row(1) }, 0);
        QTest::qWait(1800);
        QCOMPARE(r.client.radioAsked, 0);
    }

private:
    static const char *obstacle() {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
#endif
        return nullptr;
    }
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestPlaybackOptions)
#include "tst_playback_options.moc"
