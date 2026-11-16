// The format badge's text. The tracks are silent WAV files handed out as
// Tidal's lossy tier hands out a whole file; the Player is muted throughout.

#include <QTest>
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
    void fetchStreamManifest(qint64, StreamCb cb) override {
        StreamManifest m = base;
        m.type     = StreamManifest::BTS;
        m.url      = QUrl::fromLocalFile(file).toString();
        m.mimeType = QStringLiteral("audio/wav");
        if (m.codec.isEmpty()) m.codec = QStringLiteral("HIGH");
        cb(m, {});
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

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestPlaybackOptions)
#include "tst_playback_options.moc"
