#include "CoverColor.h"

#include <QCoreApplication>
#include <QMutexLocker>
#include <QThread>

#include <algorithm>
#include <array>
#include <cmath>

namespace coverart {
namespace {

// sRGB transfer function, both ways. Every average and every mix below is done
// in linear light: averaging gamma-encoded channels is what turns two bright
// colours into something darker than either of them.
double toLinear(double v) {
    return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
}

double toGamma(double v) {
    v = std::clamp(v, 0.0, 1.0);
    return v <= 0.0031308 ? v * 12.92 : 1.055 * std::pow(v, 1.0 / 2.4) - 0.055;
}

QColor fromLinear(double r, double g, double b) {
    return QColor(qRound(toGamma(r) * 255.0),
                  qRound(toGamma(g) * 255.0),
                  qRound(toGamma(b) * 255.0));
}

// A linear-light mix, with the 8-bit rounding pushed in one direction.
//
// `roundDown` is the whole reason this is not three lines inline. The clamp
// promises its result is inside the band, and rounding to nearest can put a
// colour a quantisation step outside it - a step that is 0.27 of an L* unit
// next to black, which is exactly where the dark palettes' band ends. Flooring
// when darkening and ceiling when lightening makes the promise exact, at a
// cost of at most one 255th of a channel.
QColor mixLinear(const QColor &c, const QColor &towards, double t, bool roundDown) {
    auto channel = [&](double from, double to) {
        const double scaled = toGamma(from * (1.0 - t) + to * t) * 255.0;
        const double n = roundDown ? std::floor(scaled + 1e-6)
                                   : std::ceil(scaled - 1e-6);
        return int(std::clamp(n, 0.0, 255.0));
    };
    return QColor(channel(toLinear(c.redF()),   toLinear(towards.redF())),
                  channel(toLinear(c.greenF()), toLinear(towards.greenF())),
                  channel(toLinear(c.blueF()),  toLinear(towards.blueF())));
}

// The grey nearest the middle of a band. Only reached by a band narrower than
// one 8-bit step, which no palette in src/ui/ThemePalette.cpp has; it is here
// so that clampToBand() has an answer rather than a loop that cannot converge.
QColor greyInBand(double yLo, double yHi) {
    const double wanted = 0.5 * (yLo + yHi);
    int best = 0;
    double bestGap = 2.0;
    for (int v = 0; v <= 255; ++v) {
        const double y = toLinear(v / 255.0);
        const double gap = std::abs(y - wanted);
        const bool inside = y >= yLo && y <= yHi;
        if (inside && gap < bestGap) { best = v; bestGap = gap; }
    }
    if (bestGap < 2.0) return QColor(best, best, best);
    // Nothing lands inside: take the closest grey there is.
    for (int v = 0; v <= 255; ++v) {
        const double gap = std::abs(toLinear(v / 255.0) - wanted);
        if (gap < bestGap) { best = v; bestGap = gap; }
    }
    return QColor(best, best, best);
}

struct Bin {
    double weight = 0.0;
    double r = 0.0, g = 0.0, b = 0.0;   // weighted sums, linear light
};

} // namespace

double relativeLuminance(const QColor &c) {
    return 0.2126 * toLinear(c.redF())
         + 0.7152 * toLinear(c.greenF())
         + 0.0722 * toLinear(c.blueF());
}

double lightness(const QColor &c) {
    const double y = relativeLuminance(c);
    return y > 0.008856 ? 116.0 * std::cbrt(y) - 16.0 : 903.3 * y;
}

double luminanceForLightness(double l) {
    return l > 8.0 ? std::pow((l + 16.0) / 116.0, 3.0) : l / 903.3;
}

QColor dominant(const QImage &image) {
    if (image.isNull()) return {};

    const QImage small = image
        .scaled(kSampleSize, kSampleSize, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
        .convertToFormat(QImage::Format_ARGB32);
    if (small.isNull()) return {};

    std::array<Bin, kHueBins> bins{};
    // Everything opaque, unweighted - the fallback for a sleeve with no hue.
    double anyR = 0.0, anyG = 0.0, anyB = 0.0, anyN = 0.0;

    for (int y = 0; y < small.height(); ++y) {
        const QRgb *row = reinterpret_cast<const QRgb *>(small.constScanLine(y));
        for (int x = 0; x < small.width(); ++x) {
            const QRgb px = row[x];
            // Half-transparent and below is a hole in the artwork, not a
            // colour: a rounded corner or a logo's alpha channel.
            if (qAlpha(px) < 128) continue;

            const double lr = toLinear(qRed(px)   / 255.0);
            const double lg = toLinear(qGreen(px) / 255.0);
            const double lb = toLinear(qBlue(px)  / 255.0);
            anyR += lr; anyG += lg; anyB += lb; anyN += 1.0;

            float h = 0.0f, s = 0.0f, v = 0.0f;
            QColor::fromRgb(qRed(px), qGreen(px), qBlue(px)).getHsvF(&h, &s, &v);
            if (h < 0.0f) continue;                    // achromatic: no hue at all
            if (s < kMinSaturation || v < kMinValue) continue;

            const int bin = std::clamp(int(h * kHueBins), 0, kHueBins - 1);
            const double w = s;
            bins[bin].weight += w;
            bins[bin].r += lr * w;
            bins[bin].g += lg * w;
            bins[bin].b += lb * w;
        }
    }

    // Pick on a smoothed score so one flat colour sitting on a bin boundary is
    // not beaten by a spread-out one, then average over the same three bins so
    // the halves of a split hue come back together.
    int winner = -1;
    double best = 0.0;
    for (int i = 0; i < kHueBins; ++i) {
        const int prev = (i + kHueBins - 1) % kHueBins;
        const int next = (i + 1) % kHueBins;
        const double score = bins[i].weight
                           + 0.5 * (bins[prev].weight + bins[next].weight);
        if (score > best) { best = score; winner = i; }
    }

    if (winner >= 0) {
        double w = 0.0, r = 0.0, g = 0.0, b = 0.0;
        for (int d = -1; d <= 1; ++d) {
            const Bin &bin = bins[(winner + d + kHueBins) % kHueBins];
            w += bin.weight; r += bin.r; g += bin.g; b += bin.b;
        }
        if (w > 0.0) return fromLinear(r / w, g / w, b / w);
    }

    if (anyN <= 0.0) return {};   // nothing opaque at all
    return fromLinear(anyR / anyN, anyG / anyN, anyB / anyN);
}

QColor clampToBand(const QColor &c, const QColor &bg, const QColor &limit) {
    if (!c.isValid()) return {};
    if (!bg.isValid() || !limit.isValid()) return c;

    double yLo = relativeLuminance(bg);
    double yHi = relativeLuminance(limit);
    if (yLo > yHi) std::swap(yLo, yHi);

    QColor out = c.toRgb();
    const double y = relativeLuminance(out);
    if (y > yHi) {
        // Y is linear in a linear-light mix, so this factor lands on yHi
        // exactly. Towards black, which scales every channel alike and so
        // keeps the hue and the saturation the artwork had.
        out = mixLinear(out, QColor(Qt::black), 1.0 - yHi / y, /*roundDown=*/true);
    } else if (y < yLo) {
        // Upwards there is no equivalent: raising luminance past what the
        // channels can carry means adding white, which costs saturation. A
        // light theme is where this runs, and a pastel is the right answer
        // there anyway.
        out = mixLinear(out, QColor(Qt::white), (yLo - y) / (1.0 - y), /*roundDown=*/false);
    } else {
        return out;
    }

    const double after = relativeLuminance(out);
    if (after >= yLo - 1e-12 && after <= yHi + 1e-12) return out;
    return greyInBand(yLo, yHi);
}

QColor tint(const QImage &image, const QColor &bg, const QColor &limit) {
    return clampToBand(dominant(image), bg, limit);
}

} // namespace coverart

// ─── CoverColorStore ────────────────────────────────────────────────────────

CoverColorStore *CoverColorStore::instance() {
    static QMutex guard;
    static CoverColorStore *store = nullptr;
    QMutexLocker locked(&guard);
    if (!store) {
        // Never deleted: it outlives every page that reads it, and tearing a
        // QObject down from under a loader thread at exit buys nothing.
        store = new CoverColorStore;
        // The first caller may be the image loader thread. Push the object
        // onto the application thread so that `recorded` reaches the GUI as a
        // queued call rather than running CoverTint's slot off-thread.
        if (QCoreApplication::instance()
            && store->thread() != QCoreApplication::instance()->thread())
            store->moveToThread(QCoreApplication::instance()->thread());
    }
    return store;
}

bool CoverColorStore::contains(const QString &id) const {
    QMutexLocker locked(&m_lock);
    return m_colours.contains(id);
}

QColor CoverColorStore::lookup(const QString &id) const {
    QMutexLocker locked(&m_lock);
    const auto it = m_colours.constFind(id);
    return it == m_colours.cend() ? QColor() : QColor::fromRgb(*it);
}

void CoverColorStore::record(const QString &id, const QImage &image) {
    if (id.isEmpty() || image.isNull()) return;
    if (contains(id)) return;   // one extraction per cover, not one per load
    const QColor colour = coverart::dominant(image);
    if (!colour.isValid()) return;
    put(id, colour);
}

void CoverColorStore::put(const QString &id, const QColor &colour) {
    if (id.isEmpty() || !colour.isValid()) return;
    {
        QMutexLocker locked(&m_lock);
        if (!m_colours.contains(id)) m_order.enqueue(id);
        m_colours.insert(id, colour.rgb());
        while (m_order.size() > maxEntries) {
            const QString oldest = m_order.dequeue();
            m_colours.remove(oldest);
        }
    }
    emit recorded(id);
}

void CoverColorStore::clear() {
    QMutexLocker locked(&m_lock);
    m_colours.clear();
    m_order.clear();
}

// ─── CoverTint ──────────────────────────────────────────────────────────────

CoverTint::CoverTint(QObject *parent)
    : QObject(parent)
{
    connect(CoverColorStore::instance(), &CoverColorStore::recorded,
            this, [this](const QString &id) {
                // The cover this object is waiting for usually finishes
                // downloading after the page has already asked for it.
                if (id == m_coverId) refresh();
            });
}

void CoverTint::setActive(bool v) {
    if (v == m_active) return;
    m_active = v;
    emit activeChanged();
    refresh();
}

void CoverTint::setCoverId(const QString &v) {
    if (v == m_coverId) return;
    m_coverId = v;
    emit coverIdChanged();
    refresh();
}

void CoverTint::setBg(const QColor &v) {
    if (v == m_bg) return;
    m_bg = v;
    emit bandChanged();
    refresh();
}

void CoverTint::setLimit(const QColor &v) {
    if (v == m_limit) return;
    m_limit = v;
    emit bandChanged();
    refresh();
}

void CoverTint::refresh() {
    QColor next;
    if (m_active && !m_coverId.isEmpty()) {
        const QColor raw = CoverColorStore::instance()->lookup(m_coverId);
        if (raw.isValid())
            next = coverart::clampToBand(raw, m_bg, m_limit);
    }
    if (next == m_color) return;
    m_color = next;
    emit colorChanged();
}
