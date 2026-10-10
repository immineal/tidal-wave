// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QColor>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QQmlEngine>
#include <QQueue>
#include <QString>
#include <QMutex>

// The cover-derived gradient behind the fullscreen Now Playing page: one
// colour from the artwork, held to a luminance the page's type stays legible
// against. coverart:: is the arithmetic, pure functions over a QImage and two
// palette colours. CoverColorStore caches one colour per cover, filled by the
// image provider on the loader thread. CoverTint is the QML-facing object.
namespace coverart {

// The cover is scaled to this size, smoothly, before sampling.
inline constexpr int kSampleSize = 32;

// 15 degrees each: red and orange differ, and dithering noise does not split
// one flat colour across two bins.
inline constexpr int kHueBins = 24;

// A pixel has to be this colourful to vote. White, black and every grey fall
// below it.
inline constexpr double kMinSaturation = 0.18;

// A pixel has to be this bright to vote: the hue of a near-black pixel is
// mostly quantisation noise. No ceiling; white fails the saturation floor.
inline constexpr double kMinValue = 0.12;

// WCAG 2.1 relative luminance, and CIE L*, which is monotone in it.
double relativeLuminance(const QColor &c);
double lightness(const QColor &c);
double luminanceForLightness(double l);

// The dominant colour of a cover, unclamped. Pixels vote for their hue bin
// weighted by saturation. A cover with no colourful pixel gives the mean of
// everything opaque. Invalid for a null or fully transparent image.
QColor dominant(const QImage &image);

// Clamps `c` into the CIE L* band spanned by two palette grounds. A tint
// between two grounds that both clear a text contrast threshold clears it
// too. Mixes towards black or white in linear light; the result is in band.
QColor clampToBand(const QColor &c, const QColor &bg, const QColor &limit);

// dominant() then clampToBand().
QColor tint(const QImage &image, const QColor &bg, const QColor &limit);

} // namespace coverart

// Cover id -> unclamped dominant colour. Unclamped because the clamp depends
// on the palette, which changes at run time. Written from the image loader
// thread and read from the GUI thread, so every accessor takes the mutex.
class CoverColorStore : public QObject {
    Q_OBJECT
public:
    // Bounds the cache, counted in covers.
    static constexpr int maxEntries = 512;

    static CoverColorStore *instance();

    bool   contains(const QString &id) const;
    QColor lookup(const QString &id) const;   // invalid when absent

    // Extract and store, unless `id` is already known. Safe from any thread.
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
// `hasColor` is false while the object is inactive, no cover is set or the
// artwork has not been seen; the page then paints its fallback.
class CoverTint : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    // The cover's provider id, the string that goes into "image://tidal/...".
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
