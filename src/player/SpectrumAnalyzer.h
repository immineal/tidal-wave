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

// Whether this build can tap the decoded audio at all: QAudioBufferOutput
// arrived in Qt 6.8, and the Debian 12 box everything has to keep working on
// ships 6.4.2.
//
// A named macro rather than the version check written out at each of its three
// sites, so the old path can be compiled on a new Qt by defining it to 0 - it
// is the half of this feature that has no machine here to build it, and a
// guard nobody can compile is a guard that rots. Do not use it to decide
// anything at runtime; ask availableAtCompileTime(), which is what the
// preference and the QML read.
#if !defined(TIDALWAVE_HAS_BUFFER_OUTPUT)
#  if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
#    define TIDALWAVE_HAS_BUFFER_OUTPUT 1
#  else
#    define TIDALWAVE_HAS_BUFFER_OUTPUT 0
#  endif
#endif

// Five band levels, 0..1, taken off the audio that is actually playing.
//
// It exists for one thing: the five bars in VectorIcon's PlayingIndicator,
// which otherwise animate on a fixed random-looking schedule. Turned on in
// Settings, they stop inventing and show a very coarse spectrogram instead.
// That is the whole feature, which is also the measure of how much it is
// allowed to cost - a visualiser must never be the reason the app stutters,
// and it must never be the reason the app crashes.
//
// ── How it is reached ───────────────────────────────────────────────────────
//
// A QML singleton, in front of the DSP, exactly the way ThemePalette sits in
// front of the palette table. PlayingIndicator is a leaf component instantiated
// inside list delegates, and a singleton is the one channel such a thing can
// reach app state through: a context property would be undefined in the test
// hosts that instantiate the indicator bare, and an unqualified name that is
// not there is a QML warning, which tests/tst_firstrun.cpp fails on. The
// alternative - threading five numbers down through TrackRow and QueuePanel as
// delegate properties - would put a five-element array on every row of a 5000
// row queue to feed the one row that is playing.
//
// ── Why `instance()` and `create()` rather than a plain singleton ───────────
//
// Same reason, and the same hazard, as ThemePalette: Qt picks how to build a
// QML_SINGLETON by testing std::is_default_constructible FIRST and only then
// looking for create(). A default-constructible type gets a second instance
// built by the engine, create() is never called, and the bars quietly bind to
// an analyser nobody feeds. The `parent` argument below is therefore
// deliberately NOT defaulted, and SpectrumAnalyzer.cpp static_asserts that it
// stays that way.
//
// ── Qt version ─────────────────────────────────────────────────────────────
//
// Tapping the decoded audio needs QAudioBufferOutput, which arrived in Qt 6.8.
// Below that there is nothing to analyse, so availableAtCompileTime() is false,
// the preference cannot switch the feature on, and the bars keep their own
// animation. Everything in this class except that one fact compiles and is
// tested on Qt 6.4 - processBuffer() takes a QAudioBuffer, which has existed
// since Qt 5 - so the Debian 12 box builds, runs and passes the suite.
//
// ── Threading ──────────────────────────────────────────────────────────────
//
// processBuffer() is not thread-safe and does not need to be: Player connects
// QAudioBufferOutput::audioBufferReceived with Qt::QueuedConnection, so buffers
// are delivered on this object's own thread however the backend produced them.
class SpectrumAnalyzer : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Spectrum)
    QML_SINGLETON

    // Five doubles in 0..1, bass first. Always five, even when idle.
    Q_PROPERTY(QVariantList levels READ levels NOTIFY levelsChanged)
    // The levels mean something right now: switched on, and audio arriving.
    // This is what the QML tests before taking its bar heights from here; when
    // it is false the indicator runs its own animation exactly as it always
    // has.
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    // The preference, after availability. Distinct from `active` because a
    // paused track is enabled and not active.
    Q_PROPERTY(bool enabled READ enabled NOTIFY enabledChanged)
    // False on a Qt without QAudioBufferOutput. The Settings row hides itself
    // rather than offering a switch that cannot do anything.
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    // Five bars in the glyph, five bands here. Not a setting: the box
    // arithmetic in PlayingIndicator is exactly eight bar widths, which is
    // five bars and four gaps.
    static constexpr int kBands = 5;

    // 2048 points, hopped by half. At 44.1 kHz that is 21.5 Hz per bin and an
    // analysis every 23 ms. 1024 was tried first and gives 43 Hz bins, which
    // puts barely two bins inside the 50-150 Hz band - the bass bar then
    // measured mostly the window's own mainlobe.
    static constexpr int kFftSize = 2048;
    static constexpr int kHopSize = kFftSize / 2;

    // How often the levels are published. The decoder hands over a buffer
    // every few milliseconds; repainting every now-playing indicator at that
    // rate is not affordable, and nobody can see it either.
    static constexpr int kPublishMs = 40;      // 25 Hz
    // No audio for this long and the bars are released back to their own
    // animation. Long enough to ride out a buffer gap, short enough that a
    // pause does not leave a frozen spectrum on screen.
    static constexpr int kIdleTimeoutMs = 400;

    // Deliberately no default (see the class comment).
    explicit SpectrumAnalyzer(QObject *parent);
    ~SpectrumAnalyzer() override;

    // The one analyser. Application wires the Player and the preferences into
    // it before the engine loads any QML.
    static SpectrumAnalyzer *instance();
    static SpectrumAnalyzer *create(QQmlEngine *, QJSEngine *);

    // Whether this build can tap the audio at all.
    static bool availableAtCompileTime();
    bool available() const { return availableAtCompileTime(); }

    // The six logarithmically spaced edges that make the five bands, in Hz.
    // Public so a test can state which band a frequency belongs to without
    // keeping its own copy of the table.
    static QList<double> bandEdgesHz();

    bool enabled() const { return m_enabled; }
    bool active()  const { return m_active; }
    QVariantList  levels()     const;
    QList<double> bandLevels() const;

    // Run the DSP, or do not. The single door: watching the preference goes
    // through setPrefsSource(), and this is what that ends up calling.
    //
    // Deliberately *not* gated on availability. Availability is a statement
    // about whether anything can feed this object, not about whether it
    // works - on a Qt without QAudioBufferOutput the analyser is perfectly
    // functional and simply never receives a buffer, which is what lets the
    // whole of tests/tst_spectrum.cpp run on the Debian 12 box instead of
    // going dark on exactly the build least often exercised. The refusal
    // belongs one layer up, where the preference is read.
    void setEnabled(bool on);

    // Watches a notifying bool property named "spectrumBars" on `source`.
    // By meta-object rather than against Prefs directly, so a test double
    // works here without this class knowing the concrete type - the same
    // arrangement ThemePalette::setThemeSource() uses. A source without the
    // property warns and leaves the feature off.
    void setPrefsSource(QObject *source);

    // One decoded buffer. Any format QAudioFormat can describe is accepted;
    // anything it cannot be read as is dropped without touching the levels.
    // Synchronous, including the envelope, so the DSP is testable with no
    // event loop.
    void processBuffer(const QAudioBuffer &buffer);

    // Back to five zeros and inactive.
    void reset();

    // ── test hooks ──────────────────────────────────────────────────────
    // Nothing in the app calls these; processBuffer() is the only door the
    // app uses. They exist because the QML half of this feature - whether
    // the five bars actually follow the levels, and whether they go back to
    // their own animation afterwards - cannot otherwise be asserted without
    // an audio device, a Tidal stream and a real QMediaPlayer, none of which
    // a headless test run has. Deliberately independent of enabled(), so the
    // bars can be driven on a Qt where the feature itself is unavailable.
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

    // The envelope-followed levels, updated per analysis frame, and the copy
    // that was last published. levels() reads the live ones; the watermark is
    // only there so the tick can skip emitting when nothing moved.
    double m_levels[kBands]    = {};
    double m_published[kBands] = {};

    // Milliseconds since the last buffer we accepted. Monotonic, so it
    // survives a system clock change mid-track.
    QElapsedTimer m_sinceBuffer;

    // Mono, windowed input. Filled to kFftSize, analysed, then slid by
    // kHopSize so consecutive frames overlap by half.
    std::vector<double> m_mono;
    int m_fill = 0;

    // Scratch for the transform, allocated once.
    std::vector<double> m_re, m_im;

    // The analysis window, and the one constant derived from it that turns a
    // sum of squared bins back into the amplitude of the sine that produced
    // them - so a full-scale tone sitting inside one band reads exactly 1.0
    // whatever window is used, and swapping the window changes the shape of
    // the leakage without moving the scale.
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
