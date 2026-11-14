// SPDX-License-Identifier: GPL-3.0-or-later

#include "Decode.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>

namespace lyricsync {

namespace {

constexpr double kNeg = -1e30;
// Back-pointers take 2 bits a state and frame; past this the song is skipped.
constexpr double kMaxStates = 6e8;
const double kNan = std::numeric_limits<double>::quiet_NaN();

struct Bonus {
    // Per token, the frame bonus on entering it; null rows add nothing.
    std::vector<const float *> rows;
};

// ctcalign.viterbi(), comparison for comparison.
bool viterbi(const std::vector<float> &lp, int T, int V, const std::vector<int> &tg, const Bonus *bonus,
             const std::vector<double> *pen, const std::vector<char> &inl, std::vector<long long> &first,
             double &total, const std::atomic<bool> *stop) {
    const int L = int(tg.size());
    const int S = 2 * L + 1;
    if (double(T) * S > kMaxStates) return false;
    const bool useB = bonus != nullptr, useP = pen != nullptr;
    std::vector<double> sc(static_cast<size_t>(S), kNeg), nw(static_cast<size_t>(S));
    std::vector<uint8_t> bp((size_t(T) * S + 3) / 4, 0);
    auto setBp = [&](size_t i, int d) { bp[i >> 2] |= uint8_t(d << ((i & 3) * 2)); };
    auto getBp = [&](size_t i) { return (bp[i >> 2] >> ((i & 3) * 2)) & 3; };
    auto lpAt = [&](int t, int v) { return double(lp[size_t(t) * V + v]); };

    sc[0] = lpAt(0, 0);
    sc[1] = lpAt(0, tg[0]) + (useB && bonus->rows[0] ? double(bonus->rows[0][0]) : 0.0)
          - (useP ? (*pen)[0] : 0.0);
    for (int t = 1; t < T; ++t) {
        if (stop && (t & 1023) == 0 && stop->load(std::memory_order_relaxed)) return false;
        const double blank = lpAt(t, 0);
        const double pt = useP ? (*pen)[t] : 0.0;
        const size_t row = size_t(t) * S;
        for (int s = 0; s < S; ++s) {
            if (s % 2 == 0) {
                double best = sc[s];
                int d = 0;
                if (s > 0 && sc[s - 1] > best) { best = sc[s - 1]; d = 1; }
                nw[s] = best + blank - (useP && inl[s] ? pt : 0.0);
                if (d) setBp(row + s, d);
            } else {
                const int k = s / 2;
                double best = sc[s];
                int d = 0;
                double ent = kNeg;
                int de = 0;
                if (sc[s - 1] > ent) { ent = sc[s - 1]; de = 1; }
                if (s > 1 && tg[k] != tg[k - 1] && sc[s - 2] > ent) { ent = sc[s - 2]; de = 2; }
                if (useB && ent > kNeg && bonus->rows[k]) ent += double(bonus->rows[k][t]);
                if (ent > best) { best = ent; d = de; }
                nw[s] = best + lpAt(t, tg[k]) - (useP ? pt : 0.0);
                if (d) setBp(row + s, d);
            }
        }
        std::swap(sc, nw);
    }
    int s = sc[S - 1] > sc[S - 2] ? S - 1 : S - 2;
    total = sc[s];
    first.assign(size_t(L), -1);
    for (int t = T - 1; t >= 0; --t) {
        if (s % 2 == 1) first[s / 2] = t;
        s -= getBp(size_t(t) * S + s);
    }
    return true;
}

std::vector<char> inlineStates(const std::vector<int> &first, int L) {
    std::vector<char> inl(size_t(2 * L + 1), 1);
    inl.front() = inl.back() = 0;
    for (int f : first)
        if (f > 0) inl[size_t(2 * f)] = 0;
    return inl;
}

bool align(const std::vector<float> &lp, int T, int V, double fps, const LineTargets &lines,
           const Bonus *bonus, const std::vector<double> *pen, Path &out, const std::atomic<bool> *stop) {
    const std::vector<int> &tg = lines.tokens;
    if (tg.empty() || 2 * tg.size() >= size_t(T)) return false;
    if (!viterbi(lp, T, V, tg, bonus, pen, inlineStates(lines.first, int(tg.size())), out.tf, out.total, stop))
        return false;
    out.t.assign(lines.first.size(), kNan);
    for (size_t i = 0; i < lines.first.size(); ++i)
        if (lines.first[i] >= 0) out.t[i] = double(out.tf[size_t(lines.first[i])]) / fps;
    return true;
}

// Per grid value, repeated over its 4 frames, then edge-padded to T.
template <typename X>
std::vector<X> toFrames(const std::vector<X> &g, int T) {
    std::vector<X> out;
    out.reserve(size_t(T));
    for (size_t i = 0; i < g.size() && out.size() < size_t(T); ++i)
        for (int k = 0; k < 4 && out.size() < size_t(T); ++k) out.push_back(g[i]);
    const X last = out.empty() ? X(0) : out.back();
    while (out.size() < size_t(T)) out.push_back(last);
    return out;
}

std::vector<double> gapPen(const std::vector<float> &v, int T, double gam, double v0, int lmin) {
    std::vector<double> g(v.size(), 0.0);
    for (size_t i = 0; i < v.size();) {
        if (double(v[i]) < v0) {
            size_t j = i;
            while (j < v.size() && double(v[j]) < v0) ++j;
            if (int(j - i) >= lmin)
                for (size_t k = i; k < j; ++k) g[k] = gam;
            i = j;
        } else {
            ++i;
        }
    }
    return toFrames(g, T);
}

std::vector<size_t> lineFirsts(const LineTargets &lines) {
    std::vector<size_t> fi;
    for (int f : lines.first)
        if (f >= 0) fi.push_back(size_t(f));
    return fi;
}

std::vector<size_t> lineEnds(const std::vector<size_t> &fi, size_t ntok) {
    std::vector<size_t> ends;
    for (size_t i = 1; i < fi.size(); ++i) ends.push_back(fi[i] - 1);
    ends.push_back(ntok - 1);
    return ends;
}

// _sig(): the longest stretch one line spends on long low-vocal frames.
double longestLow(const Path &a, const LineTargets &lines, const std::vector<double> &pen, double fps) {
    const std::vector<size_t> fi = lineFirsts(lines), ends = lineEnds(fi, lines.tokens.size());
    long long mx = 0;
    for (size_t k = 0; k < fi.size(); ++k) {
        long long lo = 0;
        for (long long t = a.tf[fi[k]]; t <= a.tf[ends[k]]; ++t) lo += pen[size_t(t)] > 0;
        mx = std::max(mx, lo);
    }
    return double(mx) / fps;
}

double percentile10(std::vector<float> v) {
    std::sort(v.begin(), v.end());
    const double vi = double(v.size() - 1) * (10.0 / 100.0);
    const double fl = std::floor(vi);
    const size_t i = size_t(fl), j = std::min(i + 1, v.size() - 1);
    const double t = vi - fl;
    const float diff = v[j] - v[i];
    return t >= 0.5 ? double(v[j]) - double(diff) * (1 - t) : double(v[i]) + double(diff) * t;
}

std::map<std::string, double> confFeats(const std::vector<float> &lp, int T, int V, double fps, const Path &a,
                                        const LineTargets &lines, const std::vector<float> &vocal) {
    std::map<std::string, double> f;
    const std::vector<int> &tg = lines.tokens;
    const std::vector<size_t> fi = lineFirsts(lines);
    std::vector<float> tp(tg.size());
    for (size_t k = 0; k < tg.size(); ++k) tp[k] = lp[size_t(a.tf[k]) * V + tg[k]];
    std::vector<float> lf;
    std::vector<double> t;
    for (size_t i : fi) { lf.push_back(tp[i]); t.push_back(double(a.tf[i]) / fps); }
    std::vector<double> nch;
    for (size_t k = 0; k < fi.size(); ++k)
        nch.push_back(double((k + 1 < fi.size() ? fi[k + 1] : tg.size()) - fi[k]));
    std::vector<double> r;
    for (size_t k = 1; k < t.size(); ++k) r.push_back(std::log(std::max(t[k] - t[k - 1], 0.2) / nch[k - 1]));
    if (r.empty()) r.push_back(0.0);

    double maxSum = 0, nbSum = 0;
    for (int i = 0; i < T; ++i) {
        const float *row = &lp[size_t(i) * V];
        maxSum += double(*std::max_element(row, row + V));
        nbSum += double(1.f - std::exp(row[0]));
    }
    auto mean = [](const auto &v) {
        double s = 0;
        for (auto x : v) s += double(x);
        return s / double(v.size());
    };
    double hi = 0;
    for (float x : tp) hi += double(x) > std::log(0.5);
    const double rm = mean(r);
    double rv = 0;
    for (double x : r) rv += (x - rm) * (x - rm);

    f["score"] = (a.total - maxSum) / T;
    f["tokp"] = mean(tp);
    f["tok_hi"] = hi / double(tp.size());
    f["linep"] = mean(lf);
    f["linep_q10"] = percentile10(lf);
    f["rate_sd"] = std::sqrt(rv / double(r.size()));
    f["cps"] = double(tg.size()) / std::max(t.back() - t.front(), 1.0);
    f["nb_share"] = nbSum / T;
    f["chars_per_nb"] = double(tg.size()) / std::max(nbSum / fps, 1.0);

    const std::vector<size_t> ends = lineEnds(fi, tg.size());
    double slow = -1e300;
    long long lowSum = 0, spanSum = 0, lowMax = 0;
    const std::vector<float> vg = toFrames(vocal, T);
    for (size_t k = 0; k < fi.size(); ++k) {
        const long long s = a.tf[fi[k]], b = a.tf[ends[k]] + 1;
        slow = std::max(slow, double(b - s) / fps / nch[k]);
        long long low = 0;
        for (long long i = s; i < b; ++i) low += vg[size_t(i)] < 0;
        lowSum += low;
        spanSum += b - s;
        lowMax = std::max(lowMax, low);
    }
    f["slow_line"] = std::log(slow);
    f["lowv_in"] = double(lowSum) / double(std::max<long long>(spanSum, 1));
    f["lowv_max"] = std::log1p(double(lowMax) / fps);
    return f;
}

} // namespace

std::vector<double> fillTimes(const std::vector<double> &t, double dur) {
    const size_t n = t.size();
    std::vector<size_t> known;
    for (size_t i = 0; i < n; ++i)
        if (std::isfinite(t[i])) known.push_back(i);
    std::vector<double> out(n);
    if (known.empty()) {
        const double stop = dur * 0.9;
        const double step = n > 1 ? stop / double(n - 1) : 0.0;
        for (size_t i = 0; i < n; ++i) out[i] = (n > 1 && i == n - 1) ? stop : double(i) * step;
        return out;
    }
    for (size_t i = 0; i < n; ++i) {
        if (i <= known.front()) { out[i] = t[known.front()]; continue; }
        if (i >= known.back()) { out[i] = t[known.back()]; continue; }
        const auto hi = std::lower_bound(known.begin(), known.end(), i);
        if (*hi == i) { out[i] = t[i]; continue; }
        const size_t j1 = *hi, j0 = *(hi - 1);
        const double slope = (t[j1] - t[j0]) / double(j1 - j0);
        out[i] = slope * double(i - j0) + t[j0];
    }
    return out;
}

Decoded decodeSong(const std::vector<float> &lp, int T, double fps, const std::vector<float> &start,
                   const std::vector<float> &vocal, const LineTargets &lines, const DecodeParams &p,
                   const std::atomic<bool> *stop) {
    Decoded out;
    const int V = T > 0 ? int(lp.size() / size_t(T)) : 0;
    if (T <= 0 || V <= 0 || start.empty() || vocal.empty()) return out;

    // The start bonus beta * min(o, clip) on each line's first letter.
    std::vector<float> og;
    og.reserve(size_t(T));
    const float clip = float(p.clip);
    for (size_t i = 0; i < start.size() && og.size() < size_t(T); ++i)
        for (int k = 0; k < 4 && og.size() < size_t(T); ++k) og.push_back(std::min(start[i], clip));
    const float ogMin = *std::min_element(og.begin(), og.end());
    while (og.size() < size_t(T)) og.push_back(ogMin);
    std::vector<float> bonusRow(static_cast<size_t>(T));
    const float beta = float(p.beta);
    for (int t = 0; t < T; ++t) bonusRow[size_t(t)] = beta * og[size_t(t)];
    Bonus bonus;
    bonus.rows.assign(lines.tokens.size(), nullptr);
    for (int f : lines.first)
        if (f >= 0) bonus.rows[size_t(f)] = bonusRow.data();

    Path a;
    if (!align(lp, T, V, fps, lines, &bonus, nullptr, a, stop)) return out;
    bool sw = false;
    double lmax = 0.0;
    if (p.gam > 0) {
        const std::vector<double> pen = gapPen(vocal, T, p.gam, p.v0, p.lmin);
        lmax = longestLow(a, lines, pen, fps);
        if (lmax > p.switchS) {
            Path a2;
            if (align(lp, T, V, fps, lines, &bonus, &pen, a2, stop)) {
                a = std::move(a2);
                sw = true;
                lmax = longestLow(a, lines, pen, fps);
            }
        }
    }
    out.f = confFeats(lp, T, V, fps, a, lines, vocal);
    out.f["gap_lmax"] = std::log1p(lmax);
    out.f["switched"] = sw ? 1.0 : 0.0;
    Path a0;
    if (stop && stop->load(std::memory_order_relaxed)) return out;
    if (!align(lp, T, V, fps, lines, nullptr, nullptr, a0, stop)) return out;
    const double dur = double(T) / fps;
    const std::vector<double> t0 = fillTimes(a0.t, dur), t1 = fillTimes(a.t, dur);
    double agree = 0;
    for (size_t i = 0; i < t0.size(); ++i) agree += std::abs(t0[i] - t1[i]) <= 1.0;
    out.f["agree_plain"] = t0.empty() ? 0.0 : agree / double(t0.size());
    out.a = std::move(a);
    out.switched = sw;
    out.ok = true;
    return out;
}

} // namespace lyricsync
