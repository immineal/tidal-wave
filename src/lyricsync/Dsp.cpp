// SPDX-License-Identifier: GPL-3.0-or-later

#include "Dsp.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace lyricsync::dsp {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kTaps = 63;
constexpr int kHalfTaps = kTaps / 2;

uint32_t bitsOf(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }
uint64_t bitsOf(double d) { uint64_t u; std::memcpy(&u, &d, 8); return u; }

double sinc(double x) {
    const double y = kPi * (x == 0 ? 1.0e-20 : x);
    return std::sin(y) / y;
}

// features.fir_lowpass(63, 4960 / 44100), numpy's formulas term for term.
std::vector<double> lowpass() {
    const double cutoff = 4960.0 / kRateIn;
    std::vector<double> h(kTaps);
    double sum = 0;
    for (int i = 0; i < kTaps; ++i) {
        const double n = double(i) - (kTaps - 1) / 2.0;
        const double k = double(1 - kTaps + 2 * i);
        const double bl = 0.42 + 0.5 * std::cos(kPi * k / (kTaps - 1))
                        + 0.08 * std::cos(2.0 * kPi * k / (kTaps - 1));
        h[i] = 2 * cutoff * sinc(2 * cutoff * n) * bl;
        sum += h[i];
    }
    for (double &v : h) v /= sum;
    return h;
}

// Triangles on the bin centres, 80-5000 Hz, HTK mel; [band][bin].
std::vector<float> melMatrix(int *lo, int *hi) {
    auto hz2mel = [](double f) { return 2595 * std::log10(1 + f / 700); };
    auto mel2hz = [](double m) { return 700 * (std::pow(10.0, m / 2595) - 1); };
    const double a = hz2mel(80.0), b = hz2mel(5000.0);
    double edges[kMel + 2];
    const double step = (b - a) / (kMel + 1);
    for (int i = 0; i < kMel + 2; ++i) edges[i] = mel2hz(i == kMel + 1 ? b : i * step + a);
    std::vector<float> w(size_t(kMel) * kBins, 0.f);
    for (int m = 0; m < kMel; ++m) {
        const double l = edges[m], c = edges[m + 1], h = edges[m + 2];
        lo[m] = kBins; hi[m] = 0;
        for (int k = 0; k < kBins; ++k) {
            const double f = double(k) * kRate / kNfft;
            const double v = std::max(0.0, std::min((f - l) / (c - l), (h - f) / (h - c)));
            w[size_t(m) * kBins + k] = float(v);
            if (float(v) != 0.f) { lo[m] = std::min(lo[m], k); hi[m] = k + 1; }
        }
    }
    return w;
}

struct Fft {
    int n;
    std::vector<int> rev;
    std::vector<double> c, s;
    explicit Fft(int n_) : n(n_), rev(n_), c(n_ / 2), s(n_ / 2) {
        int bits = 0;
        while ((1 << bits) < n) ++bits;
        for (int i = 0; i < n; ++i) {
            int r = 0;
            for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
            rev[i] = r;
        }
        for (int i = 0; i < n / 2; ++i) {
            c[i] = std::cos(2 * kPi * i / n);
            s[i] = -std::sin(2 * kPi * i / n);
        }
    }
    void run(double *re, double *im) const {
        for (int i = 0; i < n; ++i)
            if (rev[i] > i) { std::swap(re[i], re[rev[i]]); std::swap(im[i], im[rev[i]]); }
        for (int len = 2; len <= n; len <<= 1) {
            const int half = len / 2, stride = n / len;
            for (int i = 0; i < n; i += len) {
                for (int j = 0; j < half; ++j) {
                    const double wr = c[j * stride], wi = s[j * stride];
                    double &ar = re[i + j], &ai = im[i + j];
                    double &br = re[i + j + half], &bi = im[i + j + half];
                    const double tr = br * wr - bi * wi, ti = br * wi + bi * wr;
                    br = ar - tr; bi = ai - ti;
                    ar += tr; ai += ti;
                }
            }
        }
    }
};

template <int N>
float medianOf(float (&v)[N]) {
    std::nth_element(v, v + N / 2, v + N);
    return v[N / 2];
}

} // namespace

// ── float16 ────────────────────────────────────────────────────────────────

float halfToFloat(uint16_t h) {
    uint32_t s = uint32_t(h & 0x8000u) << 16, e = (h >> 10) & 0x1f, m = h & 0x3ff, f;
    if (e == 0) {
        if (m == 0) f = s;
        else {
            e = 127 - 15 + 1;
            while (!(m & 0x400)) { m <<= 1; e--; }
            m &= 0x3ff;
            f = s | (e << 23) | (m << 13);
        }
    } else if (e == 31) f = s | 0x7f800000u | (m << 13);
    else f = s | ((e + 127 - 15) << 23) | (m << 13);
    float r; std::memcpy(&r, &f, 4);
    return r;
}

uint16_t floatToHalf(float f) {
    const uint32_t x = bitsOf(f);
    const uint16_t sign = uint16_t((x >> 16) & 0x8000u);
    const uint32_t ax = x & 0x7fffffffu;
    if (ax > 0x7f800000u) return sign | 0x7e00;          // NaN
    if (ax >= 0x47800000u) return sign | 0x7c00;         // 2^16 and up: infinity
    if (ax < 0x38800000u) {                              // below 2^-14: subnormal
        float a; std::memcpy(&a, &ax, 4);
        return sign | uint16_t(std::nearbyint(a * 16777216.0f));
    }
    uint32_t h = (((ax >> 23) - 127 + 15) << 10) | ((ax >> 13) & 0x3ff);
    const uint32_t rem = ax & 0x1fff;
    if (rem > 0x1000 || (rem == 0x1000 && (h & 1))) ++h;
    return sign | uint16_t(h);
}

uint16_t doubleToHalf(double d) {
    const uint64_t x = bitsOf(d);
    const uint16_t sign = uint16_t((x >> 48) & 0x8000u);
    const uint64_t ax = x & 0x7fffffffffffffffull;
    if (ax > 0x7ff0000000000000ull) return sign | 0x7e00;
    const int e = int(ax >> 52) - 1023 + 15;
    if (e >= 31) return sign | 0x7c00;
    if (e <= 0) {
        double a; std::memcpy(&a, &ax, 8);
        return sign | uint16_t(std::nearbyint(a * 16777216.0));
    }
    uint64_t h = (uint64_t(e) << 10) | ((ax >> 42) & 0x3ff);
    const uint64_t rem = ax & ((1ull << 42) - 1), halfway = 1ull << 41;
    if (rem > halfway || (rem == halfway && (h & 1))) ++h;
    return sign | uint16_t(h);
}

// ── decimation ─────────────────────────────────────────────────────────────

Decimator::Decimator() : m_h(lowpass()) {}

void Decimator::push(const float *x, size_t frames) {
    for (int c = 0; c < 2; ++c) {
        std::vector<float> &b = m_buf[c];
        const size_t at = b.size();
        b.resize(at + frames);
        for (size_t i = 0; i < frames; ++i) b[at + i] = x[2 * i + c];
    }
    m_in += frames;
    emitUpTo(m_in, false);
}

void Decimator::finish() { emitUpTo(m_in, true); }

void Decimator::emitUpTo(size_t limit, bool atEnd) {
    // y[i] = sum_j x[i + 31 - j] h[j], zero outside the signal ("same").
    while (m_next < limit && (atEnd || m_next + kHalfTaps < limit)) {
        for (int c = 0; c < 2; ++c) {
            const std::vector<float> &b = m_buf[c];
            double acc = 0;
            for (int j = 0; j < kTaps; ++j) {
                const long long idx = (long long)m_next + kHalfTaps - j;
                if (idx < 0 || idx >= (long long)limit) continue;
                acc += double(b[size_t(idx) - m_base]) * m_h[j];
            }
            m_out[c].push_back(float(acc));
        }
        m_next += kDecim;
    }
    // Keep what the next outputs still read.
    const size_t keepFrom = m_next > size_t(kHalfTaps) ? m_next - kHalfTaps : 0;
    if (keepFrom > m_base + 65536) {
        for (int c = 0; c < 2; ++c)
            m_buf[c].erase(m_buf[c].begin(), m_buf[c].begin() + (keepFrom - m_base));
        m_base = keepFrom;
    }
}

// ── frame features ─────────────────────────────────────────────────────────

FrameFeatures frameFeatures(const std::vector<float> &left, const std::vector<float> &right,
                            const std::atomic<bool> *stop) {
    FrameFeatures out;
    const size_t n = left.size();
    if (n < size_t(kNfft) || right.size() != n) return out;
    const int frames = int(1 + (n - kNfft) / kHop);
    out.frames = frames;
    for (auto &b : out.band) b.assign(size_t(frames) * kMel, 0.f);

    float win[kNfft];
    for (int k = 0; k < kNfft; ++k)
        win[k] = float(0.5 + 0.5 * std::cos(kPi * double(2 * k - kNfft) / kNfft));
    int lo[kMel], hi[kMel];
    const std::vector<float> mel = melMatrix(lo, hi);
    const Fft fft(kNfft);

    // The last 17 frames' |M|, |M|^2, |S|^2, by frame % 17.
    constexpr int kRing = 17;
    std::vector<float> mag(size_t(kRing) * kBins), mp(size_t(kRing) * kBins), sp(size_t(kRing) * kBins);
    std::vector<double> re(kNfft), im(kNfft);
    int computed = 0;
    auto compute = [&](int t) {
        const size_t s = size_t(t) * kHop;
        for (int k = 0; k < kNfft; ++k) {
            re[k] = double(left[s + k] * win[k]);
            im[k] = double(right[s + k] * win[k]);
        }
        fft.run(re.data(), im.data());
        float *mg = &mag[size_t(t % kRing) * kBins];
        float *pm = &mp[size_t(t % kRing) * kBins];
        float *ps = &sp[size_t(t % kRing) * kBins];
        for (int b = 0; b < kBins; ++b) {
            const int nb = (kNfft - b) % kNfft;
            const double a = re[b], bb = im[b], c = re[nb], d = im[nb];
            // Both channels came through one complex transform.
            const double lr = (a + c) / 2, li = (bb - d) / 2;
            const double rr = (bb + d) / 2, ri = -(a - c) / 2;
            const float m = float(std::hypot((lr + rr) * 0.5, (li + ri) * 0.5));
            const float sm = float(std::hypot((lr - rr) * 0.5, (li - ri) * 0.5));
            mg[b] = m;
            pm[b] = m * m;
            ps[b] = sm * sm;
        }
    };

    std::vector<float> H(kBins), H5(kBins), P(kBins);
    float sp5[kBins], hm[kBins], vib2[kBins], cen[kBins];
    auto magAt = [&](int t) { return &mag[size_t(std::clamp(t, 0, frames - 1) % kRing) * kBins]; };
    for (int t = 0; t < frames; ++t) {
        if (stop && (t & 255) == 0 && stop->load(std::memory_order_relaxed)) return FrameFeatures{};
        while (computed < std::min(frames, t + 9)) compute(computed++);
        const float *rows[17];
        for (int j = 0; j < 17; ++j) rows[j] = magAt(t - 8 + j);
        for (int b = 0; b < kBins; ++b) {
            float w17[17], w5[5];
            for (int j = 0; j < 17; ++j) w17[j] = rows[j][b];
            for (int j = 0; j < 5; ++j) w5[j] = rows[6 + j][b];
            H[b] = medianOf(w17);
            H5[b] = medianOf(w5);
        }
        const float *mg = rows[8];
        for (int b = 0; b < kBins; ++b) {
            float w[17];
            for (int j = 0; j < 17; ++j) w[j] = mg[std::clamp(b - 8 + j, 0, kBins - 1)];
            P[b] = medianOf(w);
        }
        const float *pm = &mp[size_t(t % kRing) * kBins];
        const float *ps = &sp[size_t(t % kRing) * kBins];
        for (int b = 0; b < kBins; ++b) {
            const float h2 = H[b] * H[b], p2 = P[b] * P[b];
            hm[b] = (h2 / (h2 + p2 + 1e-12f)) * pm[b];
            const float p5 = std::min(P[b], mg[b]);
            const float v = std::max(H5[b] - H[b], 0.f) * (H5[b] > p5 ? 1.f : 0.f);
            vib2[b] = v * v;
            const float cw = pm[b] / (pm[b] + ps[b] + 1e-9f);
            cen[b] = pm[b] * cw * cw;
            sp5[b] = ps[b];
        }
        const float *src[5] = {pm, sp5, hm, vib2, cen};
        for (int k = 0; k < 5; ++k) {
            float *dst = &out.band[k][size_t(t) * kMel];
            for (int m = 0; m < kMel; ++m) {
                const float *w = &mel[size_t(m) * kBins];
                double acc = 0;
                for (int b = lo[m]; b < hi[m]; ++b) acc += double(src[k][b]) * double(w[b]);
                dst[m] = roundHalf(std::log(float(acc) + 1e-9f));
            }
        }
    }
    return out;
}

// ── order statistics ───────────────────────────────────────────────────────

float median(std::vector<float> v) {
    const size_t n = v.size();
    if (n == 0) return 0.f;
    std::nth_element(v.begin(), v.begin() + n / 2, v.end());
    const float hiV = v[n / 2];
    if (n % 2) return hiV;
    const float loV = *std::max_element(v.begin(), v.begin() + n / 2);
    return (loV + hiV) / 2.f;
}

namespace {
double lerp(float a, float b, double t) {
    const float diff = b - a;
    return t >= 0.5 ? double(b) - double(diff) * (1 - t) : double(a) + double(diff) * t;
}
double percentileSorted(const std::vector<float> &v, double q) {
    const size_t n = v.size();
    const double vi = double(n - 1) * q;
    const double fl = std::floor(vi);
    const size_t i = size_t(fl), j = std::min(i + 1, n - 1);
    return lerp(v[i], v[j], vi - fl);
}
} // namespace

double percentile(std::vector<float> v, double q) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    return percentileSorted(v, q / 100.0);
}

Quartiles quartiles(std::vector<float> v) {
    if (v.empty()) return {0.f, 1e-3};
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    const float med = n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.f;
    const double q1 = percentileSorted(v, 0.25), q3 = percentileSorted(v, 0.75);
    return {med, std::max(q3 - q1, 1e-3)};
}

void fft(std::vector<double> &re, std::vector<double> &im) {
    const Fft f(int(re.size()));
    f.run(re.data(), im.data());
}

} // namespace lyricsync::dsp
