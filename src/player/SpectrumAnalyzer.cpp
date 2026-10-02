#include "SpectrumAnalyzer.h"

#include <QAudioBuffer>
#include <QAudioFormat>
#include <QMetaMethod>
#include <QMetaProperty>
#include <QTimer>
#include <QtGlobal>
#include <algorithm>
#include <cmath>
#include <type_traits>

// The hazard ThemePalette's create() comment describes, caught at compile time
// instead of at runtime: Qt decides how to build a QML_SINGLETON by testing
// std::is_default_constructible first, so the moment this type gains a default
// constructor the engine builds its own instance, create() is never called,
// and every PlayingIndicator in the app binds to an analyser that nothing ever
// feeds. The failure is silent - the bars just never move - so it is pinned
// here rather than left to be rediscovered.
static_assert(!std::is_default_constructible_v<SpectrumAnalyzer>,
              "SpectrumAnalyzer must not be default-constructible, or Qt will "
              "build the QML singleton itself and never call create(). Keep "
              "the `parent` argument of the constructor un-defaulted.");

namespace {

// ─── bands ──────────────────────────────────────────────────────────────────
//
// Six edges, five bands, geometrically spaced: each is a touch over three
// times the width of the one below it, which is how a spectrum has to be split
// for the result to look like an equaliser rather than like four empty bars
// next to one busy one. Linear thirds of 0-22 kHz would put everything a human
// hears about pitch into the first bar.
//
// The numbers are rounded off the 50 Hz -> 13 kHz ratio ladder rather than
// taken from it exactly, because round edges make the band a frequency falls
// into something a reader can work out. 1 kHz lands in the middle band with
// better than a third of an octave of margin either side, which is what
// tests/tst_spectrum.cpp leans on.
constexpr double kEdges[SpectrumAnalyzer::kBands + 1] = {
    50.0, 150.0, 450.0, 1400.0, 4200.0, 13000.0
};

// The window. Blackman-Harris rather than Hann: its mainlobe is wider, which
// costs a little resolution nobody can see at five bars, and its sidelobes are
// 60 dB further down, which is the difference between a 1 kHz tone lighting
// one bar and a 1 kHz tone lighting one bar brightly and the next two faintly.
// Leakage into a neighbouring band is the only artefact of this whole pipeline
// anyone would actually notice.
constexpr double kBh[4] = { 0.35875, 0.48829, 0.14128, 0.01168 };

// How far below full scale a band has to be to read as nothing. 55 dB is about
// where a quiet passage stops being distinguishable from the room, and it maps
// the levels most music actually produces across the useful half of the bar.
constexpr double kFloorDb = 55.0;

// Per analysis frame, which is every kHopSize samples - 23 ms at 44.1 kHz.
// Fast up, slower down: the asymmetry is what makes a level meter read as one
// rather than as a flicker. Tuned so a transient is on screen within about two
// frames and takes about an eighth of a second to fall away.
constexpr double kAttack = 0.45;
constexpr double kDecay  = 0.18;

// Below this a level is zero. An exponential decay never arrives on its own,
// and a bar held at 10^-9 of full scale is a bar that never parks.
constexpr double kSilenceEpsilon = 1e-4;

// Published levels closer together than this are the same picture.
constexpr double kPublishEpsilon = 2e-3;

// Iterative radix-2 Cooley-Tukey, decimation in time, in place. `twCos`/`twSin`
// hold e^(-2*pi*i*t/n) for t in [0, n/2).
void fft(std::vector<double> &re, std::vector<double> &im,
         const std::vector<double> &twCos, const std::vector<double> &twSin, int n)
{
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std::swap(re[size_t(i)], re[size_t(j)]);
            std::swap(im[size_t(i)], im[size_t(j)]);
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const int half = len >> 1;
        const int step = n / len;
        for (int base = 0; base < n; base += len) {
            for (int k = 0; k < half; ++k) {
                const int t  = k * step;
                const double wr = twCos[size_t(t)];
                const double wi = twSin[size_t(t)];
                const size_t a = size_t(base + k);
                const size_t b = a + size_t(half);
                const double xr = re[b], xi = im[b];
                const double ur = xr * wr - xi * wi;
                const double ui = xr * wi + xi * wr;
                re[b] = re[a] - ur;
                im[b] = im[a] - ui;
                re[a] += ur;
                im[a] += ui;
            }
        }
    }
}

// One frame of one channel, as a double in -1..1. Returns false for anything
// this build cannot read, which is how an unexpected sample format becomes a
// dropped buffer rather than a reinterpret_cast over the wrong type.
inline bool sampleAt(const char *base, QAudioFormat::SampleFormat fmt,
                     qsizetype index, double *out)
{
    switch (fmt) {
    case QAudioFormat::UInt8:
        // Unsigned, silence is 128. Without the bias this reads as a
        // permanent DC offset, which is a pegged bass bar over silence.
        *out = (double(reinterpret_cast<const quint8 *>(base)[index]) - 128.0) / 128.0;
        return true;
    case QAudioFormat::Int16:
        *out = double(reinterpret_cast<const qint16 *>(base)[index]) / 32768.0;
        return true;
    case QAudioFormat::Int32:
        *out = double(reinterpret_cast<const qint32 *>(base)[index]) / 2147483648.0;
        return true;
    case QAudioFormat::Float:
        *out = double(reinterpret_cast<const float *>(base)[index]);
        return true;
    default:
        return false;
    }
}

} // namespace

bool SpectrumAnalyzer::availableAtCompileTime()
{
    return TIDALWAVE_HAS_BUFFER_OUTPUT != 0;
}

QList<double> SpectrumAnalyzer::bandEdgesHz()
{
    QList<double> out;
    out.reserve(kBands + 1);
    for (const double edge : kEdges) out.append(edge);
    return out;
}

SpectrumAnalyzer::SpectrumAnalyzer(QObject *parent)
    : QObject(parent)
{
    m_mono.assign(size_t(kFftSize), 0.0);
    m_re.assign(size_t(kFftSize), 0.0);
    m_im.assign(size_t(kFftSize), 0.0);

    // The window, and the one number derived from it that puts the band
    // amplitudes on an absolute scale. By Parseval the squared bins of a
    // windowed sine of amplitude A sum (over the half spectrum) to
    // A^2 * mean(w^2) / coherentGain^2 once each bin is scaled by
    // 2 / (N * coherentGain) - so folding both constants together leaves a
    // single factor, and sqrt(sum) * that factor is A. Computed from the
    // window array rather than written down, so changing the window above
    // cannot silently change what "full scale" means.
    m_window.resize(size_t(kFftSize));
    double sumSq = 0.0;
    for (int n = 0; n < kFftSize; ++n) {
        const double x = 2.0 * M_PI * double(n) / double(kFftSize - 1);
        const double w = kBh[0] - kBh[1] * std::cos(x)
                       + kBh[2] * std::cos(2.0 * x) - kBh[3] * std::cos(3.0 * x);
        m_window[size_t(n)] = w;
        sumSq += w * w;
    }
    const double meanSq = sumSq / double(kFftSize);
    m_magScale = 2.0 / (double(kFftSize) * std::sqrt(meanSq));

    m_twCos.resize(size_t(kFftSize / 2));
    m_twSin.resize(size_t(kFftSize / 2));
    for (int t = 0; t < kFftSize / 2; ++t) {
        const double a = -2.0 * M_PI * double(t) / double(kFftSize);
        m_twCos[size_t(t)] = std::cos(a);
        m_twSin[size_t(t)] = std::sin(a);
    }

    m_publishTimer = new QTimer(this);
    m_publishTimer->setInterval(kPublishMs);
    m_publishTimer->setTimerType(Qt::CoarseTimer);
    connect(m_publishTimer, &QTimer::timeout, this, &SpectrumAnalyzer::publishTick);
}

SpectrumAnalyzer::~SpectrumAnalyzer() = default;

SpectrumAnalyzer *SpectrumAnalyzer::instance()
{
    static SpectrumAnalyzer *self = new SpectrumAnalyzer(nullptr);
    return self;
}

SpectrumAnalyzer *SpectrumAnalyzer::create(QQmlEngine *, QJSEngine *)
{
    SpectrumAnalyzer *self = instance();
    // The singleton outlives any one engine, so the engine must not delete it.
    QQmlEngine::setObjectOwnership(self, QQmlEngine::CppOwnership);
    return self;
}

QVariantList SpectrumAnalyzer::levels() const
{
    QVariantList out;
    out.reserve(kBands);
    for (const double level : m_levels) out.append(level);
    return out;
}

QList<double> SpectrumAnalyzer::bandLevels() const
{
    QList<double> out;
    out.reserve(kBands);
    for (const double level : m_levels) out.append(level);
    return out;
}

void SpectrumAnalyzer::setEnabled(bool on)
{
    if (on == m_enabled) return;
    m_enabled = on;

    if (m_enabled) {
        m_publishTimer->start();
    } else {
        m_publishTimer->stop();
        reset();
    }
    emit enabledChanged(m_enabled);
}

void SpectrumAnalyzer::setPrefsSource(QObject *source)
{
    if (m_prefs == source) return;
    if (m_prefs) disconnect(m_prefs, nullptr, this, nullptr);
    m_prefs = source;

    if (m_prefs) {
        // By meta-object rather than against Prefs::spectrumBarsChanged, so a
        // test double works here without this class knowing the concrete type.
        const QMetaObject *mo = m_prefs->metaObject();
        const int index = mo->indexOfProperty("spectrumBars");
        if (index < 0) {
            qWarning("SpectrumAnalyzer: preferences source has no \"spectrumBars\" property");
        } else {
            const QMetaProperty prop = mo->property(index);
            if (prop.hasNotifySignal()) {
                const int slot = metaObject()->indexOfSlot("refreshFromPrefs()");
                connect(m_prefs, prop.notifySignal(), this, metaObject()->method(slot));
            }
        }
    }
    refreshFromPrefs();
}

void SpectrumAnalyzer::refreshFromPrefs()
{
    // Where the Qt version actually bites. Below 6.8 there is no
    // QAudioBufferOutput and so nothing that could ever hand this object a
    // buffer; the preference is reported unavailable, and it is refused here
    // rather than left to switch on a DSP that would only ever see silence.
    setEnabled(availableAtCompileTime()
               && m_prefs && m_prefs->property("spectrumBars").toBool());
}

void SpectrumAnalyzer::reset()
{
    m_fill = 0;
    std::fill(m_mono.begin(), m_mono.end(), 0.0);
    const bool had = std::any_of(std::begin(m_levels), std::end(m_levels),
                                 [](double v) { return v != 0.0; });
    clearLevels();
    setActive(false);
    m_sinceBuffer.invalidate();
    if (had) emit levelsChanged();
}

void SpectrumAnalyzer::clearLevels()
{
    for (int b = 0; b < kBands; ++b) {
        m_levels[b]    = 0.0;
        m_published[b] = 0.0;
    }
}

void SpectrumAnalyzer::setActive(bool on)
{
    if (on == m_active) return;
    m_active = on;
    emit activeChanged(m_active);
}

void SpectrumAnalyzer::setLevelsForTest(const QVariantList &levels)
{
    for (int b = 0; b < kBands; ++b) {
        const double v = b < levels.size() ? levels.at(b).toDouble() : 0.0;
        m_levels[b]    = std::clamp(v, 0.0, 1.0);
        m_published[b] = m_levels[b];
    }
    // Keeps the idle sweep in publishTick() from pulling the rug out from
    // under a test that is mid-assertion.
    m_sinceBuffer.start();
    setActive(true);
    emit levelsChanged();
}

void SpectrumAnalyzer::stopForTest()
{
    reset();
    emit levelsChanged();
}

void SpectrumAnalyzer::processBuffer(const QAudioBuffer &buffer)
{
    if (!m_enabled) return;

    // Everything a malformed buffer could be. QAudioBufferOutput hands over a
    // default-constructed one before the pipeline has a format, the end of a
    // stream arrives as a valid container with no frames, and a backend that
    // has gone wrong can produce a format whose bytesPerSample() is zero -
    // which is a division, not a wrong colour.
    if (!buffer.isValid()) return;
    const QAudioFormat fmt = buffer.format();
    if (!fmt.isValid()) return;
    const int channels = fmt.channelCount();
    const int rate     = fmt.sampleRate();
    const int stride   = fmt.bytesPerSample();
    if (channels <= 0 || rate <= 0 || stride <= 0) return;

    const qsizetype frames = buffer.frameCount();
    if (frames <= 0) return;
    // Trust the declared frame count only as far as the bytes actually there.
    const qsizetype usable =
        std::min<qsizetype>(frames, buffer.byteCount() / (qsizetype(channels) * stride));
    if (usable <= 0) return;

    const char *base = buffer.constData<char>();
    if (!base) return;

    // One probe before committing: an unreadable sample format is dropped
    // whole rather than half-converted.
    double probe = 0.0;
    if (!sampleAt(base, fmt.sampleFormat(), 0, &probe)) return;

    if (rate != m_binRate) rebuildBandBins(rate);

    m_sinceBuffer.start();
    setActive(true);

    const double inv = 1.0 / double(channels);
    for (qsizetype f = 0; f < usable; ++f) {
        double sum = 0.0;
        for (int c = 0; c < channels; ++c) {
            double s = 0.0;
            sampleAt(base, fmt.sampleFormat(), f * channels + c, &s);
            sum += s;
        }
        m_mono[size_t(m_fill++)] = sum * inv;
        if (m_fill == kFftSize) {
            analyseFrame();
            // Slide by half a window, so consecutive frames overlap and a
            // transient cannot fall between two of them.
            std::copy(m_mono.begin() + kHopSize, m_mono.end(), m_mono.begin());
            m_fill = kFftSize - kHopSize;
        }
    }
}

void SpectrumAnalyzer::rebuildBandBins(int rate)
{
    m_binRate = rate;
    const int nyquistBin = kFftSize / 2;
    for (int b = 0; b < kBands; ++b) {
        const double perHz = double(kFftSize) / double(rate);
        // Half-open in frequency, so the bin on a shared edge belongs to the
        // upper band only and no bin is counted twice.
        int lo = int(std::ceil(kEdges[b] * perHz));
        int hi = int(std::ceil(kEdges[b + 1] * perHz)) - 1;
        lo = std::max(lo, 1);               // never DC
        hi = std::min(hi, nyquistBin - 1);
        m_binLo[b] = lo;
        m_binHi[b] = hi;                    // hi < lo means "above Nyquist here"
    }
}

void SpectrumAnalyzer::analyseFrame()
{
    for (int n = 0; n < kFftSize; ++n) {
        m_re[size_t(n)] = m_mono[size_t(n)] * m_window[size_t(n)];
        m_im[size_t(n)] = 0.0;
    }
    fft(m_re, m_im, m_twCos, m_twSin, kFftSize);

    for (int b = 0; b < kBands; ++b) {
        double target = 0.0;
        if (m_binHi[b] >= m_binLo[b]) {
            double energy = 0.0;
            for (int k = m_binLo[b]; k <= m_binHi[b]; ++k)
                energy += m_re[size_t(k)] * m_re[size_t(k)] + m_im[size_t(k)] * m_im[size_t(k)];
            const double amp = std::sqrt(energy) * m_magScale;
            if (amp > 0.0) {
                // dBFS mapped onto the bar. Logarithmic, because every step of
                // the chain in front of this one is: a bar that moved linearly
                // in amplitude would sit on the floor for all but the loudest
                // moments of a track.
                const double db = 20.0 * std::log10(amp);
                target = std::clamp(1.0 + db / kFloorDb, 0.0, 1.0);
            }
        }

        const double coeff = target > m_levels[b] ? kAttack : kDecay;
        double next = m_levels[b] + (target - m_levels[b]) * coeff;
        if (next < kSilenceEpsilon) next = 0.0;
        m_levels[b] = std::clamp(next, 0.0, 1.0);
    }
}

void SpectrumAnalyzer::publishTick()
{
    // No audio for a while: a pause, a track change, or the end of the queue.
    // Release the bars rather than leaving the last spectrum frozen on screen.
    if (m_sinceBuffer.isValid() && m_sinceBuffer.elapsed() > kIdleTimeoutMs) {
        m_fill = 0;
        std::fill(m_mono.begin(), m_mono.end(), 0.0);
        clearLevels();
        setActive(false);
        m_sinceBuffer.invalidate();
        emit levelsChanged();
        return;
    }

    bool moved = false;
    for (int b = 0; b < kBands; ++b) {
        if (std::abs(m_levels[b] - m_published[b]) > kPublishEpsilon) {
            moved = true;
            break;
        }
    }
    if (!moved) return;

    for (int b = 0; b < kBands; ++b) m_published[b] = m_levels[b];
    emit levelsChanged();
}
