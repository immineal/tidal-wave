// What reaches the sink across a track boundary: two tone tracks play into a
// null sink whose monitor is recorded. Runs only where tests/with-null-sink.sh
// made the sink tests_null, so nothing reaches a speaker.

#include <QTest>
#include <QAudioDevice>
#include <QAudioFormat>
#include <QAudioOutput>
#include <QProcess>
#include <QStandardPaths>
#include <QDataStream>
#include <QFile>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <cmath>
#include <functional>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "ui/Prefs.h"

namespace {

constexpr int    kRate      = 44100;
constexpr double kTone      = 0.5;     // amplitude of each track's sine
constexpr int    kFirstMs   = 7000;    // past the preload's five seconds
constexpr int    kSecondMs  = 2500;
constexpr int    kLongMs    = 9000;    // room for a crossfade after the preload
// A sine at kTone dips below this for a few samples at each crossing; a
// run longer than kGapRunMs of it is a gap.
constexpr double kQuiet     = 0.02;
constexpr double kGapRunMs  = 1.0;

QByteArray toneWav(int ms, double hz) {
    const quint32 frames = quint32(qint64(kRate) * ms / 1000);
    const quint32 bytes  = frames * 2 * 2;
    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };
    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16) << quint16(1) << quint16(2) << quint32(kRate)
      << quint32(kRate * 4) << quint16(4) << quint16(16);
    tag("data"); s << bytes;
    for (quint32 i = 0; i < frames; ++i) {
        const qint16 v = qint16(std::lround(kTone * 32767.0 * std::sin(2 * M_PI * hz * i / kRate)));
        s << v << v;
    }
    return d;
}

// Hands out each track's WAV as a whole file, as Tidal's lossy tier does.
class FileClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    QHash<qlonglong, QString> files;
    StreamManifest base;
    void fetchStreamManifest(qint64 trackId, StreamCb cb) override {
        StreamManifest m = base;
        m.type = StreamManifest::BTS;
        m.url  = QUrl::fromLocalFile(files.value(trackId)).toString();
        m.mimeType = QStringLiteral("audio/wav");
        if (m.codec.isEmpty()) m.codec = QStringLiteral("LOSSLESS");
        cb(m, {});
    }
    // No autoplay request leaves the test.
    void fetchTrackRadio(qint64, TracksCallback cb) override { cb({}, {}); }
};

QVariantMap row(qlonglong id, int ms, qlonglong albumId = 7) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("albumId")]    = albumId;
    t[QStringLiteral("duration")]   = (ms + 999) / 1000;
    return t;
}

QAudioDevice nullSink() {
    for (const QAudioDevice &d : QMediaDevices::audioOutputs())
        if (d.id().contains("tests_null") && !d.id().contains("tests_null_2")) return d;
    return {};
}

// Records the sink's monitor with parec, as mono 32-bit float. Qt does not
// list monitors among its inputs.
class Recorder {
public:
    bool start(const QAudioDevice &sink) {
        const QString parec = QStandardPaths::findExecutable(QStringLiteral("parec"));
        if (parec.isEmpty()) return false;
        m_proc.start(parec, { QStringLiteral("--device=") + QString::fromUtf8(sink.id()) + QStringLiteral(".monitor"),
                              QStringLiteral("--format=float32le"), QStringLiteral("--channels=1"),
                              QStringLiteral("--rate=%1").arg(kRate), QStringLiteral("--latency-msec=10"),
                              QStringLiteral("--raw") });
        // Started is not recording: parec on Debian 13 takes about 2 s to
        // deliver its first bytes, and a track played meanwhile loses its start.
        return m_proc.waitForStarted(5000) && m_proc.waitForReadyRead(10000);
    }
    QVector<double> stop() {
        m_proc.terminate();
        m_proc.waitForFinished(5000);
        const QByteArray raw = m_proc.readAllStandardOutput();
        QVector<double> out(raw.size() / 4);
        for (qsizetype i = 0; i < out.size(); ++i)
            out[i] = *reinterpret_cast<const float *>(raw.constData() + i * 4);
        return out;
    }
private:
    QProcess m_proc;
};

struct Measured {
    double soundMs  = 0;    // first loud sample to last
    double gapMs    = 0;    // longest quiet run in between
    double gapAtMs  = 0;    // where it starts, from the first loud sample
    double overlapMs = 0;   // both tones at once: louder than either alone
};

Measured measure(const QVector<double> &s, int rate) {
    Measured m;
    qsizetype first = -1, last = -1;
    for (qsizetype i = 0; i < s.size(); ++i)
        if (std::fabs(s[i]) > 0.2) { if (first < 0) first = i; last = i; }
    if (first < 0) return m;
    m.soundMs = double(last - first) * 1000.0 / rate;
    qsizetype run = 0, best = 0, bestAt = 0;
    for (qsizetype i = first; i <= last; ++i) {
        if (std::fabs(s[i]) < kQuiet) { ++run; if (run > best) { best = run; bestAt = i - run + 1; } }
        else run = 0;
    }
    const double bestMs = double(best) * 1000.0 / rate;
    m.gapMs   = bestMs >= kGapRunMs ? bestMs : 0.0;
    m.gapAtMs = double(bestAt - first) * 1000.0 / rate;
    qsizetype over0 = -1, over1 = -1;
    for (qsizetype i = first; i <= last; ++i)
        if (std::fabs(s[i]) > kTone * 1.2) { if (over0 < 0) over0 = i; over1 = i; }
    if (over0 >= 0) m.overlapMs = double(over1 - over0) * 1000.0 / rate;
    return m;
}

} // namespace

class TestGapless : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_gapless"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        QSKIP("Qt 6.4 changes tracks the old way, with a gap");
#endif
        auto write = [this](const QString &name, const QByteArray &bytes) {
            QFile f(m_dir.filePath(name));
            return f.open(QIODevice::WriteOnly) && f.write(bytes) == bytes.size();
        };
        QVERIFY(write(QStringLiteral("a.wav"), toneWav(kFirstMs, 1000.0)));
        QVERIFY(write(QStringLiteral("b.wav"), toneWav(kSecondMs, 1500.0)));
        QVERIFY(write(QStringLiteral("c.wav"), toneWav(kLongMs, 1000.0)));
    }

    void init() { QSettings().clear(); }

    // Two tracks of a queue follow each other with no silence in between:
    // the second is started on the first one's last sample.
    void theNextTrackFollowsWithoutAGap() {
        const Measured m = play(1, kFirstMs, 7, false);
        if (QTest::currentTestFailed() || m.soundMs == 0) return;
        QVERIFY2(m.gapMs <= kMaxGapMs,
                 qPrintable(QStringLiteral("%1 ms of silence between the tracks").arg(m.gapMs)));
        QVERIFY2(m.overlapMs <= kMaxOverlapMs,
                 qPrintable(QStringLiteral("the tracks overlapped for %1 ms").arg(m.overlapMs)));
        // And nothing was cut off: the old way on Qt 6.4 lost about 350 ms at the change.
        const double cut = kFirstMs + kSecondMs + m.gapMs - m.overlapMs - m.soundMs;
        QVERIFY2(cut <= kMaxCutMs, qPrintable(QStringLiteral("%1 ms were cut off").arg(cut)));
    }

    // Crossfade on, between tracks of two albums: the two sound together for
    // most of the fade, and there is still no silence.
    void aCrossfadeOverlapsTheTracks() {
        const Measured m = play(3, kLongMs, 8, true);
        if (QTest::currentTestFailed() || m.soundMs == 0) return;
        QVERIFY2(m.gapMs <= kMaxGapMs,
                 qPrintable(QStringLiteral("%1 ms of silence in the crossfade").arg(m.gapMs)));
        // 1.5 s, half the second track; both are louder than one for 70 % of it.
        QVERIFY2(m.overlapMs > 800 && m.overlapMs < 1500,
                 qPrintable(QStringLiteral("the tracks overlapped for %1 ms").arg(m.overlapMs)));
    }

    // Crossfade on, within one album played in order: gapless, as before.
    void anAlbumInOrderIsNotCrossfaded() {
        const Measured m = play(1, kFirstMs, 7, true);
        if (QTest::currentTestFailed() || m.soundMs == 0) return;
        QVERIFY2(m.gapMs <= kMaxGapMs,
                 qPrintable(QStringLiteral("%1 ms of silence between the tracks").arg(m.gapMs)));
        QVERIFY2(m.overlapMs <= kMaxOverlapMs,
                 qPrintable(QStringLiteral("the tracks overlapped for %1 ms").arg(m.overlapMs)));
        const double cut = kFirstMs + kSecondMs + m.gapMs - m.overlapMs - m.soundMs;
        QVERIFY2(cut <= kMaxCutMs, qPrintable(QStringLiteral("%1 ms were cut off").arg(cut)));
    }

private:
    // Plays track `first` of album `firstAlbum`, `firstMs` long, then track 2
    // of album 7, the album that plays, and records what the sink played.
    Measured play(qlonglong first, int firstMs, qlonglong firstAlbum, bool crossfade) {
        const QAudioDevice sink = nullSink();
        if (sink.isNull()) { QTest::qSkip("needs a null sink called tests_null: run under tests/with-null-sink.sh", __FILE__, __LINE__); return {}; }

        Prefs prefs;
        prefs.setAudioDevice(QString::fromUtf8(sink.id()));
        prefs.setNormalizeLoudness(false);
        prefs.setCrossfade(crossfade);
        prefs.setCrossfadeSeconds(2);
        TidalApi api;
        FileClient client{&api};
        client.files[1] = m_dir.filePath(QStringLiteral("a.wav"));
        client.files[2] = m_dir.filePath(QStringLiteral("b.wav"));
        client.files[3] = m_dir.filePath(QStringLiteral("c.wav"));
        Player player{&client};
        player.setPrefs(&prefs);
        player.setPlaybackSource(QStringLiteral("album"), QStringLiteral("7"), QStringLiteral("Album"));
        [&] { QTRY_VERIFY_WITH_TIMEOUT(player.findChild<QMediaPlayer *>(), 10000); }();
        if (QTest::currentTestFailed()) return {};
        // Never louder than this anywhere but on the null sink.
        [&] { QCOMPARE(player.activeAudioDeviceId(), QString::fromUtf8(sink.id())); }();
        if (QTest::currentTestFailed()) return {};
        player.setVolume(1.0);
        player.setMuted(false);

        Recorder rec;
        if (!rec.start(sink)) { player.setMuted(true); QTest::qSkip("needs parec to record the null sink", __FILE__, __LINE__); return {}; }
        QTest::qWait(300);

        bool secondPlayed = false;
        connect(&player, &Player::currentTrackChanged, this, [&] {
            if (player.currentTrackMap().value(QStringLiteral("id")).toLongLong() == 2) secondPlayed = true;
        });
        player.playTracks(QVariantList{ row(first, firstMs, firstAlbum), row(2, kSecondMs) }, 0);
        [&] {
            QTRY_VERIFY_WITH_TIMEOUT(secondPlayed, firstMs + 8000);
            QTRY_VERIFY_WITH_TIMEOUT(player.stopped(), kSecondMs + 8000);
        }();
        QTest::qWait(300);
        player.setMuted(true);
        const Measured m = measure(rec.stop(), kRate);
        qInfo("sounded for %.1f ms of %d ms; longest silence %.1f ms at %.1f ms; overlap %.1f ms",
              m.soundMs, firstMs + kSecondMs, m.gapMs, m.gapAtMs, m.overlapMs);
        if (QTest::currentTestFailed()) return {};
        [&] { QVERIFY2(m.soundMs > 0.7 * (firstMs + kSecondMs), "the capture holds too little sound"); }();
        return m;
    }

    // The second backend sounds within about 15 ms either side of the old
    // one's end (tst_gapless on a null sink). Before, the gap was 60 ms or more.
    static constexpr double kMaxGapMs     = 30.0;
    static constexpr double kMaxOverlapMs = 40.0;
    static constexpr double kMaxCutMs     = 60.0;
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestGapless)
#include "tst_gapless.moc"
