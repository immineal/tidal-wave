// SPDX-License-Identifier: GPL-3.0-or-later

#include "Aligner.h"
#include "Decode.h"
#include "Dsp.h"
#include "Nets.h"
#include "Text.h"

#include <QFile>
#include <algorithm>
#include <chrono>
#include <cmath>

namespace lyricsync {

using namespace dsp;

namespace {

constexpr int kVocab = 27;
constexpr int kVoiceLo = 8, kVoiceHi = 34;

// runs/conf_convF_gap.json: ridge confidence over these features.
struct ConfTerm { const char *key; double mu, sd, w; };
constexpr ConfTerm kConf[] = {
    {"agree_plain", 0.8415294659825436, 0.17532662066511429, 0.11262249151345012},
    {"chars_per_nb", 38.38846258711569, 7.026807975221074, 0.010340907650442065},
    {"cps", 7.644564482642958, 3.6051722671808992, 0.042482140117891656},
    {"gap_lmax", 0.8548917953332755, 0.8617575753618415, 0.011392016712480083},
    {"linep", -2.4878032530859575, 0.5382937571309757, 0.011110582407217594},
    {"linep_q10", -4.499026710532375, 0.8784925836112584, -0.012195507865508562},
    {"lowv_in", 0.050937581499693886, 0.06344542467196604, -0.010519626579186021},
    {"lowv_max", 1.0911867556865893, 0.763050438298939, -0.010313414404955524},
    {"nb_share", 0.17114817409670538, 0.07400953750509283, -0.02410343042665608},
    {"rate_sd", 0.4977325847947648, 0.18707385494547765, -0.013726483233881289},
    {"score", -0.25623621282734205, 0.12684029311234685, 0.04437480166010278},
    {"slow_line", -0.9841397890540458, 0.6067098645694481, -0.001037813467429526},
    {"tok_hi", 0.10574287389021635, 0.05210156291443506, -0.027841197177431658},
    {"tokp", -2.3324177206791554, 0.29107535099792553, 0.034692345087616205},
};
constexpr double kConfBias = 0.8685922116884036;
constexpr double kThreshold = 0.594657349020247;

double now() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// vadfeat.box(): centred moving average by float32 cumulative sums, edges held.
std::vector<float> box(const std::vector<float> &x, int w) {
    const size_t n = x.size();
    if (w <= 1 || n == 0) return x;
    const int h = w / 2;
    std::vector<float> c(n + 2 * size_t(h) + 1);
    c[0] = 0.f;
    size_t k = 0;
    auto add = [&](float v) { c[k + 1] = c[k] + v; ++k; };
    for (int i = 0; i < h; ++i) add(x.front());
    for (float v : x) add(v);
    for (int i = 0; i < h; ++i) add(x.back());
    std::vector<float> out(n);
    const float fw = float(w);
    for (size_t i = 0; i < n; ++i) out[i] = (c[i + size_t(w)] - c[i]) / fw;
    return out;
}

// vadfeat.to_grid(): the mean of each 4 consecutive rows, the rest dropped.
std::vector<float> toGrid(const std::vector<float> &x, int frames, int cols) {
    const int g = frames / kGrid;
    std::vector<float> out(size_t(g) * cols);
    for (int i = 0; i < g; ++i)
        for (int c = 0; c < cols; ++c) {
            float s = x[size_t(4 * i) * cols + c];
            for (int k = 1; k < 4; ++k) s += x[size_t(4 * i + k) * cols + c];
            out[size_t(i) * cols + c] = s / 4.f;
        }
    return out;
}

// (x - median) / max(p75 - p25, 1e-3) per column, in float64 like numpy.
std::vector<double> normalise(const std::vector<float> &x, int rows, int cols) {
    std::vector<double> out(size_t(rows) * cols);
    std::vector<float> col(static_cast<size_t>(rows));
    for (int c = 0; c < cols; ++c) {
        for (int r = 0; r < rows; ++r) col[size_t(r)] = x[size_t(r) * cols + c];
        const Quartiles q = quartiles(col);
        for (int r = 0; r < rows; ++r)
            out[size_t(r) * cols + c] = double(x[size_t(r) * cols + c] - q.median) / q.scale;
    }
    return out;
}

double clip8(double v) { return std::min(std::max(v, -8.0), 8.0); }

float logSumExp(const float *a, int from, int to) {
    double s = 0;
    for (int i = from; i < to; ++i) s += double(std::exp(a[i]));
    return std::log(float(s) + 1e-9f);
}

// vadfeat.grid_features(), the 46 base columns the detector reads.
std::vector<float> gridBase(const FrameFeatures &fe) {
    const int T = fe.frames;
    constexpr int kCols = 46;
    const std::vector<float> &mid = fe.band[0], &side = fe.band[1], &harm = fe.band[2];
    std::vector<float> voice(static_cast<size_t>(T)), tot(static_cast<size_t>(T));
    std::vector<float> ff(size_t(T) * kCols);
    for (int t = 0; t < T; ++t) {
        const float *m = &mid[size_t(t) * kMel];
        const float *s = &side[size_t(t) * kMel];
        const float *h = &harm[size_t(t) * kMel];
        const float *v = &fe.band[3][size_t(t) * kMel];
        const float *c = &fe.band[4][size_t(t) * kMel];
        const float *mp = t > 0 ? &mid[size_t(t - 1) * kMel] : m;
        voice[t] = logSumExp(m, kVoiceLo, kVoiceHi);
        tot[t] = logSumExp(m, 0, kMel);
        double flux = 0;
        for (int b = kVoiceLo; b < kVoiceHi; ++b) flux += double(std::max(m[b] - mp[b], 0.f));
        float *row = &ff[size_t(t) * kCols];
        for (int k = 0; k < 8; ++k) {
            const float m8 = logSumExp(m, 5 * k, 5 * k + 5), s8 = logSumExp(s, 5 * k, 5 * k + 5);
            const float h8 = logSumExp(h, 5 * k, 5 * k + 5), v8 = logSumExp(v, 5 * k, 5 * k + 5);
            const float c8 = logSumExp(c, 5 * k, 5 * k + 5);
            row[k] = m8;
            row[8 + k] = m8 - s8;
            row[16 + k] = h8 - m8;
            row[24 + k] = v8 - m8;
            row[32 + k] = c8 - m8;
        }
        const float hv = logSumExp(h, kVoiceLo, kVoiceHi), sv = logSumExp(s, kVoiceLo, kVoiceHi);
        row[40] = voice[t];
        row[41] = voice[t] - tot[t];
        row[42] = hv - voice[t];
        row[43] = voice[t] - sv;
        row[44] = float(flux / (kVoiceHi - kVoiceLo));
    }
    // Syllabic modulation: the voice envelope's 2.5-8 Hz energy, 1 s windows.
    const std::vector<float> bv = box(voice, 43);
    std::vector<float> env(static_cast<size_t>(T));
    for (int t = 0; t < T; ++t) env[t] = voice[t] - bv[t];
    const std::vector<float> b3 = box(env, 3), b9 = box(env, 9);
    std::vector<float> bp2(static_cast<size_t>(T));
    for (int t = 0; t < T; ++t) { const float bp = b3[t] - b9[t]; bp2[t] = bp * bp; }
    const std::vector<float> mod = box(bp2, 43);
    for (int t = 0; t < T; ++t) ff[size_t(t) * kCols + 45] = std::log(mod[t] + 1e-4f);

    const int G = T / kGrid;
    const std::vector<double> g = normalise(toGrid(ff, T, kCols), G, kCols);
    std::vector<float> out(g.size());
    for (size_t i = 0; i < g.size(); ++i) out[i] = float(g[i]);
    return out;
}

} // namespace

double Analysis::seconds() const { return frames / kFps; }

// ── models ─────────────────────────────────────────────────────────────────

struct Models::Impl {
    CtcNet ctc;
    Detector detector;
    Translit translit;
    DecodeParams dec;
};

Models::Models() : d(std::make_unique<Impl>()) {}
Models::~Models() = default;

double Models::threshold() const { return kThreshold; }

std::shared_ptr<const Models> Models::fromData(const QByteArray &ctc, const QByteArray &detector,
                                               const QByteArray &translit, QString *err) {
    std::shared_ptr<Models> m(new Models());
    if (!m->d->ctc.load(ctc, err) || !m->d->detector.load(detector, err) || !m->d->translit.load(translit, err))
        return nullptr;
    if (m->d->ctc.inputs() != 5 * kMel || m->d->ctc.outputs() != kVocab || m->d->detector.inputs() != 5 * kMel + 46) {
        if (err) *err = QStringLiteral("the nets do not fit the front end");
        return nullptr;
    }
    return m;
}

std::shared_ptr<const Models> Models::builtin(QString *err) {
    auto read = [](const QString &path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
    };
    return fromData(read(QStringLiteral(":/lyricsync/ctc.f16.bin")),
                    read(QStringLiteral(":/lyricsync/detector.f16.bin")),
                    read(QStringLiteral(":/lyricsync/translit.bin")), err);
}

// ── front end ──────────────────────────────────────────────────────────────

struct FrontEnd::Impl { Decimator dec; };

FrontEnd::FrontEnd() : d(std::make_unique<Impl>()) {}
FrontEnd::~FrontEnd() = default;

void FrontEnd::push(const float *x, size_t frames) { d->dec.push(x, frames); }
size_t FrontEnd::framesIn() const { return d->dec.inputFrames(); }

Analysis FrontEnd::finish(const Models &models, Timing *timing, const DumpFn &dump) {
    const Models::Impl &m = models.impl();
    Analysis out;
    double t0 = now();
    d->dec.finish();
    if (dump) { dump("dec_l", d->dec.left(), 1); dump("dec_r", d->dec.right(), 1); }
    double t1 = now();
    const FrameFeatures fe = frameFeatures(d->dec.left(), d->dec.right());
    d->dec.release();
    const int T = fe.frames, G = T / kGrid;
    if (T < 8 * kGrid) return out;
    if (dump) {
        static const char *names[5] = {"fe_mid", "fe_side", "fe_harm", "fe_vib", "fe_cen"};
        for (int k = 0; k < 5; ++k) dump(names[k], fe.band[k], kMel);
    }

    // The detector's input: the five band blocks at grid rate, then the grid features.
    const std::vector<float> grid = gridBase(fe);
    if (dump) dump("grid46", grid, 46);
    constexpr int kIn = 5 * kMel + 46;
    std::vector<float> xi(size_t(G) * kIn);
    for (int k = 0; k < 5; ++k) {
        const std::vector<double> g = normalise(toGrid(fe.band[k], T, kMel), G, kMel);
        for (int r = 0; r < G; ++r)
            for (int c = 0; c < kMel; ++c)
                xi[size_t(r) * kIn + k * kMel + c] = roundHalf(float(clip8(g[size_t(r) * kMel + c])));
    }
    for (int r = 0; r < G; ++r)
        for (int c = 0; c < 46; ++c)
            xi[size_t(r) * kIn + 5 * kMel + c] = roundHalf(float(clip8(double(grid[size_t(r) * 46 + c]))));
    if (dump) dump("xi", xi, kIn);
    double t2 = now();
    m.detector.forward(xi.data(), G, out.vocal, out.start);
    if (dump) { dump("v", out.vocal, 1); dump("o", out.start, 1); }
    double t3 = now();

    // The CTC net's input: the five band blocks per frame, per-song normalised.
    std::vector<float> h(size_t(T) * 5 * kMel);
    for (int k = 0; k < 5; ++k) {
        const std::vector<double> g = normalise(fe.band[k], T, kMel);
        for (int r = 0; r < T; ++r)
            for (int c = 0; c < kMel; ++c)
                h[size_t(r) * 5 * kMel + k * kMel + c] = roundHalf(clip8(g[size_t(r) * kMel + c]));
    }
    if (dump) dump("h", h, 5 * kMel);
    out.lp.resize(size_t(T) * kVocab);
    m.ctc.forward(h.data(), T, out.lp.data());
    if (dump) dump("lp", out.lp, kVocab);
    out.frames = T;
    double t4 = now();
    if (timing) {
        timing->decimate += t1 - t0;
        timing->features += t2 - t1;
        timing->detector += t3 - t2;
        timing->ctc += t4 - t3;
    }
    return out;
}

// ── alignment ──────────────────────────────────────────────────────────────

Alignment align(const Analysis &a, const QString &plainText, const Models &models, Timing *timing) {
    const double t0 = now();
    const Models::Impl &m = models.impl();
    Alignment out;
    out.lines = plainLines(plainText);
    LineTargets targets;
    for (const QString &line : out.lines) {
        const std::vector<int> tk = tokens(line, m.translit);
        targets.first.push_back(tk.empty() ? -1 : int(targets.tokens.size()));
        targets.tokens.insert(targets.tokens.end(), tk.begin(), tk.end());
    }
    const double dur = a.frames / kFps;
    Decoded dd;
    if (a.frames > 0 && !out.lines.isEmpty())
        dd = decodeSong(a.lp, a.frames, kFps, a.start, a.vocal, targets, m.dec);
    if (!dd.ok) {
        out.times = fillTimes(std::vector<double>(size_t(out.lines.size()), std::nan("")), dur);
    } else {
        out.times = fillTimes(dd.a.t, dur);
        double z = kConfBias;
        for (const ConfTerm &c : kConf) z += (dd.f.at(c.key) - c.mu) / c.sd * c.w;
        out.confidence = z;
        out.aligned = true;
    }
    out.kept = out.aligned && out.confidence >= kThreshold;
    if (timing) timing->align += now() - t0;
    return out;
}

QString toLrc(const Alignment &a) {
    QString out;
    for (qsizetype i = 0; i < a.lines.size(); ++i) {
        const double s = std::max(0.0, i < qsizetype(a.times.size()) ? a.times[size_t(i)] : 0.0);
        const int mm = int(std::floor(s / 60));
        char stamp[32];
        std::snprintf(stamp, sizeof stamp, "[%02d:%05.2f]", mm, std::fmod(s, 60.0));
        out += QLatin1String(stamp) + a.lines.at(i) + u'\n';
    }
    return out;
}

} // namespace lyricsync
