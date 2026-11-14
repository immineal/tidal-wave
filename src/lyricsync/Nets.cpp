// SPDX-License-Identifier: GPL-3.0-or-later

#include "Nets.h"
#include "Dsp.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <cmath>
#include <cstring>

namespace lyricsync {

namespace {

// Reads little-endian fields off a byte array; any overrun sets ok = false.
struct Reader {
    const QByteArray &d;
    qsizetype at = 0;
    bool ok = true;
    bool bytes(void *dst, qsizetype n) {
        if (!ok || n < 0 || at + n > d.size()) { ok = false; return false; }
        std::memcpy(dst, d.constData() + at, size_t(n));
        at += n;
        return true;
    }
    int32_t i32() { int32_t v = 0; bytes(&v, 4); return v; }
    uint32_t u32() { uint32_t v = 0; bytes(&v, 4); return v; }
    std::vector<float> floats(size_t n, bool f16) {
        std::vector<float> v(n);
        if (f16) {
            std::vector<uint16_t> h(n);
            if (bytes(h.data(), qsizetype(n * 2)))
                for (size_t i = 0; i < n; ++i) v[i] = dsp::halfToFloat(h[i]);
        } else {
            bytes(v.data(), qsizetype(n * 4));
        }
        return v;
    }
};

bool fail(QString *err, const QString &why) {
    if (err) *err = why;
    return false;
}

} // namespace

// ── CTC net ────────────────────────────────────────────────────────────────

bool CtcNet::load(const QByteArray &data, QString *err) {
    Reader r{data};
    char magic[8];
    if (!r.bytes(magic, 8) || std::memcmp(magic, "H3CTCNT1", 8) != 0)
        return fail(err, QStringLiteral("not a CTC net file"));
    m_nin = r.i32(); m_C = r.i32(); m_kin = r.i32(); m_k = r.i32(); m_nb = r.i32(); m_nout = r.i32();
    const bool f16 = r.i32() != 0;
    if (!r.ok || m_nin <= 0 || m_C <= 0 || m_kin <= 0 || m_k <= 0 || m_nb < 0 || m_nout <= 0
        || m_nin > 4096 || m_C > 4096 || m_kin > 64 || m_k > 64 || m_nb > 64 || m_nout > 256)
        return fail(err, QStringLiteral("bad CTC net header"));
    m_dil.resize(size_t(m_nb));
    for (int &d : m_dil) d = r.i32();
    const size_t C = size_t(m_C);
    const std::vector<float> inw = r.floats(C * m_nin * m_kin, f16);
    m_inb = r.floats(C, f16);
    m_dww.resize(size_t(m_nb)); m_dwb.resize(size_t(m_nb)); m_pwT.resize(size_t(m_nb)); m_pwb.resize(size_t(m_nb));
    for (int b = 0; b < m_nb; ++b) {
        m_dww[b] = r.floats(C * m_k, f16);
        m_dwb[b] = r.floats(C, f16);
        const std::vector<float> pw = r.floats(C * C, f16);
        m_pwb[b] = r.floats(C, f16);
        m_pwT[b].resize(C * C);
        for (size_t o = 0; o < C; ++o)
            for (size_t i = 0; i < C; ++i) m_pwT[b][i * C + o] = pw[o * C + i];
    }
    m_outw = r.floats(size_t(m_nout) * C, f16);
    m_outb = r.floats(size_t(m_nout), f16);
    if (!r.ok || r.at != data.size()) return fail(err, QStringLiteral("CTC net file has the wrong size"));
    for (int d : m_dil)
        if (d <= 0 || d > 1024) return fail(err, QStringLiteral("bad CTC net dilation"));
    m_inT.resize(size_t(m_kin) * m_nin * C);
    for (size_t o = 0; o < C; ++o)
        for (int i = 0; i < m_nin; ++i)
            for (int j = 0; j < m_kin; ++j)
                m_inT[(size_t(j) * m_nin + i) * C + o] = inw[(o * m_nin + i) * m_kin + j];
    return true;
}

bool CtcNet::forward(const float *x, int T, float *out, const std::atomic<bool> *stop) const {
    const int C = m_C;
    std::vector<float> h(size_t(T) * C), d(size_t(T) * C), acc(static_cast<size_t>(C));
    const int p0 = m_kin / 2;
    for (int t = 0; t < T; ++t) {
        float *ht = &h[size_t(t) * C];
        for (int o = 0; o < C; ++o) ht[o] = m_inb[o];
        for (int j = 0; j < m_kin; ++j) {
            const int s = t + j - p0;
            if (s < 0 || s >= T) continue;
            const float *xs = x + size_t(s) * m_nin;
            for (int i = 0; i < m_nin; ++i) {
                const float xv = xs[i];
                const float *w = &m_inT[(size_t(j) * m_nin + i) * C];
                for (int o = 0; o < C; ++o) ht[o] += w[o] * xv;
            }
        }
        for (int o = 0; o < C; ++o) ht[o] = ht[o] > 0 ? ht[o] : 0;
    }
    for (int b = 0; b < m_nb; ++b) {
        if (stop && stop->load(std::memory_order_relaxed)) return false;
        const int dl = m_dil[b], pk = m_k / 2;
        const float *dw = m_dww[b].data();
        for (int t = 0; t < T; ++t) {
            float *dt = &d[size_t(t) * C];
            for (int c = 0; c < C; ++c) dt[c] = m_dwb[b][c];
            for (int j = 0; j < m_k; ++j) {
                const int s = t + (j - pk) * dl;
                if (s < 0 || s >= T) continue;
                const float *hs = &h[size_t(s) * C];
                for (int c = 0; c < C; ++c) dt[c] += dw[size_t(c) * m_k + j] * hs[c];
            }
        }
        for (int t = 0; t < T; ++t) {
            const float *dt = &d[size_t(t) * C];
            for (int o = 0; o < C; ++o) acc[o] = m_pwb[b][o];
            for (int i = 0; i < C; ++i) {
                const float v = dt[i];
                const float *w = &m_pwT[b][size_t(i) * C];
                for (int o = 0; o < C; ++o) acc[o] += w[o] * v;
            }
            float *ht = &h[size_t(t) * C];
            for (int o = 0; o < C; ++o) ht[o] += acc[o] > 0 ? acc[o] : 0;
        }
    }
    for (int t = 0; t < T; ++t) {
        const float *ht = &h[size_t(t) * C];
        float *ot = out + size_t(t) * m_nout;
        float mx = -1e30f;
        for (int o = 0; o < m_nout; ++o) {
            float s = m_outb[o];
            const float *w = &m_outw[size_t(o) * C];
            for (int i = 0; i < C; ++i) s += w[i] * ht[i];
            ot[o] = s;
            mx = s > mx ? s : mx;
        }
        double z = 0;
        for (int o = 0; o < m_nout; ++o) z += std::exp(double(ot[o] - mx));
        const float lz = mx + float(std::log(z));
        for (int o = 0; o < m_nout; ++o) ot[o] -= lz;
    }
    return true;
}

// ── detector ───────────────────────────────────────────────────────────────

bool Detector::load(const QByteArray &data, QString *err) {
    Reader r{data};
    char magic[8];
    if (!r.bytes(magic, 8) || std::memcmp(magic, "LSYNCNN1", 8) != 0)
        return fail(err, QStringLiteral("not a detector file"));
    const uint32_t hl = r.u32();
    if (!r.ok || hl > 1u << 20 || r.at + qsizetype(hl) > data.size())
        return fail(err, QStringLiteral("bad detector header"));
    const QJsonObject hdr = QJsonDocument::fromJson(data.mid(r.at, hl)).object();
    r.at += hl;
    m_nin = hdr.value(QStringLiteral("nin")).toInt();
    m_C = hdr.value(QStringLiteral("channels")).toInt();
    const int nets = hdr.value(QStringLiteral("nets")).toInt();
    m_dil.clear();
    for (const QJsonValue &v : hdr.value(QStringLiteral("dilations")).toArray()) m_dil.push_back(v.toInt());
    if (m_nin <= 0 || m_nin > 4096 || m_C <= 0 || m_C > 1024 || nets <= 0 || nets > 16 || m_dil.empty())
        return fail(err, QStringLiteral("bad detector header"));
    for (int d : m_dil)
        if (d <= 0 || d > 1024) return fail(err, QStringLiteral("bad detector dilation"));
    // The arrays must come in the order this loader reads them.
    const QJsonArray arrays = hdr.value(QStringLiteral("arrays")).toArray();
    const int perNet = 4 + 2 * int(m_dil.size());
    if (arrays.size() != nets * perNet) return fail(err, QStringLiteral("detector arrays do not match"));
    const size_t C = size_t(m_C);
    m_nets.assign(size_t(nets), {});
    for (int n = 0; n < nets; ++n) {
        Net &net = m_nets[n];
        net.wi = r.floats(C * m_nin, true);
        net.bi = r.floats(C, true);
        for (size_t k = 0; k < m_dil.size(); ++k) {
            net.wb.push_back(r.floats(C * C * 3, true));
            net.bb.push_back(r.floats(C, true));
        }
        net.wo = r.floats(2 * C, true);
        net.bo = r.floats(2, true);
    }
    if (!r.ok || r.at != data.size()) return fail(err, QStringLiteral("detector file has the wrong size"));
    return true;
}

namespace {
// y[o][t] = b[o] + sum_i sum_j w[o][i][j] * x[i][t + (j - (K-1)/2) * d], zero padded
void conv(const float *x, int ci, int T, const float *w, const float *b, int co, int K, int d, float *y) {
    for (int o = 0; o < co; ++o) {
        float *yo = y + size_t(o) * T;
        for (int t = 0; t < T; ++t) yo[t] = b[o];
        for (int i = 0; i < ci; ++i) {
            const float *xi = x + size_t(i) * T;
            for (int j = 0; j < K; ++j) {
                const float wv = w[(size_t(o) * ci + i) * K + j];
                const int sh = (j - (K - 1) / 2) * d;
                const int t0 = sh < 0 ? -sh : 0, t1 = sh > 0 ? T - sh : T;
                for (int t = t0; t < t1; ++t) yo[t] += wv * xi[t + sh];
            }
        }
    }
}
} // namespace

void Detector::forward(const float *xin, int T, std::vector<float> &vocal, std::vector<float> &start) const {
    vocal.assign(size_t(T), 0.f);
    start.assign(size_t(T), 0.f);
    if (T <= 0) return;
    const size_t C = size_t(m_C);
    std::vector<float> x(size_t(m_nin) * T);
    for (int t = 0; t < T; ++t)
        for (int i = 0; i < m_nin; ++i) x[size_t(i) * T + t] = xin[size_t(t) * m_nin + i];
    std::vector<float> h(C * T), r(C * T), y(2 * size_t(T));
    std::vector<float> sum(2 * size_t(T), 0.f);
    for (const Net &n : m_nets) {
        conv(x.data(), m_nin, T, n.wi.data(), n.bi.data(), m_C, 1, 1, h.data());
        for (float &v : h) v = v > 0 ? v : 0;
        for (size_t k = 0; k < m_dil.size(); ++k) {
            conv(h.data(), m_C, T, n.wb[k].data(), n.bb[k].data(), m_C, 3, m_dil[k], r.data());
            for (size_t i = 0; i < h.size(); ++i) h[i] += r[i] > 0 ? r[i] : 0;
        }
        conv(h.data(), m_C, T, n.wo.data(), n.bo.data(), 2, 1, 1, y.data());
        for (size_t i = 0; i < y.size(); ++i) sum[i] += y[i];
    }
    const float k = float(m_nets.size());
    for (int t = 0; t < T; ++t) {
        vocal[t] = sum[t] / k;
        start[t] = sum[size_t(T) + t] / k;
    }
}

} // namespace lyricsync
