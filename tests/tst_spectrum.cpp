// The five now-playing bars, driven by the audio. Buffers from
// QAudioBufferOutput arrive in whatever format the decoder produced, or with no
// format at all, and each must land on five numbers in 0..1 or be dropped
// without a crash. processBuffer() is synchronous, so only the emission rate
// needs an event loop, and the file also runs on Qt 6.4, where
// QAudioBufferOutput does not exist and the feature is inert.

#include <QTest>
#include <QAudioBuffer>
#include <QCoreApplication>
#include <QDataStream>
#include <QFile>
#include <QMediaPlayer>
#include <QSettings>
#include <QTemporaryDir>
#include <QUrl>
#include <QAudioFormat>
#include <QByteArray>
#include <QSignalSpy>
#include <QVariantList>
#include <cmath>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "player/SpectrumAnalyzer.h"
#if TIDALWAVE_HAS_BUFFER_OUTPUT
#include <QAudioBufferOutput>
#endif

namespace {

// A stand-in for Prefs carrying just the one property the analyser reads, so
// the pref wiring can be exercised without the real settings file.
class StubSpectrumPref : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool spectrumBars READ spectrumBars WRITE setSpectrumBars NOTIFY spectrumBarsChanged)
public:
    using QObject::QObject;
    bool spectrumBars() const { return m_on; }
    void setSpectrumBars(bool v) {
        if (v == m_on) return;
        m_on = v;
        emit spectrumBarsChanged();
    }
signals:
    void spectrumBarsChanged();
private:
    bool m_on = false;
};

// A source that does not carry the property at all.
class StubEmptyPref : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
};

// ─── buffer building ────────────────────────────────────────────────────────

// Interleaves `frames` frames of a sine at `hz` into the sample format asked
// for. Amplitude is in 0..1 of full scale, the same level in every format.
QAudioBuffer toneBuffer(double hz, double amplitude, int frames, int rate,
                        int channels, QAudioFormat::SampleFormat sampleFormat,
                        qint64 startFrame = 0)
{
    QAudioFormat fmt;
    fmt.setSampleRate(rate);
    fmt.setChannelCount(channels);
    fmt.setSampleFormat(sampleFormat);

    const int bytesPerSample = fmt.bytesPerSample();
    QByteArray bytes(qsizetype(frames) * channels * bytesPerSample, Qt::Uninitialized);
    char *out = bytes.data();

    for (int f = 0; f < frames; ++f) {
        const double t = double(startFrame + f) / double(rate);
        const double v = amplitude * std::sin(2.0 * M_PI * hz * t);
        for (int c = 0; c < channels; ++c) {
            switch (sampleFormat) {
            case QAudioFormat::UInt8: {
                // Unsigned, centred on 128.
                const int s = int(std::lround(v * 127.0)) + 128;
                *reinterpret_cast<quint8 *>(out) = quint8(qBound(0, s, 255));
                break;
            }
            case QAudioFormat::Int16: {
                const int s = int(std::lround(v * 32767.0));
                *reinterpret_cast<qint16 *>(out) = qint16(qBound(-32768, s, 32767));
                break;
            }
            case QAudioFormat::Int32: {
                const double s = std::round(v * 2147483647.0);
                *reinterpret_cast<qint32 *>(out) = qint32(qBound(-2147483648.0, s, 2147483647.0));
                break;
            }
            case QAudioFormat::Float:
            default:
                *reinterpret_cast<float *>(out) = float(v);
                break;
            }
            out += bytesPerSample;
        }
    }
    return QAudioBuffer(bytes, fmt);
}

QAudioBuffer silenceBuffer(int frames, int rate, int channels,
                           QAudioFormat::SampleFormat sampleFormat)
{
    return toneBuffer(0.0, 0.0, frames, rate, channels, sampleFormat);
}

// Feeds `seconds` worth of a tone in decoder-sized chunks, so the analyser sees
// partial frames as it does in the app.
void feedTone(SpectrumAnalyzer &a, double hz, double amplitude, double seconds,
              int rate, int channels, QAudioFormat::SampleFormat sampleFormat,
              int chunkFrames = 940)
{
    qint64 frame = 0;
    const qint64 total = qint64(seconds * rate);
    while (frame < total) {
        const int n = int(qMin<qint64>(chunkFrames, total - frame));
        a.processBuffer(toneBuffer(hz, amplitude, n, rate, channels, sampleFormat, frame));
        frame += n;
    }
}

// A 16-bit stereo PCM WAV on disk, for the one case that goes through a real
// QMediaPlayer rather than handing the analyser buffers directly.
bool writeToneWav(const QString &path, double hz, double seconds, int rate)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    const int frames   = int(seconds * rate);
    const quint32 data = quint32(frames) * 2 * 2;

    const auto u32 = [&f](quint32 v) { f.write(reinterpret_cast<const char *>(&v), 4); };
    const auto u16 = [&f](quint16 v) { f.write(reinterpret_cast<const char *>(&v), 2); };

    f.write("RIFF");      u32(36 + data);
    f.write("WAVEfmt ");  u32(16);
    u16(1);               // PCM
    u16(2);               // stereo
    u32(quint32(rate));
    u32(quint32(rate) * 4);
    u16(4);
    u16(16);
    f.write("data");      u32(data);
    for (int i = 0; i < frames; ++i) {
        const qint16 s =
            qint16(std::lround(0.8 * 32767.0 * std::sin(2.0 * M_PI * hz * i / rate)));
        f.write(reinterpret_cast<const char *>(&s), 2);
        f.write(reinterpret_cast<const char *>(&s), 2);
    }
    return true;
}

// Index of the band a frequency belongs to, straight off the analyser's own
// edge table, so the expectations below cannot drift away from the DSP.
int bandOf(double hz)
{
    const QList<double> edges = SpectrumAnalyzer::bandEdgesHz();
    for (int i = 0; i + 1 < edges.size(); ++i)
        if (hz >= edges[i] && hz < edges[i + 1]) return i;
    return -1;
}

} // namespace

class TestSpectrum : public QObject {
    Q_OBJECT

private slots:
    void anAnalyserStartsSilentAndIdle();
    void silenceStaysSilent();
    void silenceStaysSilent_data();

    void aToneLightsItsOwnBandOnly();
    void aToneLightsItsOwnBandOnly_data();

    void everyBandCanBeLit();
    void everyBandCanBeLit_data();

    void louderReadsHigher();
    void levelsNeverLeaveTheUnitRange();

    void aBrokenBufferIsDroppedNotGuessedAt();
    void aBrokenBufferIsDroppedNotGuessedAt_data();

    void nothingIsComputedWhileDisabled();
    void disablingClearsWhatWasThere();
    void theLevelsDecayWhenTheMusicStops();

    void thePrefDrivesTheSwitch();
    void aPrefSourceWithoutThePropertyIsOff();
    void theFeatureIsInertWithoutQt68();

    void theChangeSignalIsRatedNotPerBuffer();
    void activeFollowsTheAudio();

    void theSingletonIsTheOneQmlSees();

    // Last, and in this order: they are the only cases that touch the
    // process-wide analyser, and theSingletonIsTheOneQmlSees() above asserts
    // that nothing before them did.
    void initTestCase();
    void theTapIsOnlyAttachedWhileTheSwitchIsOn();
    void aRealDecodedStreamLightsTheRightBand();
    void switchingOnMidTrackTakesEffectOnTheNextOne();
    void cleanup();

private:
    QTemporaryDir m_settingsDir;
};

// A Player writes its session to QSettings on the way out, so the one case
// below that builds a real one gets a scratch settings file rather than the
// user's own.
void TestSpectrum::initTestCase()
{
    QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_spectrum"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QVERIFY(m_settingsDir.isValid());
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsDir.path());
}

// Leaves the singleton as it was found, so a case added after these ones does
// not inherit a running analyser.
void TestSpectrum::cleanup()
{
    SpectrumAnalyzer::instance()->setEnabled(false);
}

// ─── the resting state ──────────────────────────────────────────────────────

// Off is the shipped state, and off means five hard zeros and `active` false.
// The QML reads `active` to decide whether to take its heights from here.
void TestSpectrum::anAnalyserStartsSilentAndIdle()
{
    SpectrumAnalyzer a(nullptr);
    QVERIFY(!a.enabled());
    QVERIFY(!a.active());
    QCOMPARE(a.levels().size(), SpectrumAnalyzer::kBands);
    for (const QVariant &v : a.levels())
        QCOMPARE(v.toDouble(), 0.0);
}

void TestSpectrum::silenceStaysSilent_data()
{
    QTest::addColumn<int>("rate");
    QTest::addColumn<int>("channels");
    QTest::addColumn<QAudioFormat::SampleFormat>("sampleFormat");

    QTest::newRow("float mono 44100")   << 44100 << 1 << QAudioFormat::Float;
    QTest::newRow("int16 stereo 44100") << 44100 << 2 << QAudioFormat::Int16;
    QTest::newRow("int32 stereo 96000") << 96000 << 2 << QAudioFormat::Int32;
    QTest::newRow("uint8 mono 22050")   << 22050 << 1 << QAudioFormat::UInt8;
}

// Digital silence comes out as exact zeros in every format, including UInt8,
// where silence is the byte 128 and a missing bias correction reads as DC.
void TestSpectrum::silenceStaysSilent()
{
    QFETCH(int, rate);
    QFETCH(int, channels);
    QFETCH(QAudioFormat::SampleFormat, sampleFormat);

    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    for (int i = 0; i < 40; ++i)
        a.processBuffer(silenceBuffer(1024, rate, channels, sampleFormat));

    const QList<double> levels = a.bandLevels();
    QCOMPARE(levels.size(), SpectrumAnalyzer::kBands);
    for (int i = 0; i < levels.size(); ++i)
        QVERIFY2(levels[i] == 0.0,
                 qPrintable(QStringLiteral("band %1 read %2 on silence")
                                .arg(i).arg(levels[i])));
}

// ─── tones ──────────────────────────────────────────────────────────────────

void TestSpectrum::aToneLightsItsOwnBandOnly_data()
{
    QTest::addColumn<int>("rate");
    QTest::addColumn<int>("channels");
    QTest::addColumn<QAudioFormat::SampleFormat>("sampleFormat");

    // The formats a Tidal stream can actually decode to, plus the two the
    // backend may hand over on other platforms.
    QTest::newRow("float mono 44100")    << 44100 << 1 << QAudioFormat::Float;
    QTest::newRow("float stereo 44100")  << 44100 << 2 << QAudioFormat::Float;
    QTest::newRow("int16 mono 44100")    << 44100 << 1 << QAudioFormat::Int16;
    QTest::newRow("int16 stereo 44100")  << 44100 << 2 << QAudioFormat::Int16;
    QTest::newRow("int16 stereo 48000")  << 48000 << 2 << QAudioFormat::Int16;
    QTest::newRow("int32 stereo 96000")  << 96000 << 2 << QAudioFormat::Int32;
    QTest::newRow("float stereo 192000") << 192000 << 2 << QAudioFormat::Float;
    QTest::newRow("uint8 mono 22050")    << 22050 << 1 << QAudioFormat::UInt8;
}

// 1 kHz in, one bar up. 1 kHz sits inside the middle band (450-1400 Hz) with
// better than a third of an octave of margin either side. Run across every
// sample format, because a wrong conversion still yields a plausible spectrum.
void TestSpectrum::aToneLightsItsOwnBandOnly()
{
    QFETCH(int, rate);
    QFETCH(int, channels);
    QFETCH(QAudioFormat::SampleFormat, sampleFormat);

    const double hz = 1000.0;
    const int expected = bandOf(hz);
    QCOMPARE(expected, 2);

    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    feedTone(a, hz, 0.8, 0.8, rate, channels, sampleFormat);

    const QList<double> levels = a.bandLevels();
    QVERIFY2(levels[expected] > 0.5,
             qPrintable(QStringLiteral("the 1 kHz band only reached %1")
                            .arg(levels[expected])));
    for (int i = 0; i < levels.size(); ++i) {
        if (i == expected) continue;
        QVERIFY2(levels[i] < 0.2,
                 qPrintable(QStringLiteral("band %1 leaked to %2 from a 1 kHz tone")
                                .arg(i).arg(levels[i])));
    }
}

void TestSpectrum::everyBandCanBeLit_data()
{
    QTest::addColumn<double>("hz");
    QTest::newRow("80 Hz")    << 80.0;
    QTest::newRow("260 Hz")   << 260.0;
    QTest::newRow("1 kHz")    << 1000.0;
    QTest::newRow("2.4 kHz")  << 2400.0;
    QTest::newRow("7 kHz")    << 7000.0;
}

// One tone per band, each near the geometric centre of its own, which pins the
// mapping of frequencies to bars.
void TestSpectrum::everyBandCanBeLit()
{
    QFETCH(double, hz);
    const int expected = bandOf(hz);
    QVERIFY2(expected >= 0, "the test tone fell outside every band");

    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    feedTone(a, hz, 0.8, 0.8, 44100, 2, QAudioFormat::Float);

    const QList<double> levels = a.bandLevels();
    int loudest = 0;
    for (int i = 1; i < levels.size(); ++i)
        if (levels[i] > levels[loudest]) loudest = i;

    QCOMPARE(loudest, expected);
    QVERIFY2(levels[expected] > 0.4,
             qPrintable(QStringLiteral("band %1 only reached %2 at %3 Hz")
                            .arg(expected).arg(levels[expected]).arg(hz)));
}

// Monotonic in amplitude, so the bars read as a level meter.
void TestSpectrum::louderReadsHigher()
{
    const auto measure = [](double amplitude) {
        SpectrumAnalyzer a(nullptr);
        a.setEnabled(true);
        feedTone(a, 1000.0, amplitude, 0.8, 44100, 2, QAudioFormat::Float);
        return a.bandLevels()[2];
    };

    const double quiet = measure(0.02);
    const double mid   = measure(0.2);
    const double loud  = measure(0.9);

    QVERIFY2(quiet < mid, qPrintable(QStringLiteral("%1 !< %2").arg(quiet).arg(mid)));
    QVERIFY2(mid < loud,  qPrintable(QStringLiteral("%1 !< %2").arg(mid).arg(loud)));
}

// A bar is drawn as a fraction of its box, so a level outside 0..1 is a bar
// drawn outside the glyph or with a negative height.
void TestSpectrum::levelsNeverLeaveTheUnitRange()
{
    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);

    // Clipping-loud, ultrasonic and sub-audible in turn: three ways to push a
    // naive normalisation past full scale, or below zero.
    feedTone(a, 60.0, 1.0, 0.4, 44100, 2, QAudioFormat::Float);
    for (const double level : a.bandLevels()) {
        QVERIFY(level >= 0.0);
        QVERIFY(level <= 1.0);
    }
    feedTone(a, 19000.0, 1.0, 0.4, 44100, 2, QAudioFormat::Float);
    for (const double level : a.bandLevels()) {
        QVERIFY(level >= 0.0);
        QVERIFY(level <= 1.0);
    }
    // 5 Hz: below every band and below the window's own resolution, so it is
    // the closest thing to a DC offset a sine can be. A normalisation that
    // counted the DC bin would peg the bass bar on it.
    feedTone(a, 5.0, 1.0, 0.4, 44100, 2, QAudioFormat::Float);
    for (const double level : a.bandLevels()) {
        QVERIFY(level >= 0.0);
        QVERIFY(level <= 1.0);
    }
}

// ─── refusal ────────────────────────────────────────────────────────────────

void TestSpectrum::aBrokenBufferIsDroppedNotGuessedAt_data()
{
    QTest::addColumn<QAudioBuffer>("buffer");

    // What QAudioBufferOutput hands over before the pipeline has a format.
    QTest::newRow("default-constructed") << QAudioBuffer();

    // A valid container holding no frames: the end of a stream.
    QAudioFormat empty;
    empty.setSampleRate(44100);
    empty.setChannelCount(2);
    empty.setSampleFormat(QAudioFormat::Float);
    QTest::newRow("no frames") << QAudioBuffer(QByteArray(), empty, 0);

    // A format with no sample format at all: isValid() is false and
    // bytesPerSample() is 0, so anything that divides by it crashes.
    QAudioFormat unknown;
    unknown.setSampleRate(44100);
    unknown.setChannelCount(2);
    unknown.setSampleFormat(QAudioFormat::Unknown);
    QTest::newRow("unknown sample format")
        << QAudioBuffer(QByteArray(4096, '\0'), unknown, 0);

    // Nonsense that still type-checks: no channels, and no sample rate. Both
    // are divisors in the band mapping.
    QAudioFormat noChannels;
    noChannels.setSampleRate(44100);
    noChannels.setChannelCount(0);
    noChannels.setSampleFormat(QAudioFormat::Float);
    QTest::newRow("zero channels")
        << QAudioBuffer(QByteArray(4096, '\0'), noChannels, 0);

    QAudioFormat noRate;
    noRate.setSampleRate(0);
    noRate.setChannelCount(2);
    noRate.setSampleFormat(QAudioFormat::Float);
    QTest::newRow("zero sample rate")
        << QAudioBuffer(QByteArray(4096, '\0'), noRate, 0);
}

// None of these may crash, and none of them may move the bars.
void TestSpectrum::aBrokenBufferIsDroppedNotGuessedAt()
{
    QFETCH(QAudioBuffer, buffer);

    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    for (int i = 0; i < 50; ++i)
        a.processBuffer(buffer);

    for (const double level : a.bandLevels())
        QCOMPARE(level, 0.0);
    QVERIFY(!a.active());
}

// ─── the switch ─────────────────────────────────────────────────────────────

// Off means the DSP does not run. The observable half is asserted: a stream
// loud enough to peg a bar leaves every level at zero and emits nothing.
void TestSpectrum::nothingIsComputedWhileDisabled()
{
    SpectrumAnalyzer a(nullptr);
    QVERIFY(!a.enabled());

    QSignalSpy spy(&a, &SpectrumAnalyzer::levelsChanged);
    feedTone(a, 1000.0, 0.9, 1.0, 44100, 2, QAudioFormat::Float);

    for (const double level : a.bandLevels())
        QCOMPARE(level, 0.0);
    QCOMPARE(spy.count(), 0);
    QVERIFY(!a.active());
}

// Turning the preference off mid-track puts the bars back at zero with
// `active` false, where the QML's own animation takes over.
void TestSpectrum::disablingClearsWhatWasThere()
{
    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    feedTone(a, 1000.0, 0.9, 0.8, 44100, 2, QAudioFormat::Float);
    QVERIFY(a.bandLevels()[2] > 0.3);

    a.setEnabled(false);
    QVERIFY(!a.active());
    for (const double level : a.bandLevels())
        QCOMPARE(level, 0.0);
}

// The decay half of the envelope: the levels fall after the audio stops.
void TestSpectrum::theLevelsDecayWhenTheMusicStops()
{
    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    feedTone(a, 1000.0, 0.9, 0.8, 44100, 2, QAudioFormat::Float);
    const double peak = a.bandLevels()[2];
    QVERIFY(peak > 0.3);

    // Two frames of silence: enough to fall, not enough to reach zero.
    for (int i = 0; i < 2; ++i)
        a.processBuffer(silenceBuffer(512, 44100, 2, QAudioFormat::Float));
    const double after = a.bandLevels()[2];
    QVERIFY2(after < peak, qPrintable(QStringLiteral("%1 !< %2").arg(after).arg(peak)));
    QVERIFY2(after > 0.0, "the level fell to zero in two frames, which is a cut, not a decay");

    // ...and it does get all the way there.
    for (int i = 0; i < 200; ++i)
        a.processBuffer(silenceBuffer(512, 44100, 2, QAudioFormat::Float));
    QCOMPARE(a.bandLevels()[2], 0.0);
}

// The preference reaches the analyser through a by-name connection, as
// ThemePalette's theme source does, so a stub can stand in for Prefs.
void TestSpectrum::thePrefDrivesTheSwitch()
{
    StubSpectrumPref pref;
    SpectrumAnalyzer a(nullptr);
    QSignalSpy spy(&a, &SpectrumAnalyzer::enabledChanged);

    a.setPrefsSource(&pref);
    QVERIFY(!a.enabled());            // the stub starts off, as the real pref does

    pref.setSpectrumBars(true);
    QCOMPARE(a.enabled(), a.available());
    if (a.available()) QCOMPARE(spy.count(), 1);

    pref.setSpectrumBars(false);
    QVERIFY(!a.enabled());
}

// A preferences object without the property leaves the feature off and logs
// a warning.
void TestSpectrum::aPrefSourceWithoutThePropertyIsOff()
{
    StubEmptyPref pref;
    SpectrumAnalyzer a(nullptr);
    QTest::ignoreMessage(QtWarningMsg,
                         "SpectrumAnalyzer: preferences source has no \"spectrumBars\" property");
    a.setPrefsSource(&pref);
    QVERIFY(!a.enabled());
    QVERIFY(!a.active());
}

// Below Qt 6.8 there is no QAudioBufferOutput: the feature is reported
// unavailable and turning the preference on changes nothing. From 6.8 the same
// pref switches it on.
void TestSpectrum::theFeatureIsInertWithoutQt68()
{
    // Keyed to TIDALWAVE_HAS_BUFFER_OUTPUT, because the guard can be forced to
    // 0, which is how the pre-6.8 path is compiled and run against a newer Qt.
    QCOMPARE(SpectrumAnalyzer::availableAtCompileTime(),
             TIDALWAVE_HAS_BUFFER_OUTPUT != 0);

    StubSpectrumPref pref;
    SpectrumAnalyzer a(nullptr);
    a.setPrefsSource(&pref);
    pref.setSpectrumBars(true);
    QCOMPARE(a.enabled(), SpectrumAnalyzer::availableAtCompileTime());
}

// ─── rate ───────────────────────────────────────────────────────────────────

// The decoder hands over a buffer every few milliseconds. The levels are
// computed per frame and published on a tick of about 25 Hz.
void TestSpectrum::theChangeSignalIsRatedNotPerBuffer()
{
    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    QSignalSpy spy(&a, &SpectrumAnalyzer::levelsChanged);

    // About 2.7 s of audio in 128-frame chunks, fed synchronously, so the
    // publishing timer cannot run until the qWait below.
    feedTone(a, 1000.0, 0.8, 2.7, 44100, 2, QAudioFormat::Float, 128);
    QCOMPARE(spy.count(), 0);

    QTest::qWait(300);
    QVERIFY2(spy.count() >= 1, "nothing was published at all");
    QVERIFY2(spy.count() <= 20,
             qPrintable(QStringLiteral("%1 emissions in 300 ms is not a ~25 Hz tick")
                            .arg(spy.count())));
}

// `active` is what the QML switches on. It has to go false on its own when the
// audio stops: a paused track emits no buffers at all.
void TestSpectrum::activeFollowsTheAudio()
{
    SpectrumAnalyzer a(nullptr);
    a.setEnabled(true);
    QVERIFY(!a.active());

    feedTone(a, 1000.0, 0.8, 0.3, 44100, 2, QAudioFormat::Float);
    QVERIFY(a.active());

    // No buffers for longer than the idle window.
    QTest::qWait(SpectrumAnalyzer::kIdleTimeoutMs + 300);
    QVERIFY(!a.active());
    for (const double level : a.bandLevels())
        QCOMPARE(level, 0.0);
}

// The QML reads one global `Spectrum`, and Application wires the player into
// that same object. instance() and create() must hand back the same analyser.
void TestSpectrum::theSingletonIsTheOneQmlSees()
{
    SpectrumAnalyzer *first = SpectrumAnalyzer::instance();
    QVERIFY(first != nullptr);
    QCOMPARE(SpectrumAnalyzer::instance(), first);
    QCOMPARE(SpectrumAnalyzer::create(nullptr, nullptr), first);
    // Untouched by every case above, which all built their own analyser.
    QVERIFY(!first->enabled());
    QVERIFY(!first->active());
}

// With the switch off there is no QAudioBufferOutput attached to the
// QMediaPlayer at all, so nothing is decoded for the analyser. Below Qt 6.8
// there is nothing to attach and the answer is false whatever the switch says.
void TestSpectrum::theTapIsOnlyAttachedWhileTheSwitchIsOn()
{
    TidalApi api;
    TidalClient client(&api);
    Player player(&client);
    // Player defers its audio init by one event loop turn; there is no
    // QMediaPlayer to attach anything to until it has run.
    QTest::qWait(50);

    SpectrumAnalyzer *analyser = SpectrumAnalyzer::instance();
    QVERIFY(!analyser->enabled());
    QVERIFY(!player.spectrumTapAttached());

    analyser->setEnabled(true);
    QCOMPARE(player.spectrumTapAttached(), SpectrumAnalyzer::availableAtCompileTime());

    analyser->setEnabled(false);
    QVERIFY(!player.spectrumTapAttached());
}

// The one case with a real QMediaPlayer in the middle, to cover the join:
// whether QAudioBufferOutput delivers, and into what format. A 1 kHz WAV, so it
// needs no account, network or audio device. Skips where no buffers arrive.
void TestSpectrum::aRealDecodedStreamLightsTheRightBand()
{
#if !TIDALWAVE_HAS_BUFFER_OUTPUT
    QSKIP("QAudioBufferOutput needs Qt 6.8; the feature is unavailable in this build");
#else
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString wav = dir.filePath(QStringLiteral("tone.wav"));
    QVERIFY(writeToneWav(wav, 1000.0, 3.0, 44100));

    SpectrumAnalyzer analyser(nullptr);
    analyser.setEnabled(true);

    int delivered = 0;
    QMediaPlayer player;
    QAudioBufferOutput tap;
    connect(&tap, &QAudioBufferOutput::audioBufferReceived,
            &analyser, &SpectrumAnalyzer::processBuffer, Qt::QueuedConnection);
    connect(&tap, &QAudioBufferOutput::audioBufferReceived,
            this, [&delivered] { ++delivered; }, Qt::QueuedConnection);
    player.setAudioBufferOutput(&tap);
    player.setSource(QUrl::fromLocalFile(wav));
    player.play();

    bool lit = false;
    for (int i = 0; i < 60 && !lit; ++i) {
        QTest::qWait(50);
        lit = analyser.bandLevels()[2] > 0.5;
    }
    player.stop();

    if (delivered == 0)
        QSKIP("the multimedia backend delivered no audio buffers for a PCM WAV");

    QVERIFY2(lit, "a real 1 kHz stream never lit the band it belongs in");
    const QList<double> levels = analyser.bandLevels();
    for (int i = 0; i < levels.size(); ++i) {
        if (i == 2) continue;
        QVERIFY2(levels[i] < 0.25,
                 qPrintable(QStringLiteral("band %1 read %2 off a 1 kHz stream")
                                .arg(i).arg(levels[i])));
    }
#endif
}

// Attaching a QAudioBufferOutput to a QMediaPlayer that is already playing
// delivers no buffers for that track (ffmpeg backend, Qt 6.12). Only re-setting
// the source helps, so the feature starts at the next track.
void TestSpectrum::switchingOnMidTrackTakesEffectOnTheNextOne()
{
#if !TIDALWAVE_HAS_BUFFER_OUTPUT
    QSKIP("QAudioBufferOutput needs Qt 6.8; the feature is unavailable in this build");
#else
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString first  = dir.filePath(QStringLiteral("first.wav"));
    const QString second = dir.filePath(QStringLiteral("second.wav"));
    // Different bands, so "the next track is being analysed" is not something
    // a leftover level from the first one could fake.
    QVERIFY(writeToneWav(first,  1000.0, 6.0, 44100));
    QVERIFY(writeToneWav(second,  260.0, 6.0, 44100));
    QCOMPARE(bandOf(1000.0), 2);
    QCOMPARE(bandOf(260.0),  1);

    SpectrumAnalyzer analyser(nullptr);
    analyser.setEnabled(true);

    int delivered = 0;
    QMediaPlayer player;
    player.setSource(QUrl::fromLocalFile(first));
    player.play();
    QTest::qWait(700);
    if (player.playbackState() != QMediaPlayer::PlayingState)
        QSKIP("the multimedia backend would not play a PCM WAV");

    // The preference going on mid-track.
    QAudioBufferOutput tap;
    connect(&tap, &QAudioBufferOutput::audioBufferReceived,
            &analyser, &SpectrumAnalyzer::processBuffer, Qt::QueuedConnection);
    connect(&tap, &QAudioBufferOutput::audioBufferReceived,
            this, [&delivered] { ++delivered; }, Qt::QueuedConnection);
    player.setAudioBufferOutput(&tap);

    QTest::qWait(500);
    QVERIFY2(player.playbackState() == QMediaPlayer::PlayingState,
             "attaching the tap mid-track disturbed playback");
    QCOMPARE(player.error(), QMediaPlayer::NoError);

    // The next track, set exactly the way Player::loadAndPlay() sets one.
    player.setSource(QUrl::fromLocalFile(second));
    player.play();
    bool lit = false;
    for (int i = 0; i < 60 && !lit; ++i) {
        QTest::qWait(50);
        lit = analyser.bandLevels()[1] > 0.5;
    }
    player.stop();

    if (delivered == 0)
        QSKIP("the multimedia backend delivered no audio buffers for a PCM WAV");
    QVERIFY2(lit, "the tap did not pick up the track that started after it was attached");
#endif
}

QTEST_MAIN(TestSpectrum)
#include "tst_spectrum.moc"
