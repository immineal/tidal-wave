// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QtGlobal>
#include <QQmlEngine>
#include <QPointer>
#include <QVariantList>
#include <QElapsedTimer>
#include <QList>
#include <vector>

class QAudioBuffer;
class QTimer;

// Whether this build can tap the decoded audio: QAudioBufferOutput arrived in
// Qt 6.8. A macro, so the 6.4 path can be compiled on a newer Qt by defining
// it to 0. At runtime ask availableAtCompileTime().
#if !defined(TIDALWAVE_HAS_BUFFER_OUTPUT)
#  if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
#    define TIDALWAVE_HAS_BUFFER_OUTPUT 1
#  else
#    define TIDALWAVE_HAS_BUFFER_OUTPUT 0
#  endif
#endif

// Five band levels, 0..1, taken off the audio that is playing, for the bars
// in PlayingIndicator. A QML singleton: the indicator is a leaf component
// inside list delegates, and test hosts instantiate it with no context.
class SpectrumAnalyzer : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Spectrum)
    QML_SINGLETON

    // Five doubles in 0..1, bass first. Always five, even when idle.
    Q_PROPERTY(QVariantList levels READ levels NOTIFY levelsChanged)
    // The levels mean something right now: switched on, and audio arriving.
    // When false the indicator runs its own animation.
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    // The preference, after availability. Distinct from `active` because a
    // paused track is enabled and not active.
    Q_PROPERTY(bool enabled READ enabled NOTIFY enabledChanged)
    // False on a Qt without QAudioBufferOutput; the Settings row hides itself.
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    // Five bars in the glyph, five bands here. PlayingIndicator's box is
    // eight bar widths: five bars and four gaps.
    static constexpr int kBands = 5;

    // 2048 points, hopped by half: 21.5 Hz per bin at 44.1 kHz. 1024 leaves
    // barely two bins inside the 50-150 Hz band.
    static constexpr int kFftSize = 2048;
    static constexpr int kHopSize = kFftSize / 2;

    // How often the levels are published; buffers arrive far more often.
    static constexpr int kPublishMs = 40;      // 25 Hz
    // No audio for this long and the bars go back to their own animation.
    static constexpr int kIdleTimeoutMs = 400;

    // No default for parent: Qt builds a default-constructible QML_SINGLETON
    // itself and never calls create().
    explicit SpectrumAnalyzer(QObject *parent);
    ~SpectrumAnalyzer() override;

    // The one analyser, wired up before the engine loads any QML.
    static SpectrumAnalyzer *instance();
    static SpectrumAnalyzer *create(QQmlEngine *, QJSEngine *);

    static bool availableAtCompileTime();
    bool available() const { return availableAtCompileTime(); }

    // The six logarithmically spaced edges that make the five bands, in Hz.
    // Public for the tests.
    static QList<double> bandEdgesHz();

    bool enabled() const { return m_enabled; }
    bool active()  const { return m_active; }
    QVariantList  levels()     const;
    QList<double> bandLevels() const;

    // Runs the DSP or stops it; setPrefsSource() ends up here. Not gated on
    // availability: without QAudioBufferOutput the analyser works and never
    // receives a buffer, so its tests run on Qt 6.4 too.
    void setEnabled(bool on);

    // Watches a notifying bool property named "spectrumBars" on `source`, by
    // meta-object, so a test double works. A source without the property
    // warns and leaves the feature off.
    void setPrefsSource(QObject *source);

    // One decoded buffer; a format that cannot be read is dropped. Synchronous,
    // so the DSP is testable with no event loop. Not thread-safe: Player
    // connects it queued.
    void processBuffer(const QAudioBuffer &buffer);

    // Back to five zeros and inactive.
    void reset();

    // ── test hooks ──────────────────────────────────────────────────────
    // Nothing in the app calls these. They drive the QML bars without an
    // audio device, and are independent of enabled().
    Q_INVOKABLE void setLevelsForTest(const QVariantList &levels);
    Q_INVOKABLE void stopForTest();

signals:
    void levelsChanged();
    void activeChanged(bool active);
    void enabledChanged(bool enabled);

private slots:
    void refreshFromPrefs();

private:
    void publishTick();
    void analyseFrame();
    void rebuildBandBins(int sampleRate);
    void setActive(bool on);
    void clearLevels();

    QPointer<QObject> m_prefs;
    QTimer *m_publishTimer = nullptr;

    bool m_enabled = false;
    bool m_active  = false;

    // The envelope-followed levels, and the copy last published, so the tick
    // can skip emitting when nothing moved.
    double m_levels[kBands]    = {};
    double m_published[kBands] = {};

    // Monotonic time since the last accepted buffer.
    QElapsedTimer m_sinceBuffer;

    // Mono, windowed input. Filled to kFftSize, analysed, then slid by
    // kHopSize so consecutive frames overlap by half.
    std::vector<double> m_mono;
    int m_fill = 0;

    // Scratch for the transform, allocated once.
    std::vector<double> m_re, m_im;

    // The analysis window, and the constant that scales a sum of squared bins
    // so a full-scale tone inside one band reads 1.0 whatever the window.
    std::vector<double> m_window;
    double m_magScale = 1.0;

    // cos/sin table for the transform, kFftSize/2 entries.
    std::vector<double> m_twCos, m_twSin;

    // [first, lastInclusive] bin of each band, recomputed when the sample rate
    // changes. first > last means the band is above Nyquist at this rate.
    int m_binLo[kBands] = {};
    int m_binHi[kBands] = {};
    int m_binRate = 0;
};
