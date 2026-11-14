// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QByteArray>
#include <QString>
#include <QStringList>
#include <atomic>
#include <functional>
#include <memory>
#include <vector>

// The lyrics-to-audio aligner: plain lyrics and the track's audio in, a start
// time per sung line and a confidence out. A port of the reference pipeline
// (predict.py), with no ML library.
namespace lyricsync {

class Models;

// Everything that depends only on the audio.
struct Analysis {
    int frames = 0;                 // STFT frames, kFps a second
    std::vector<float> lp;          // frames x 27 letter log-probs
    std::vector<float> start, vocal;   // detector logits per 4 frames
    double seconds() const;
};

struct Timing { double decimate = 0, features = 0, detector = 0, ctc = 0, align = 0; };

// Stage outputs, for checks against the reference.
using DumpFn = std::function<void(const char *name, const std::vector<float> &data, int cols)>;

// Takes 44.1 kHz stereo in pieces of any size.
class FrontEnd {
public:
    FrontEnd();
    ~FrontEnd();
    void push(const float *interleavedStereo, size_t frames);
    size_t framesIn() const;
    // Checked during finish(); once true, finish() gives up with an empty Analysis.
    void setStop(const std::atomic<bool> *stop);
    // Empty when the audio is too short. Frees the samples either way.
    Analysis finish(const Models &m, Timing *timing = nullptr, const DumpFn &dump = {});

private:
    struct Impl;
    std::unique_ptr<Impl> d;
};

struct Alignment {
    QStringList lines;              // the sung lines, in text order
    std::vector<double> times;      // start of each, seconds
    double confidence = -9.0;
    bool aligned = false;           // false: no letters, or the song was too long
    bool kept = false;              // confidence at or above the threshold
};

Alignment align(const Analysis &a, const QString &plainText, const Models &m, Timing *timing = nullptr);
// [mm:ss.xx]line per sung line, as predict.py writes it.
QString toLrc(const Alignment &a);

class Models {
public:
    static std::shared_ptr<const Models> fromData(const QByteArray &ctc, const QByteArray &detector,
                                                  const QByteArray &translit, QString *err);
    // The ones built into the app; null when a resource is missing.
    static std::shared_ptr<const Models> builtin(QString *err = nullptr);
    // Bumped when anything that changes a result changes, so cached results
    // from an older aligner are not used.
    static constexpr int kVersion = 1;
    double threshold() const;

    struct Impl;
    const Impl &impl() const { return *d; }
    ~Models();

private:
    Models();
    std::unique_ptr<Impl> d;
};

} // namespace lyricsync
