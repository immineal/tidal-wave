// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QByteArray>
#include <QString>
#include <vector>

// Plain C++ forward passes of the aligner's two conv nets. No ML runtime.
namespace lyricsync {

// The CTC letter net: x -> relu(conv5) -> blocks h += relu(pw(dw_dilated(h)))
// -> linear -> log_softmax. BatchNorm is folded into the weights file.
class CtcNet {
public:
    bool load(const QByteArray &data, QString *err);
    int inputs() const { return m_nin; }
    int outputs() const { return m_nout; }
    // x: T x inputs, out: T x outputs log-probs.
    void forward(const float *x, int T, float *out) const;

private:
    int m_nin = 0, m_C = 0, m_kin = 0, m_k = 0, m_nb = 0, m_nout = 0;
    std::vector<int> m_dil;
    std::vector<float> m_inT, m_inb, m_outw, m_outb;   // m_inT: [j][i][o]
    std::vector<std::vector<float>> m_dww, m_dwb, m_pwT, m_pwb;  // m_pwT: [i][o]
};

// The vocal and line-start detector: an ensemble of dilated kernel-3 conv
// nets over grid steps, outputs averaged.
class Detector {
public:
    bool load(const QByteArray &data, QString *err);
    int inputs() const { return m_nin; }
    // x: T x inputs. vocal, start: T logits each.
    void forward(const float *x, int T, std::vector<float> &vocal, std::vector<float> &start) const;

private:
    struct Net { std::vector<float> wi, bi, wo, bo; std::vector<std::vector<float>> wb, bb; };
    int m_nin = 0, m_C = 0;
    std::vector<int> m_dil;
    std::vector<Net> m_nets;
};

} // namespace lyricsync
