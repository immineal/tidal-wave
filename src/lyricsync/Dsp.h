// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

// The aligner's signal processing, written to repeat the reference's numpy
// arithmetic: float32 where numpy works in float32, float64 where it widens.
namespace lyricsync::dsp {

constexpr int kRateIn  = 44100;
constexpr int kDecim   = 4;
constexpr int kRate    = kRateIn / kDecim;   // 11025 Hz
constexpr int kNfft    = 1024;
constexpr int kHop     = 256;
constexpr int kBins    = kNfft / 2 + 1;
constexpr int kMel     = 40;
constexpr int kGrid    = 4;                   // frames per grid step
constexpr double kFps  = double(kRate) / kHop;

float    halfToFloat(uint16_t h);
uint16_t floatToHalf(float f);     // round to nearest even
uint16_t doubleToHalf(double d);   // straight from double, as numpy does
inline float roundHalf(float f)   { return halfToFloat(floatToHalf(f)); }
inline float roundHalf(double d)  { return halfToFloat(doubleToHalf(d)); }

// The 63-tap low-pass and every 4th sample, on stereo input fed in pieces.
class Decimator {
public:
    Decimator();
    void push(const float *interleaved, size_t frames);
    // Flushes the tail; the output is then complete.
    void finish();
    size_t inputFrames() const { return m_in; }
    const std::vector<float> &left()  const { return m_out[0]; }
    const std::vector<float> &right() const { return m_out[1]; }
    void release() { m_out[0] = {}; m_out[1] = {}; }

private:
    void emitUpTo(size_t limit, bool atEnd);
    std::vector<double> m_h;
    std::vector<float> m_buf[2];   // input from m_base on
    size_t m_base = 0;             // input index of m_buf[*][0]
    size_t m_in = 0;               // input frames seen
    size_t m_next = 0;             // next input index to emit an output for
    std::vector<float> m_out[2];
};

// Five 40-band log spectra per STFT frame (mid, side, harm, vib, cen), each
// value rounded to float16 like the reference's stored features.
struct FrameFeatures {
    int frames = 0;
    std::vector<float> band[5];    // frames x 40
};
FrameFeatures frameFeatures(const std::vector<float> &left, const std::vector<float> &right);

// numpy.median and numpy.percentile (linear) of float32 data.
float  median(std::vector<float> v);
double percentile(std::vector<float> v, double q);
struct Quartiles { float median; double scale; };   // scale = max(p75 - p25, 1e-3)
Quartiles quartiles(std::vector<float> v);

// In-place complex FFT, n a power of two.
void fft(std::vector<double> &re, std::vector<double> &im);

} // namespace lyricsync::dsp
