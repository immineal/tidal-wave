// The cover-derived background gradient, written before src/ui/CoverColor.cpp
// per the project's tests-first rule (SPEC G4).
//
// Two halves, and the second is the one that matters.
//
//   dominant()  pulls one colour out of an album cover. The bar is not "some
//               plausible average" - a mean gives mud, and a 50/50 red-and-blue
//               sleeve must not come back purple - so the assertions below are
//               about hue and saturation, not about an exact byte triple.
//
//   clamp       is what keeps the page readable. A cover can be pure white,
//               pure black or fully saturated neon, and whatever comes out of
//               it is painted behind textPrimary, textSec, textDim and the
//               accent. The rule is written down once, here:
//
//                   the tint's CIE L* is clamped into the closed band spanned
//                   by the palette's own `bg` and `surfaceHigh`.
//
//               That is not an arbitrary pair of numbers. L* is a monotone
//               function of WCAG relative luminance, so clamping L* clamps Y
//               exactly; and tests/tst_theme.cpp already holds every text token
//               to its threshold against bg, surface *and* surfaceHigh. A tint
//               whose luminance lies between two grounds that both clear 7.0 /
//               4.5 / 3.0 therefore clears them too, for every one of the
//               sixteen palette configurations, with no second table of numbers
//               to keep in step.
//
//               It is also where the gradient already sits. The top stop is
//               Theme.accentSoft, a 10-12% accent wash over bg, and composited
//               that lands at L* 3.4-9.2 on the dark themes against a band of
//               0-13.1, and at L* 91.2-94.5 on the light ones against a band of
//               88.0-100. So the cover tint is no heavier than the accent
//               gradient it replaces - checked below, because that is the
//               reason the band is this band and not a invented one.

#include <QTest>
#include <QColor>
#include <QImage>
#include <QSignalSpy>
#include <QVariantMap>

#include "ui/CoverColor.h"
#include "ui/ThemePalette.h"

namespace {

// WCAG 2.1 relative luminance and contrast, and CIE L*a*b* with dE76 - the
// same four helpers tests/tst_theme.cpp uses, so a threshold quoted here means
// what it means over there.
double luminance(const QColor &c) {
    auto channel = [](double v) {
        return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * channel(c.redF()) + 0.7152 * channel(c.greenF())
         + 0.0722 * channel(c.blueF());
}

double contrast(const QColor &a, const QColor &b) {
    const double la = luminance(a), lb = luminance(b);
    return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}

struct Lab { double l, a, b; };

Lab toLab(const QColor &c) {
    auto lin = [](double v) {
        return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
    };
    const double r = lin(c.redF()), g = lin(c.greenF()), b = lin(c.blueF());
    const double x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
    const double y =  r * 0.2126 + g * 0.7152 + b * 0.0722;
    const double z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;
    auto f = [](double t) {
        return t > 0.008856 ? std::cbrt(t) : 7.787 * t + 16.0 / 116.0;
    };
    const double fx = f(x), fy = f(y), fz = f(z);
    return { 116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz) };
}

double deltaE(const QColor &a, const QColor &b) {
    const Lab p = toLab(a), q = toLab(b);
    return std::sqrt((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a)
                   + (p.b - q.b) * (p.b - q.b));
}

// The same compositing Qt does when it paints a translucent wash, so the
// accentSoft comparison below measures pixels and not an alpha value.
QColor composite(const QColor &wash, const QColor &ground) {
    const double a = wash.alphaF();
    return QColor::fromRgbF(float(wash.redF()   * a + ground.redF()   * (1.0 - a)),
                            float(wash.greenF() * a + ground.greenF() * (1.0 - a)),
                            float(wash.blueF()  * a + ground.blueF()  * (1.0 - a)));
}

// Hue in degrees, and the shortest way round the circle between two of them.
double hueDeg(const QColor &c) { return c.toHsv().hsvHueF() * 360.0; }

double hueGap(double a, double b) {
    double d = std::fmod(std::abs(a - b), 360.0);
    return d > 180.0 ? 360.0 - d : d;
}

double sat(const QColor &c) { return c.toHsv().hsvSaturationF(); }

// ── synthetic covers ────────────────────────────────────────────────────
//
// 256px square, which is the shape a real sleeve arrives in and eight times
// the sample grid, so the downscale inside dominant() is doing real work
// rather than copying pixels.
constexpr int kCover = 256;

QImage solid(const QColor &c) {
    QImage img(kCover, kCover, QImage::Format_ARGB32);
    img.fill(c);
    return img;
}

// `fraction` of the width in `left`, the rest in `right`.
QImage split(const QColor &left, const QColor &right, double fraction) {
    QImage img(kCover, kCover, QImage::Format_ARGB32);
    const int edge = qBound(0, qRound(kCover * fraction), kCover);
    for (int y = 0; y < kCover; ++y)
        for (int x = 0; x < kCover; ++x)
            img.setPixelColor(x, y, x < edge ? left : right);
    return img;
}

// A black-and-white photograph: greys only, with structure rather than noise,
// so the smooth downscale cannot average it into one flat value.
QImage greyscalePhoto() {
    QImage img(kCover, kCover, QImage::Format_ARGB32);
    for (int y = 0; y < kCover; ++y) {
        for (int x = 0; x < kCover; ++x) {
            const int v = qBound(0, int(20 + 200.0 * std::abs(std::sin(x * 0.05))
                                            * std::abs(std::cos(y * 0.03))), 255);
            img.setPixelColor(x, y, QColor(v, v, v));
        }
    }
    return img;
}

// A near-white sleeve with a small vivid block on it. The block is the colour
// anybody asked would name, and it is a few percent of the pixels.
QImage logoOnWhite(const QColor &logo) {
    QImage img(kCover, kCover, QImage::Format_ARGB32);
    img.fill(QColor(250, 250, 248));
    for (int y = 100; y < 156; ++y)
        for (int x = 100; x < 156; ++x)
            img.setPixelColor(x, y, logo);
    return img;
}

QImage fullyTransparent() {
    QImage img(kCover, kCover, QImage::Format_ARGB32);
    img.fill(Qt::transparent);
    return img;
}

} // namespace

class TestCoverColor : public QObject {
    Q_OBJECT

private slots:

    // ── extraction ──────────────────────────────────────────────────────

    void aSolidSleeveIsItsOwnColour_data() {
        QTest::addColumn<QColor>("in");
        QTest::newRow("red")     << QColor(255,   0,   0);
        QTest::newRow("green")   << QColor(  0, 200,  60);
        QTest::newRow("blue")    << QColor( 30,  60, 220);
        QTest::newRow("magenta") << QColor(220,  30, 180);
        QTest::newRow("amber")   << QColor(230, 150,  20);
    }
    void aSolidSleeveIsItsOwnColour() {
        QFETCH(QColor, in);
        const QColor out = coverart::dominant(solid(in));
        QVERIFY2(out.isValid(), "a solid sleeve produced no colour at all");
        // Hue, not bytes: the downscale and the linear-light average are
        // allowed to move a channel, they are not allowed to change the
        // colour's name.
        QVERIFY2(hueGap(hueDeg(out), hueDeg(in)) <= 6.0,
                 qPrintable(QStringLiteral("hue moved from %1 to %2")
                                .arg(hueDeg(in), 0, 'f', 1).arg(hueDeg(out), 0, 'f', 1)));
        QVERIFY2(sat(out) >= sat(in) - 0.06,
                 qPrintable(QStringLiteral("saturation fell from %1 to %2")
                                .arg(sat(in), 0, 'f', 3).arg(sat(out), 0, 'f', 3)));
    }

    // The three sleeves that break a naive mean, and the reason this is not
    // just QImage::scaled(1, 1).
    void aHalfAndHalfSleeveIsNotMud() {
        const QColor red(255, 0, 0), blue(0, 0, 255);
        const QColor out = coverart::dominant(split(red, blue, 0.5));
        QVERIFY(out.isValid());
        // The mean of the two is #7F007F - a purple that is in neither half of
        // the sleeve. Either answer is defensible; the blend is not.
        const bool isOne = hueGap(hueDeg(out), hueDeg(red)) <= 14.0
                        || hueGap(hueDeg(out), hueDeg(blue)) <= 14.0;
        QVERIFY2(isOne, qPrintable(QStringLiteral("hue %1 is neither half (0 or 240)")
                                       .arg(hueDeg(out), 0, 'f', 1)));
        QVERIFY2(sat(out) >= 0.80,
                 qPrintable(QStringLiteral("washed out to saturation %1")
                                .arg(sat(out), 0, 'f', 3)));
        QVERIFY2(deltaE(out, QColor(127, 0, 127)) > 25.0,
                 "came back as the mean of the two halves");
    }

    void theLargerHalfWins() {
        const QColor red(255, 0, 0), blue(0, 0, 255);
        QColor out = coverart::dominant(split(red, blue, 0.72));
        QVERIFY2(hueGap(hueDeg(out), hueDeg(red)) <= 14.0,
                 qPrintable(QStringLiteral("72%% red gave hue %1").arg(hueDeg(out), 0, 'f', 1)));
        out = coverart::dominant(split(red, blue, 0.28));
        QVERIFY2(hueGap(hueDeg(out), hueDeg(blue)) <= 14.0,
                 qPrintable(QStringLiteral("72%% blue gave hue %1").arg(hueDeg(out), 0, 'f', 1)));
    }

    // Near-white and near-black are discarded, which is what lets a small
    // vivid mark on a white sleeve be the sleeve's colour.
    void aVividMarkBeatsAWhiteField() {
        const QColor logo(0, 170, 90);
        const QColor out = coverart::dominant(logoOnWhite(logo));
        QVERIFY(out.isValid());
        QVERIFY2(hueGap(hueDeg(out), hueDeg(logo)) <= 12.0,
                 qPrintable(QStringLiteral("hue %1, wanted %2")
                                .arg(hueDeg(out), 0, 'f', 1).arg(hueDeg(logo), 0, 'f', 1)));
        QVERIFY2(sat(out) >= 0.55,
                 qPrintable(QStringLiteral("saturation %1").arg(sat(out), 0, 'f', 3)));
    }

    // Pure white, pure black and a greyscale photograph have no dominant hue
    // at all. They must still produce something - the gradient has to paint -
    // and that something must not be a hue the extractor invented out of
    // rounding noise.
    void anAchromaticSleeveStaysAchromatic_data() {
        QTest::addColumn<QImage>("cover");
        QTest::addColumn<int>("roughly");   // expected 0-255 grey level
        QTest::newRow("pure white")      << solid(Qt::white)          << 255;
        QTest::newRow("pure black")      << solid(Qt::black)          << 0;
        QTest::newRow("mid grey")        << solid(QColor(128,128,128)) << 128;
        QTest::newRow("greyscale photo") << greyscalePhoto()           << -1;
    }
    void anAchromaticSleeveStaysAchromatic() {
        QFETCH(QImage, cover);
        QFETCH(int, roughly);
        const QColor out = coverart::dominant(cover);
        QVERIFY2(out.isValid(), "an achromatic sleeve produced no colour at all");
        QVERIFY2(sat(out) <= 0.08,
                 qPrintable(QStringLiteral("invented a hue: %1 at saturation %2")
                                .arg(hueDeg(out), 0, 'f', 1).arg(sat(out), 0, 'f', 3)));
        if (roughly >= 0)
            QVERIFY2(std::abs(out.red() - roughly) <= 6,
                     qPrintable(QStringLiteral("grey level %1, wanted about %2")
                                    .arg(out.red()).arg(roughly)));
    }

    void anEmptySleeveHasNoColour() {
        QVERIFY(!coverart::dominant(QImage()).isValid());
        QVERIFY(!coverart::dominant(fullyTransparent()).isValid());
    }

    // ── the clamp ───────────────────────────────────────────────────────

    // The whole point. Every palette configuration, against the sleeves most
    // likely to break one: the four corners of the colour cube, a neon, and
    // the two achromatic extremes.
    void theClampKeepsEveryTextTokenLegible_data() { coverRows(); }
    void theClampKeepsEveryTextTokenLegible() {
        QFETCH(QString, theme);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        QFETCH(QImage, cover);

        const QVariantMap p = theme::palette(theme, oled, tinted);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };
        const QColor bg = col("bg"), limit = col("surfaceHigh");

        const QColor t = coverart::tint(cover, bg, limit);
        QVERIFY2(t.isValid(), "no tint for a sleeve that has pixels in it");

        const QString where = theme + (oled ? " black" : "") + (tinted ? " tinted" : "");

        // The band, stated in L*. Nothing in here is allowed to be outside it,
        // not by a quantisation step: clampLightness() rounds towards the band
        // rather than to nearest for exactly this assertion.
        const double lo = std::min(toLab(bg).l, toLab(limit).l);
        const double hi = std::max(toLab(bg).l, toLab(limit).l);
        QVERIFY2(toLab(t).l >= lo - 1e-6 && toLab(t).l <= hi + 1e-6,
                 qPrintable(QStringLiteral("%1: tint at L* %2, band is %3..%4")
                                .arg(where).arg(toLab(t).l, 0, 'f', 2)
                                .arg(lo, 0, 'f', 2).arg(hi, 0, 'f', 2)));

        // ...and the consequence, measured rather than argued. These are the
        // same four thresholds tst_theme.cpp holds the grounds to.
        auto check = [&](const char *token, double floorRatio) {
            const double c = contrast(col(token), t);
            QVERIFY2(c >= floorRatio,
                     qPrintable(QStringLiteral("%1: %2 on the cover tint is %3, wanted %4")
                                    .arg(where, QLatin1String(token))
                                    .arg(c, 0, 'f', 2).arg(floorRatio, 0, 'f', 1)));
        };
        check("textPrimary", 7.0);
        check("textSec",     4.5);
        check("textDim",     3.0);
        check("accent",      3.0);
    }

    // The band is the band because it is where the gradient already sits. If
    // the accent wash it replaces ever moves outside it, the cover tint would
    // be visibly lighter or heavier than today's page and this test is the
    // warning.
    void theBandContainsTheAccentGradientItReplaces_data() { themeRows(); }
    void theBandContainsTheAccentGradientItReplaces() {
        QFETCH(QString, theme);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(theme, oled, tinted);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        const QColor bg = col("bg"), limit = col("surfaceHigh");
        const QColor today = composite(col("accentSoft"), bg);
        const double lo = std::min(toLab(bg).l, toLab(limit).l);
        const double hi = std::max(toLab(bg).l, toLab(limit).l);
        QVERIFY2(toLab(today).l >= lo - 1e-6 && toLab(today).l <= hi + 1e-6,
                 qPrintable(QStringLiteral("%1: accentSoft over bg is L* %2, band is %3..%4")
                                .arg(theme).arg(toLab(today).l, 0, 'f', 2)
                                .arg(lo, 0, 'f', 2).arg(hi, 0, 'f', 2)));
    }

    // Clamping moves lightness and nothing else. A red sleeve on a dark theme
    // has to come back a deep red, not a grey and not an orange - otherwise
    // the feature is just a second way of drawing the page background.
    void theClampMovesLightnessAndNotHue_data() {
        QTest::addColumn<QColor>("in");
        QTest::newRow("red")   << QColor(255,   0,   0);
        QTest::newRow("neon")  << QColor( 57, 255,  20);
        QTest::newRow("cyan")  << QColor(  0, 255, 255);
        QTest::newRow("amber") << QColor(255, 176,   0);
    }
    void theClampMovesLightnessAndNotHue() {
        QFETCH(QColor, in);
        // Sea in black: the darkest band the app has, 0.0 to 7.2 in L*.
        const QVariantMap p = theme::palette(QStringLiteral("sea"), true, false);
        const QColor bg = p.value("bg").value<QColor>();
        const QColor limit = p.value("surfaceHigh").value<QColor>();

        const QColor out = coverart::clampToBand(in, bg, limit);
        // 12 degrees, not 3. Darkening in linear light is hue-exact in
        // arithmetic; the error is the 8-bit grid it has to land on. At the
        // bottom of that band a channel is a single-digit byte, one step of it
        // is several degrees of hue, and the clamp rounds down rather than to
        // nearest because the band has to be respected exactly. 12 degrees is
        // comfortably inside one colour name - red stays red, green green -
        // which is what the page needs; measured worst case here is 7.2.
        QVERIFY2(hueGap(hueDeg(out), hueDeg(in)) <= 12.0,
                 qPrintable(QStringLiteral("hue %1 became %2")
                                .arg(hueDeg(in), 0, 'f', 1).arg(hueDeg(out), 0, 'f', 1)));
        // ...and it is still a colour, not a grey that happens to be one byte
        // off on each channel. Chroma in Lab, where ~2.3 is the smallest
        // difference an eye can see at all.
        const Lab lab = toLab(out);
        const double chroma = std::sqrt(lab.a * lab.a + lab.b * lab.b);
        QVERIFY2(chroma >= 8.0,
                 qPrintable(QStringLiteral("clamped down to chroma %1 - that is a grey")
                                .arg(chroma, 0, 'f', 2)));
        // Darkening in linear light scales every channel by one factor, so a
        // fully saturated colour stays fully saturated.
        QVERIFY2(sat(out) >= 0.85,
                 qPrintable(QStringLiteral("saturation fell to %1").arg(sat(out), 0, 'f', 3)));
        QVERIFY2(toLab(out).l < toLab(in).l,
                 "a neon was not darkened at all");
    }

    // A colour already inside the band is returned untouched - the clamp is
    // not allowed to drift a tint that was already fine.
    void theClampLeavesAnInBandColourAlone() {
        const QVariantMap p = theme::palette(QStringLiteral("sea"), false, false);
        const QColor bg = p.value("bg").value<QColor>();
        const QColor limit = p.value("surfaceHigh").value<QColor>();
        const QColor inside = composite(p.value("accentSoft").value<QColor>(), bg);
        QCOMPARE(coverart::clampToBand(inside, bg, limit).rgb(), inside.rgb());
    }

    // Both directions, and both themes. A black sleeve on a light theme has to
    // be pulled *up*, which is the half that is easy to forget.
    void theClampWorksInBothDirections() {
        const QVariantMap dark  = theme::palette(QStringLiteral("sea"), false, false);
        const QVariantMap light = theme::palette(QStringLiteral("sky"), false, false);

        const QColor whiteOnDark = coverart::clampToBand(
            QColor(Qt::white), dark.value("bg").value<QColor>(),
            dark.value("surfaceHigh").value<QColor>());
        QVERIFY2(toLab(whiteOnDark).l <= toLab(dark.value("surfaceHigh").value<QColor>()).l + 1e-6,
                 "pure white was not pulled down on a dark theme");

        const QColor blackOnLight = coverart::clampToBand(
            QColor(Qt::black), light.value("bg").value<QColor>(),
            light.value("surfaceHigh").value<QColor>());
        QVERIFY2(toLab(blackOnLight).l >= toLab(light.value("surfaceHigh").value<QColor>()).l - 1e-6,
                 "pure black was not lifted on a light theme");
    }

    void anInvalidColourClampsToNothing() {
        const QVariantMap p = theme::palette(QStringLiteral("sea"), false, false);
        QVERIFY(!coverart::clampToBand(QColor(), p.value("bg").value<QColor>(),
                                       p.value("surfaceHigh").value<QColor>()).isValid());
        QVERIFY(!coverart::tint(QImage(), p.value("bg").value<QColor>(),
                                p.value("surfaceHigh").value<QColor>()).isValid());
    }

    // ── the cache ───────────────────────────────────────────────────────

    // Once per cover, not once per repaint. The store is what the image
    // provider writes into from its own thread and what the QML side reads.
    void theStoreComputesOnceAndRemembers() {
        CoverColorStore *store = CoverColorStore::instance();
        store->clear();
        const QString id = QStringLiteral("resources.example/one/640x640.jpg");
        QVERIFY(!store->contains(id));
        QVERIFY(!store->lookup(id).isValid());

        QSignalSpy spy(store, &CoverColorStore::recorded);
        store->record(id, solid(QColor(200, 40, 40)));
        QCOMPARE(spy.count(), 1);
        QVERIFY(store->contains(id));
        const QColor first = store->lookup(id);
        QVERIFY(first.isValid());

        // A second cover under the same id is ignored: the colour is a
        // property of the cover, and recomputing it on every reload of the
        // same artwork is the cost this cache exists to avoid.
        store->record(id, solid(QColor(40, 40, 200)));
        QCOMPARE(spy.count(), 1);
        QCOMPARE(store->lookup(id).rgb(), first.rgb());
        store->clear();
    }

    void theStoreForgetsItsOldestEntries() {
        CoverColorStore *store = CoverColorStore::instance();
        store->clear();
        const QString oldest = QStringLiteral("cover-0");
        for (int i = 0; i < CoverColorStore::maxEntries + 8; ++i)
            store->put(QStringLiteral("cover-%1").arg(i), QColor(i % 256, 90, 90));
        QVERIFY2(!store->contains(oldest), "the cache grew without bound");
        QVERIFY(store->contains(QStringLiteral("cover-%1")
                                    .arg(CoverColorStore::maxEntries + 7)));
        store->clear();
    }

    // ── the QML-facing object ───────────────────────────────────────────

    // CoverTint is what qml/pages/NowPlayingPage.qml binds the gradient's top
    // stop to. Inactive it must report nothing at all, so the page falls back
    // to Theme.accentSoft and the docked page paints exactly what it painted
    // before this feature existed.
    void anInactiveTintReportsNothing() {
        const QVariantMap p = theme::palette(QStringLiteral("sea"), false, false);
        CoverColorStore::instance()->clear();
        const QString id = QStringLiteral("resources.example/inactive/640.jpg");
        CoverColorStore::instance()->put(id, QColor(220, 40, 40));

        CoverTint tint;
        tint.setBg(p.value("bg").value<QColor>());
        tint.setLimit(p.value("surfaceHigh").value<QColor>());
        tint.setCoverId(id);

        tint.setActive(false);
        QVERIFY(!tint.hasColor());
        tint.setActive(true);
        QVERIFY(tint.hasColor());
        CoverColorStore::instance()->clear();
    }

    // The cover is downloaded on a loader thread, so the colour usually lands
    // after the page has already asked for it. The object has to pick it up.
    void aTintPicksUpAColourThatArrivesLate() {
        const QVariantMap p = theme::palette(QStringLiteral("sea"), false, false);
        CoverColorStore::instance()->clear();

        CoverTint tint;
        tint.setActive(true);
        tint.setBg(p.value("bg").value<QColor>());
        tint.setLimit(p.value("surfaceHigh").value<QColor>());

        const QString id = QStringLiteral("resources.example/late/640.jpg");
        tint.setCoverId(id);
        QVERIFY2(!tint.hasColor(), "reported a colour for a cover nobody has loaded");

        QSignalSpy spy(&tint, &CoverTint::colorChanged);
        CoverColorStore::instance()->record(id, solid(QColor(230, 30, 30)));
        QVERIFY(spy.count() >= 1);
        QVERIFY(tint.hasColor());
        QVERIFY2(hueGap(hueDeg(tint.color()), 0.0) <= 8.0,
                 qPrintable(QStringLiteral("hue %1").arg(hueDeg(tint.color()), 0, 'f', 1)));
        // ...and it arrives already clamped.
        const double hi = toLab(p.value("surfaceHigh").value<QColor>()).l;
        QVERIFY2(toLab(tint.color()).l <= hi + 1e-6,
                 qPrintable(QStringLiteral("L* %1 over a ceiling of %2")
                                .arg(toLab(tint.color()).l, 0, 'f', 2).arg(hi, 0, 'f', 2)));
        CoverColorStore::instance()->clear();
    }

    // Switching theme re-clamps what is already cached, rather than leaving a
    // tint that was legal on the old palette painted over the new one.
    void aThemeChangeReclampsTheSameCover() {
        CoverColorStore::instance()->clear();
        const QString id = QStringLiteral("resources.example/theme/640.jpg");
        CoverColorStore::instance()->put(id, QColor(255, 0, 0));

        const QVariantMap dark  = theme::palette(QStringLiteral("sea"), false, false);
        const QVariantMap light = theme::palette(QStringLiteral("sky"), false, false);

        CoverTint tint;
        tint.setActive(true);
        tint.setCoverId(id);
        tint.setBg(dark.value("bg").value<QColor>());
        tint.setLimit(dark.value("surfaceHigh").value<QColor>());
        const QColor onDark = tint.color();

        tint.setBg(light.value("bg").value<QColor>());
        tint.setLimit(light.value("surfaceHigh").value<QColor>());
        const QColor onLight = tint.color();

        QVERIFY(onDark.isValid() && onLight.isValid());
        QVERIFY2(toLab(onLight).l > toLab(onDark).l + 40.0,
                 qPrintable(QStringLiteral("dark L* %1, light L* %2 - the tint did not "
                                           "follow the palette")
                                .arg(toLab(onDark).l, 0, 'f', 1)
                                .arg(toLab(onLight).l, 0, 'f', 1)));
        CoverColorStore::instance()->clear();
    }

    void anEmptyCoverIdReportsNothing() {
        const QVariantMap p = theme::palette(QStringLiteral("sea"), false, false);
        CoverTint tint;
        tint.setActive(true);
        tint.setBg(p.value("bg").value<QColor>());
        tint.setLimit(p.value("surfaceHigh").value<QColor>());
        tint.setCoverId(QString());
        QVERIFY(!tint.hasColor());
        QVERIFY(!tint.color().isValid());
    }

private:
    // Every palette, both switches - the same sixteen rows tst_theme.cpp runs.
    static void themeRows() {
        QTest::addColumn<QString>("theme");
        QTest::addColumn<bool>("oled");
        QTest::addColumn<bool>("tinted");
        for (const auto &t : theme::themes()) {
            for (const bool tinted : {false, true}) {
                const QString ramp = tinted ? QStringLiteral(" tinted")
                                            : QStringLiteral(" neutral");
                QTest::newRow(qPrintable(t.name + ramp)) << t.name << false << tinted;
                if (t.dark)
                    QTest::newRow(qPrintable(t.name + " in black" + ramp))
                        << t.name << true << tinted;
            }
        }
    }

    // ...crossed with the sleeves. Sixteen configurations times seven covers
    // is 112 rows, which is the whole point: the clamp has to hold for any
    // artwork on any palette, and a sampled pair proves nothing.
    static void coverRows() {
        QTest::addColumn<QString>("theme");
        QTest::addColumn<bool>("oled");
        QTest::addColumn<bool>("tinted");
        QTest::addColumn<QImage>("cover");

        struct Sleeve { const char *name; QImage image; };
        const QList<Sleeve> sleeves = {
            { "white",     solid(Qt::white) },
            { "black",     solid(Qt::black) },
            { "neon green", solid(QColor(57, 255, 20)) },
            { "pure red",  solid(QColor(255, 0, 0)) },
            { "pure blue", solid(QColor(0, 0, 255)) },
            { "half and half", split(QColor(255, 0, 0), QColor(0, 0, 255), 0.5) },
            { "greyscale photo", greyscalePhoto() },
        };

        for (const auto &t : theme::themes()) {
            for (const bool tinted : {false, true}) {
                for (const bool oled : {false, true}) {
                    if (oled && !t.dark) continue;
                    for (const Sleeve &s : sleeves) {
                        const QString row = t.name + (oled ? QStringLiteral(" black")
                                                           : QString())
                                          + (tinted ? QStringLiteral(" tinted")
                                                    : QStringLiteral(" neutral"))
                                          + QStringLiteral(" / ")
                                          + QLatin1String(s.name);
                        QTest::newRow(qPrintable(row))
                            << t.name << oled << tinted << s.image;
                    }
                }
            }
        }
    }
};

QTEST_GUILESS_MAIN(TestCoverColor)
#include "tst_covercolor.moc"
