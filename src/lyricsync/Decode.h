// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <map>
#include <string>
#include <vector>

// ctcalign.py: CTC forced alignment of a song's whole lyric text, the start
// bonus, the gap re-alignment and the confidence features.
namespace lyricsync {

struct LineTargets {
    std::vector<int> tokens;        // every line's letters, in order
    std::vector<int> first;         // per line: index of its first letter, -1 for none
};

struct DecodeParams {
    double beta = 3.0, clip = 3.0, gam = 0.5, v0 = 0.0, switchS = 10.0;
    int lmin = 30;
};

struct Path {
    std::vector<long long> tf;      // first frame of each token
    double total = 0;
    std::vector<double> t;          // per line: start in seconds, NaN for none
};

struct Decoded {
    bool ok = false;
    Path a;
    bool switched = false;
    std::map<std::string, double> f;   // confidence features
};

// lp: T x 27 log-probs; start, vocal: detector logits per grid step.
Decoded decodeSong(const std::vector<float> &lp, int T, double fps, const std::vector<float> &start,
                   const std::vector<float> &vocal, const LineTargets &lines, const DecodeParams &p);

// numpy.interp over the lines with no time, or an even spread when none has one.
std::vector<double> fillTimes(const std::vector<double> &t, double dur);

} // namespace lyricsync
