#pragma once
#include <QColor>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QQmlEngine>
#include <QQueue>
#include <QString>
#include <QMutex>

// The cover-derived background gradient behind the fullscreen Now Playing
// page: one colour pulled out of the artwork, held to a luminance the page's
// own type is still legible against.
//
// Three pieces, in the order the data moves through them:
//
//   coverart::    the arithmetic. Pure functions over a QImage and two
//                 palette colours, which is what makes the whole of
//                 tests/tst_covercolor.cpp possible without a window, a
//                 network or a Tidal session.
//   CoverColorStore
//                 the cache. src/ui/ImageProvider.cpp hands it every cover it
//                 downloads, on the loader thread, so the extraction happens
//                 once per cover and never on the GUI thread.
//   CoverTint     the QML-facing object. qml/pages/NowPlayingPage.qml binds
//                 the gradient's top stop to it.
namespace coverart {

// The sample grid. A 1280px sleeve is scaled to 32x32 before anything looks
// at it, which is 1024 samples and about a quarter of a millisecond. Smooth
// scaling, not nearest: a box average over each cell is what stops a textured
// sleeve from being decided by whichever 1024 pixels the grid happened to land
// on. The averaging does invent colours along the edges between two regions,
// and those invented colours are always *less* saturated than either side -
// which the saturation weighting below then discounts on its own.
inline constexpr int kSampleSize = 32;

// 15 degrees each. Fine enough that red and orange are different answers,
// coarse enough that one flat colour cannot be split across two bins by
// dithering noise. Boundary splits are handled anyway: the winner is picked
// from a 3-bin smoothed score and averaged over the same three bins.
inline constexpr int kHueBins = 24;

// A pixel has to be this colourful to vote. Pure white, pure black and every
// grey fall below it, which is what makes "the most populous non-grey bucket"
// mean anything on a monochrome sleeve.
inline constexpr double kMinSaturation = 0.18;

// ...and this far off the floor. Near-black pixels carry a hue that is mostly
// quantisation noise, and a sleeve that is 90% black should be named by the
// 10% you can actually see. There is deliberately no ceiling to match: a pure
// yellow is value 1.0 and is still a colour, while white is excluded by the
// saturation floor above rather than by its brightness.
inline constexpr double kMinValue = 0.12;

// WCAG 2.1 relative luminance, and CIE L*. L* is a monotone function of Y, so
// the band the clamp enforces can be stated in whichever of the two reads
// better and means the same thing either way.
double relativeLuminance(const QColor &c);
double lightness(const QColor &c);
double luminanceForLightness(double l);

// The dominant colour of a cover, *unclamped* - the colour the artwork is,
// before anything is done to make it safe to paint. Invalid for a null or
// fully transparent image.
//
// Quantise-and-vote rather than a mean: every pixel that clears the two
// thresholds above votes for its hue bin with its saturation as the weight, so
// area still decides dominance but a vivid block is not outvoted by a wash of
// something nearly grey. The winning bin and its two neighbours are then
// averaged in linear light. A sleeve with no colourful pixel at all falls back
// to the linear-light mean of everything opaque, which is a grey - the honest
// answer for a monochrome cover, and one the clamp below can still place.
QColor dominant(const QImage &image);

// Clamp `c` into the closed CIE L* band spanned by `bg` and `limit`, which are
// two grounds of the current palette: the page background the gradient fades
// into, and the highest-elevation ground the palette guarantees text contrast
// against (Theme.surfaceHigh).
//
// This is the legibility rule, and it is deliberately derived rather than
// chosen. tests/tst_theme.cpp already holds textPrimary to 7.0, textSec to
// 4.5, textDim and accent to 3.0 against bg, surface and surfaceHigh on every
// one of the sixteen palette configurations. Contrast against a ground is
// monotone in that ground's luminance - upwards on a light theme, downwards on
// a dark one - so a tint whose luminance lies between two grounds that both
// clear a threshold clears it as well. Nothing here has to know which way the
// theme runs: min and max of the two do that.
//
// Lightness is moved by mixing towards black or towards white in linear light.
// Y is linear in that mix, so the target is hit exactly and the result cannot
// leave the sRGB gamut; mixing down scales every channel by one factor, which
// leaves hue and HSV saturation untouched. The 8-bit rounding is directional -
// down when darkening, up when lightening - so the result is inside the band
// and not a quantisation step outside it.
QColor clampToBand(const QColor &c, const QColor &bg, const QColor &limit);

// dominant() then clampToBand(). What the page actually wants.
QColor tint(const QImage &image, const QColor &bg, const QColor &limit);

} // namespace coverart

// Cover id -> unclamped dominant colour.
//
// Unclamped on purpose: the clamp depends on the palette, and the palette
// changes while the app is running. Caching the raw colour means a theme
// switch re-clamps what is already here instead of waiting for the artwork to
// be downloaded again - which it never would be, because Qt's own pixmap cache
// is holding it.
//
// Written from whichever thread QQuickPixmapReader runs the image provider on
// and read from the GUI thread, so every accessor takes the mutex. The
// `recorded` signal is emitted from the writing thread and reaches CoverTint
// as a queued call, because this object lives on the application thread.
class CoverColorStore : public QObject {
    Q_OBJECT
public:
    // Covers, not bytes: each entry is a string key and a QRgb. 512 is more
    // artwork than a session scrolls past, and the bound exists so a very long
    // session cannot grow this without end.
    static constexpr int maxEntries = 512;

    static CoverColorStore *instance();

    bool   contains(const QString &id) const;
    QColor lookup(const QString &id) const;   // invalid when absent

    // Extract and store, unless `id` is already known. Safe to call from any
    // thread; this is the one the image provider uses.
    void record(const QString &id, const QImage &image);

    // Store a colour that has already been worked out.
    void put(const QString &id, const QColor &colour);

    void clear();

signals:
    void recorded(const QString &id);

private:
    explicit CoverColorStore(QObject *parent = nullptr) : QObject(parent) {}

    mutable QMutex        m_lock;
    QHash<QString, QRgb>  m_colours;
    QQueue<QString>       m_order;     // insertion order, for the bound above
};

// What qml/pages/NowPlayingPage.qml binds the gradient's top stop to.
//
// It owns no colour of its own: `coverId` names a cover, the store supplies
// the artwork's colour whenever it turns up, and `bg`/`limit` are bound to
// Theme tokens so the clamp follows the palette. `hasColor` is false whenever
// the page should paint what it painted before this feature existed - the
// object is inactive, no cover is set, or the artwork has not been seen yet -
// which keeps the fallback to Theme.accentSoft a single expression in the QML.
class CoverTint : public QObject {
    Q_OBJECT
    QML_ELEMENT

    // Off unless the page says otherwise. The gradient is a fullscreen
    // treatment and a preference, and both live in the QML; this is where the
    // two of them arrive.
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    // The cover's provider id - the same string that goes into
    // "image://tidal/...", which is what the store is keyed by.
    Q_PROPERTY(QString coverId READ coverId WRITE setCoverId NOTIFY coverIdChanged)
    // Theme.bg and Theme.surfaceHigh. See coverart::clampToBand().
    Q_PROPERTY(QColor bg READ bg WRITE setBg NOTIFY bandChanged)
    Q_PROPERTY(QColor limit READ limit WRITE setLimit NOTIFY bandChanged)
    Q_PROPERTY(QColor color READ color NOTIFY colorChanged)
    Q_PROPERTY(bool hasColor READ hasColor NOTIFY colorChanged)

public:
    explicit CoverTint(QObject *parent = nullptr);

    bool    active() const   { return m_active; }
    QString coverId() const  { return m_coverId; }
    QColor  bg() const       { return m_bg; }
    QColor  limit() const    { return m_limit; }
    QColor  color() const    { return m_color; }
    bool    hasColor() const { return m_color.isValid(); }

    void setActive(bool v);
    void setCoverId(const QString &v);
    void setBg(const QColor &v);
    void setLimit(const QColor &v);

signals:
    void activeChanged();
    void coverIdChanged();
    void bandChanged();
    void colorChanged();

private:
    void refresh();

    bool    m_active = false;
    QString m_coverId;
    QColor  m_bg;
    QColor  m_limit;
    QColor  m_color;   // invalid means "paint the accent gradient instead"
};
