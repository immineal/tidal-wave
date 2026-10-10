// Palette tests. The thresholds are WCAG contrast ratios against the surface a
// token is drawn on, so a palette edit that breaks legibility fails here.
// themeRows() crosses the two switches, pure black and tinted greys, so every
// threshold is measured on each ramp, as written and in black. What each switch
// may touch is pinned on its own, and the two must compose in either order.

#include <QTest>
#include <QColor>
#include <QHash>
#include <QSet>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QVariantMap>

#include "ui/Prefs.h"
#include "ui/ThemePalette.h"

namespace {

// WCAG 2.1 relative luminance.
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

// What a translucent wash actually looks like once it is painted. Qt blends in
// 8-bit sRGB, so this matches what a screenshot samples.
QColor composite(const QColor &wash, const QColor &ground) {
    const double a = wash.alphaF();
    return QColor::fromRgbF(wash.redF()   * a + ground.redF()   * (1.0 - a),
                            wash.greenF() * a + ground.greenF() * (1.0 - a),
                            wash.blueF()  * a + ground.blueF()  * (1.0 - a));
}

// CIE L*a*b* and the Euclidean distance in it (dE76). Contrast cannot say
// whether two colours look the same: two palettes can sit at the same
// luminance and differ only in hue. About 2.3 is the smallest visible step.
struct Lab { double l, a, b; };

Lab toLab(const QColor &c) {
    auto lin = [](double v) {
        return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
    };
    const double r = lin(c.redF()), g = lin(c.greenF()), b = lin(c.blueF());
    // sRGB -> XYZ (D65), then normalised by the D65 white point.
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

// Every key a palette must carry. Theme.qml surfaces exactly these, so a token
// added to one theme and forgotten in another fails here.
const QStringList kColourTokens = {
    // grounds
    "bg", "surface", "surfaceHigh", "surfaceHov", "border",
    // type
    "textPrimary", "textSec", "textDim",
    // accent and the tints derived from it
    "accent", "accentDim", "accentInk", "accentSoft", "accentTint", "accentWash",
    // interaction
    "hoverFill",
    // semantic
    "red", "redSoft", "redInk", "green", "greenWash",
    // things drawn over arbitrary cover art, which is neither light nor dark
    "scrim", "artScrim", "artScrimStrong", "artInk", "artBorder",
};

} // namespace

class TestTheme : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never touch the user's real settings file.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_theme"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // ── the set of themes ────────────────────────────────────────────────

    void sixThemes_threeDarkThreeLight() {
        const auto all = theme::themes();
        QCOMPARE(all.size(), 6);

        int dark = 0, light = 0;
        for (const auto &t : all) (t.dark ? dark : light)++;
        QCOMPARE(dark, 3);
        QCOMPARE(light, 3);
    }

    // Settings draws the two halves as columns side by side and relies on the
    // table order to pair them by hue: Sea beside Sky, Pine beside Sand, Rust
    // beside Clay.
    void darkThenLight_pairedByPosition() {
        const auto all = theme::themes();
        QCOMPARE(all.size(), 6);
        for (int i = 0; i < 3; ++i)
            QVERIFY2(all.at(i).dark, qPrintable(all.at(i).name + " is not in the dark half"));
        for (int i = 3; i < 6; ++i)
            QVERIFY2(!all.at(i).dark, qPrintable(all.at(i).name + " is not in the light half"));

        const QStringList expected{"sea", "pine", "rust", "sky", "sand", "clay"};
        QStringList actual;
        for (const auto &t : all) actual << t.name;
        QCOMPARE(actual, expected);
    }

    // The accent is what makes a row read as one colour family, so the two
    // halves of each row have to agree about hue, loosely.
    void eachRowIsOneHue_data() {
        QTest::addColumn<QString>("darkName");
        QTest::addColumn<QString>("lightName");
        QTest::newRow("blue")  << "sea"  << "sky";
        QTest::newRow("green") << "pine" << "sand";
        QTest::newRow("amber") << "rust" << "clay";
    }

    void eachRowIsOneHue() {
        QFETCH(QString, darkName);
        QFETCH(QString, lightName);
        const QColor a = theme::palette(darkName).value("accent").value<QColor>();
        const QColor b = theme::palette(lightName).value("accent").value<QColor>();
        // Degrees around the wheel, the short way.
        int gap = qAbs(a.hue() - b.hue());
        if (gap > 180) gap = 360 - gap;
        QVERIFY2(gap <= 30, qPrintable(
            darkName + " (" + QString::number(a.hue()) + " deg) and " + lightName
            + " (" + QString::number(b.hue()) + " deg) are not the same colour family"));
    }

    void namesAreUniqueAndLabelled() {
        QSet<QString> names, labels;
        for (const auto &t : theme::themes()) {
            QVERIFY2(!t.name.isEmpty(), "a theme has no name");
            QVERIFY2(!t.label.isEmpty(), qPrintable(t.name + " has no label"));
            // The name is a settings key: lowercase ASCII, no spaces.
            QCOMPARE(t.name, t.name.toLower());
            QVERIFY(!t.name.contains(QLatin1Char(' ')));
            QVERIFY2(!names.contains(t.name), qPrintable("duplicate name " + t.name));
            QVERIFY2(!labels.contains(t.label), qPrintable("duplicate label " + t.label));
            names.insert(t.name);
            labels.insert(t.label);
        }
    }

    void defaultThemeIsOneOfThem() {
        QSet<QString> names;
        for (const auto &t : theme::themes()) names.insert(t.name);
        QVERIFY(names.contains(theme::defaultTheme()));
        // Which one is a design decision, so it is written down here.
        QCOMPARE(theme::defaultTheme(), QStringLiteral("sea"));
        QCOMPARE(theme::defaultOledBlack(), true);
        QCOMPARE(theme::defaultTintedGreys(), true);
        // Pure black does nothing on a light theme, so the default must be dark.
        for (const auto &t : theme::themes())
            if (t.name == theme::defaultTheme()) QVERIFY(t.dark);
    }

    // "deep" is a retired palette name. A settings file that stores it selects
    // Sea in pure black.
    void deepMigratesToSeaInBlack() {
        QString name;
        bool    oled = false;
        QVERIFY(theme::migrated(QStringLiteral("deep"), &name, &oled));
        QCOMPARE(name, QStringLiteral("sea"));
        QCOMPARE(oled, true);
        QVERIFY(!theme::isKnown(QStringLiteral("deep")));

        // Deep was the neutral ramp pulled to black.
        const QVariantMap deep = theme::palette(name, oled, false);
        QCOMPARE(deep.value("bg").value<QColor>(), QColor(Qt::black));
        QCOMPARE(deep.value("surface").value<QColor>(), QColor(0x0c, 0x0c, 0x0c));

        // No current name is migrated away from.
        for (const auto &t : theme::themes())
            QVERIFY2(!theme::migrated(t.name, nullptr, nullptr),
                     qPrintable(t.name + " is being migrated away from"));
        QVERIFY(!theme::migrated(QStringLiteral("graphite"), nullptr, nullptr));
        QVERIFY(!theme::migrated(QString(), nullptr, nullptr));
    }

    // The six palettes carried other names in older settings files. Each old
    // name must select its replacement.
    void aStoredOldNameSelectsTheRenamedPalette_data() {
        QTest::addColumn<QString>("stored");
        QTest::addColumn<QString>("renamed");
        QTest::newRow("midnight") << "midnight" << "sea";
        QTest::newRow("forest")   << "forest"   << "pine";
        QTest::newRow("ember")    << "ember"    << "rust";
        QTest::newRow("daylight") << "daylight" << "sky";
        QTest::newRow("paper")    << "paper"    << "sand";
        QTest::newRow("dawn")     << "dawn"     << "clay";
    }

    void aStoredOldNameSelectsTheRenamedPalette() {
        QFETCH(QString, stored);
        QFETCH(QString, renamed);
        QVERIFY(theme::isKnown(renamed));
        QVERIFY2(!theme::isKnown(stored), "an old name is still in kSpecs");

        // A rename moves no pixels, so the pure-black switch comes back out as
        // it was stored. Only "deep" above may touch it.
        for (bool oled : {false, true}) {
            QString name;
            bool    got = oled;
            QVERIFY(theme::migrated(stored, &name, &got));
            QCOMPARE(name, renamed);
            QCOMPARE(got, oled);
        }

        // The same through a settings file: Prefs migrates on load.
        {
            QSettings s;
            s.setValue(QStringLiteral("ui/theme"), stored);
            s.setValue(QStringLiteral("ui/oledBlack"), false);
        }
        {
            Prefs prefs;
            ThemePalette palette(&prefs);
            QCOMPARE(prefs.theme(), renamed);
            QCOMPARE(palette.current(),
                     theme::palette(renamed, false, prefs.tintedGreys()));
        }
        // Scoped, and cleared only once Prefs is gone: its own QSettings holds
        // the values it wrote and would put them back on the way out.
        { QSettings s; s.clear(); s.sync(); }
    }

    // A name on neither list is left in the file as written, as a settings
    // file from a newer build would carry it, and the lookup falls back to the
    // default palette.
    void aStoredUnknownNameIsLeftAloneAndFallsBack() {
        QVERIFY(!theme::migrated(QStringLiteral("graphite"), nullptr, nullptr));
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "graphite"); }
        {
            Prefs prefs;
            ThemePalette palette(&prefs);
            QCOMPARE(prefs.theme(), QStringLiteral("graphite"));
            QCOMPARE(palette.current(),
                     theme::palette(theme::defaultTheme(), prefs.oledBlack(),
                                    prefs.tintedGreys()));
        }
        { QSettings s; s.clear(); s.sync(); }
    }

    // Prefs takes its default theme from the table, so it must resolve there.
    void prefsDefaultResolves() {
        Prefs prefs;
        QVERIFY(theme::isKnown(prefs.theme()));
    }

    // ── each palette is complete ─────────────────────────────────────────

    void everyPaletteHasEveryToken_data() { themeRows(); }
    void everyPaletteHasEveryToken() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);

        for (const QString &key : kColourTokens) {
            QVERIFY2(p.contains(key), qPrintable(name + " is missing " + key));
            const QColor c = p.value(key).value<QColor>();
            QVERIFY2(c.isValid(), qPrintable(name + "." + key + " is not a colour"));
        }
        // No stray keys: a typo'd token name would otherwise sit unused while
        // the binding that wants it reads undefined.
        for (auto it = p.cbegin(); it != p.cend(); ++it) {
            if (it.key() == QLatin1String("dark")) continue;
            QVERIFY2(kColourTokens.contains(it.key()),
                     qPrintable(name + " has an unknown token " + it.key()));
        }
    }

    // QML parses a property named on<Name> declared beside a property <name> as
    // a signal handler, so such a token would never evaluate as a binding.
    void noTokenLooksLikeASignalHandler() {
        for (const QString &key : kColourTokens) {
            const bool trap = key.size() > 2
                           && key.startsWith(QLatin1String("on"))
                           && key.at(2).isUpper();
            QVERIFY2(!trap, qPrintable(
                "token \"" + key + "\" reads as a QML signal handler for a "
                "signal named \"" + key.mid(2).toLower() + "\"; rename it"));
        }
    }

    void darkFlagMatchesTheGround_data() { themeRows(); }
    void darkFlagMatchesTheGround() {
        QFETCH(QString, name);
        QFETCH(bool, dark);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QColor bg = theme::palette(name, oled, tinted).value("bg").value<QColor>();
        QCOMPARE(luminance(bg) < 0.5, dark);
    }

    // ── legibility ───────────────────────────────────────────────────────

    void textIsLegible_data() { themeRows(); }
    void textIsLegible() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        // Text is drawn on bg, on surface and on surfaceHigh (cards), so all
        // three grounds have to hold up.
        for (const char *ground : {"bg", "surface", "surfaceHigh"}) {
            const QColor g = col(ground);
            const QString where = name + " on " + QLatin1String(ground);

            QVERIFY2(contrast(col("textPrimary"), g) >= 7.0,
                     qPrintable(where + ": textPrimary below AAA ("
                                + QString::number(contrast(col("textPrimary"), g), 'f', 2) + ")"));
            QVERIFY2(contrast(col("textSec"), g) >= 4.5,
                     qPrintable(where + ": textSec below AA ("
                                + QString::number(contrast(col("textSec"), g), 'f', 2) + ")"));
            // textDim is quiet but carries real text: track numbers, durations,
            // "Playing from" and the Settings section headings. AA-large.
            QVERIFY2(contrast(col("textDim"), g) >= 3.0,
                     qPrintable(where + ": textDim below AA-large ("
                                + QString::number(contrast(col("textDim"), g), 'f', 2) + ")"));
            // ...and still clearly quieter than textSec, or there is no point in
            // having both.
            QVERIFY2(contrast(col("textSec"), g) >= 1.5 * contrast(col("textDim"), g),
                     qPrintable(where + ": textDim is not quieter than textSec ("
                                + QString::number(contrast(col("textDim"), g), 'f', 2) + " vs "
                                + QString::number(contrast(col("textSec"), g), 'f', 2) + ")"));
            // The accent is used for icons and small bold labels: the active nav
            // row, an artist link, the title of the playing row.
            QVERIFY2(contrast(col("accent"), g) >= 3.0,
                     qPrintable(where + ": accent below AA-large ("
                                + QString::number(contrast(col("accent"), g), 'f', 2) + ")"));
        }

        // Text on a solid accent fill (PillButton, the play button, the
        // Collection filter pills). The threshold is AA because a filter pill's
        // count is small text.
        QVERIFY2(contrast(col("accentInk"), col("accent")) >= 4.5,
                 qPrintable(name + ": accentInk on accent is "
                            + QString::number(contrast(col("accentInk"), col("accent")), 'f', 2)));

        // Error text has to be readable too.
        QVERIFY2(contrast(col("red"), col("surface")) >= 3.0, qPrintable(name + ": red too dim"));
        // ...and the label on a solid red fill (the danger buttons in Settings
        // fill with red on hover).
        QVERIFY2(contrast(col("redInk"), col("red")) >= 4.5,
                 qPrintable(name + ": redInk on red is "
                            + QString::number(contrast(col("redInk"), col("red")), 'f', 2)));
    }

    // The ratio above would also pass with near-black ink on a bright accent.
    // The ink on a fill is white in all six themes.
    void inkOnAFillIsWhite_data() { themeRows(); }
    void inkOnAFillIsWhite() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        for (const char *k : {"accentInk", "redInk"}) {
            const QColor ink = p.value(QLatin1String(k)).value<QColor>();
            QVERIFY2(contrast(ink, QColor(Qt::white)) <= 1.1,
                     qPrintable(name + "." + QLatin1String(k) + " is "
                                + ink.name() + ", which does not read as white"));
        }
    }

    void structureIsVisible_data() { themeRows(); }
    void structureIsVisible() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        // A border that matches its surface is not a border.
        QVERIFY2(contrast(col("border"), col("surface")) >= 1.12,
                 qPrintable(name + ": border invisible against surface"));

        // The elevation ramp has to ramp by enough to see. 1.06 is just under
        // the tightest step any palette here takes.
        const char *ladder[][2] = {{"bg", "surface"},
                                   {"surface", "surfaceHigh"},
                                   {"surfaceHigh", "surfaceHov"}};
        for (const auto &step : ladder) {
            const double c = contrast(col(step[0]), col(step[1]));
            QVERIFY2(c >= 1.06, qPrintable(
                name + ": " + QLatin1String(step[0]) + " and " + QLatin1String(step[1])
                + " are the same slab (" + QString::number(c, 'f', 3) + ")"));
        }

        const bool dark = p.value("dark").toBool();
        // Raised surfaces move away from the ground, in whichever direction
        // "away" is for this theme.
        if (dark) {
            QVERIFY(luminance(col("surface")) >= luminance(col("bg")));
            QVERIFY(luminance(col("surfaceHigh")) > luminance(col("surface")));
            QVERIFY(luminance(col("surfaceHov")) > luminance(col("surfaceHigh")));
        } else {
            QVERIFY(luminance(col("surface")) <= luminance(col("bg")));
            QVERIFY(luminance(col("surfaceHigh")) < luminance(col("surface")));
            QVERIFY(luminance(col("surfaceHov")) < luminance(col("surfaceHigh")));
        }
    }

    // A hover has to be visible. hoverFill is a wash over sidebar rows, chips
    // and theme tiles; surfaceHov is the opaque one TrackRow and menus use. A
    // wash cannot reach 3:1 without reading as a selected row.
    void hoverIsVisibleButNotASelection_data() { themeRows(); }
    void hoverIsVisibleButNotASelection() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        const QColor hover = col("hoverFill");
        for (const char *ground : {"bg", "surface", "surfaceHigh"}) {
            const QColor g = col(ground);
            const QColor washed = composite(hover, g);
            const QString where = name + " on " + QLatin1String(ground);

            QVERIFY2(contrast(washed, g) >= 1.22,
                     qPrintable(where + ": hoverFill is invisible ("
                                + QString::number(contrast(washed, g), 'f', 3) + ")"));
            // The stronger of the two, drawn opaque, has to be stronger still.
            QVERIFY2(contrast(col("surfaceHov"), g) > contrast(washed, g),
                     qPrintable(where + ": surfaceHov is no stronger than hoverFill"));
        }

        // A hovered track row against the page it sits on.
        QVERIFY2(contrast(col("surfaceHov"), col("bg")) >= 1.5,
                 qPrintable(name + ": a hovered row is invisible against the page ("
                            + QString::number(contrast(col("surfaceHov"), col("bg")), 'f', 3) + ")"));

        // The sidebar draws both on the same ground: hoverFill for the row
        // under the pointer, surfaceHov for the page you are on. If those two
        // converge, hovering looks like navigating.
        const QColor sidebar = col("surface");
        QVERIFY2(contrast(composite(hover, sidebar), col("surfaceHov")) >= 1.12,
                 qPrintable(name + ": hover and the selected row are the same colour ("
                            + QString::number(contrast(composite(hover, sidebar), col("surfaceHov")), 'f', 3)
                            + ")"));
    }

    // A white hover wash disappears on a light ground, so each theme picks its
    // own, and it has to be translucent or it would paint over the row.
    void translucentTokensAreTranslucent_data() { themeRows(); }
    void translucentTokensAreTranslucent() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        for (const char *k : {"hoverFill", "accentSoft", "accentTint", "accentWash",
                              "redSoft", "greenWash", "scrim", "artScrim",
                              "artScrimStrong", "artBorder"}) {
            const QColor c = p.value(QLatin1String(k)).value<QColor>();
            QVERIFY2(c.alphaF() < 1.0, qPrintable(name + "." + QLatin1String(k) + " is opaque"));
            QVERIFY2(c.alphaF() > 0.0, qPrintable(name + "." + QLatin1String(k) + " is invisible"));
        }
        // ...and the accent tints have to read as the accent.
        for (const char *k : {"accentSoft", "accentTint", "accentWash"}) {
            const QColor tint = p.value(QLatin1String(k)).value<QColor>();
            const QColor accent = p.value("accent").value<QColor>();
            QVERIFY2(qAbs(tint.hueF() - accent.hueF()) < 0.1 || accent.saturationF() < 0.1,
                     qPrintable(name + "." + QLatin1String(k) + " is not the accent hue"));
        }
        // The three accent tints get progressively stronger.
        const double soft = p.value("accentSoft").value<QColor>().alphaF();
        const double tint = p.value("accentTint").value<QColor>().alphaF();
        const double wash = p.value("accentWash").value<QColor>().alphaF();
        QVERIFY(soft < tint);
        QVERIFY(tint < wash);
    }

    // The album, mix and playlist heroes are accentTint fading into bg, and
    // the tint has to stay visible against the page.
    void heroGradientStillReads_data() { themeRows(); }
    void heroGradientStillReads() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        QFETCH(bool, tinted);
        const QVariantMap p = theme::palette(name, oled, tinted);
        const QColor bg  = p.value("bg").value<QColor>();
        const QColor top = composite(p.value("accentTint").value<QColor>(), bg);
        QVERIFY2(contrast(top, bg) >= 1.15,
                 qPrintable(name + ": the hero gradient is invisible against the page ("
                            + QString::number(contrast(top, bg), 'f', 3) + ")"));
    }

    // Things layered over cover art can't depend on the theme: the artwork is
    // whatever it is. Those tokens are shared, so they must be identical.
    void artTokensAreThemeIndependent() {
        const QVariantMap first = theme::palette(theme::themes().first().name);
        for (const auto &t : theme::themes()) {
            // Neither switch may move them either.
            for (const bool tinted : {false, true}) {
                for (const bool oled : {false, true}) {
                    if (oled && !t.dark) continue;
                    const QVariantMap p = theme::palette(t.name, oled, tinted);
                    for (const char *k : {"artScrim", "artScrimStrong", "artInk", "artBorder"}) {
                        QCOMPARE(p.value(QLatin1String(k)).value<QColor>(),
                                 first.value(QLatin1String(k)).value<QColor>());
                    }
                }
            }
        }
    }

    // Every state a user can reach: six themes over two ramps, plus the
    // pure-black variant of each dark one, eighteen distinct palettes.
    void noTwoThemesAreTheSame() {
        QList<QVariantMap> seen;
        QStringList tags;
        for (const auto &t : theme::themes()) {
            for (bool tinted : {false, true}) {
                for (bool oled : {false, true}) {
                    if (oled && !t.dark) continue;
                    const QVariantMap p = theme::palette(t.name, oled, tinted);
                    const QString tag = t.name + (tinted ? " tinted" : " neutral")
                                      + (oled ? " in black" : "");
                    for (int i = 0; i < seen.size(); ++i)
                        QVERIFY2(p != seen.at(i),
                                 qPrintable(tag + " is identical to " + tags.at(i)));
                    seen.append(p);
                    tags.append(tag);
                }
            }
        }
        QCOMPARE(seen.size(), 18);
    }

    // noTwoThemesAreTheSame() compares byte for byte and passes on two palettes
    // nobody can tell apart. The three grounds carry nearly all the page area,
    // so they are compared in Lab. Tinted state only: neutral is one ramp.
    void lightGroundsAreTellableApart() {
        const QStringList grounds = { "bg", "surface", "surfaceHigh" };
        QStringList lights;
        for (const auto &t : theme::themes())
            if (!t.dark) lights << t.name;
        QCOMPARE(lights.size(), 3);

        for (int i = 0; i < lights.size(); ++i)
            for (int j = i + 1; j < lights.size(); ++j)
                for (const QString &g : grounds) {
                    const QColor a = theme::palette(lights.at(i), false, true).value(g).value<QColor>();
                    const QColor b = theme::palette(lights.at(j), false, true).value(g).value<QColor>();
                    const double d = deltaE(a, b);
                    QVERIFY2(d >= 8.0, qPrintable(QStringLiteral(
                        "%1 and %2 are only dE %3 apart at %4 (%5 vs %6); "
                        "under 8 they start reading as the same theme, and "
                        "under 2.3 nobody can see any difference at all")
                        .arg(lights.at(i), lights.at(j), QString::number(d, 'f', 2),
                             g, a.name().toUpper(), b.name().toUpper())));
                }
    }

    // The same for the dark grounds, which lean toward their own accent hue.
    // Tinted state, as above.
    void darkGroundsAreTellableApart() {
        const QStringList grounds = { "bg", "surface", "surfaceHigh" };
        QStringList darks;
        for (const auto &t : theme::themes())
            if (t.dark) darks << t.name;
        QCOMPARE(darks.size(), 3);

        for (int i = 0; i < darks.size(); ++i)
            for (int j = i + 1; j < darks.size(); ++j)
                for (const QString &g : grounds) {
                    const QColor a = theme::palette(darks.at(i), false, true).value(g).value<QColor>();
                    const QColor b = theme::palette(darks.at(j), false, true).value(g).value<QColor>();
                    const double d = deltaE(a, b);
                    QVERIFY2(d >= 8.0, qPrintable(QStringLiteral(
                        "%1 and %2 are only dE %3 apart at %4 (%5 vs %6)")
                        .arg(darks.at(i), darks.at(j), QString::number(d, 'f', 2),
                             g, a.name().toUpper(), b.name().toUpper())));
                }
    }

    // ── the pure-black transform ─────────────────────────────────────────
    // What it is allowed to touch. Legibility is covered above, where every
    // dark theme already runs as written and in black.

    void oledPullsEveryGroundDown_data() { darkThemeRows(); }
    void oledPullsEveryGroundDown() {
        QFETCH(QString, name);
        QFETCH(bool, tinted);
        const QVariantMap plain = theme::palette(name, false, tinted);
        const QVariantMap black = theme::palette(name, true, tinted);
        auto col = [](const QVariantMap &p, const char *k) {
            return p.value(QLatin1String(k)).value<QColor>();
        };

        // The whole point of the switch.
        QCOMPARE(col(black, "bg"), QColor(Qt::black));

        // ...and the rest of the ramp comes with it, or the page would be
        // black with the old grounds floating on top of it.
        for (const char *k : {"surface", "surfaceHigh", "surfaceHov", "border"}) {
            const double was = luminance(col(plain, k));
            const double now = luminance(col(black, k));
            QVERIFY2(now < was, qPrintable(
                name + "." + QLatin1String(k) + " did not come down ("
                + col(plain, k).name() + " -> " + col(black, k).name() + ")"));
        }

        // The tint survives because the channels are scaled, so the hue holds.
        for (const char *k : {"surface", "surfaceHigh", "surfaceHov", "border"}) {
            const QColor a = col(plain, k), b = col(black, k);
            // Nothing to keep in the neutral state, where the ramp is grey on
            // purpose; a grey scaled by a constant is still that grey.
            if (a.saturation() < 12) continue;
            QVERIFY2(qAbs(a.hue() - b.hue()) <= 12, qPrintable(
                name + "." + QLatin1String(k) + " changed hue, " + a.name()
                + " -> " + b.name()));
        }
    }

    // Nothing but the grounds and the hover wash. The type and the accents
    // were tuned against the thresholds above and must not move.
    void oledTouchesNothingButTheGrounds_data() { darkThemeRows(); }
    void oledTouchesNothingButTheGrounds() {
        QFETCH(QString, name);
        QFETCH(bool, tinted);
        const QVariantMap plain = theme::palette(name, false, tinted);
        const QVariantMap black = theme::palette(name, true, tinted);

        const QSet<QString> mayMove = {
            "bg", "surface", "surfaceHigh", "surfaceHov", "border", "hoverFill"
        };
        QCOMPARE(plain.keys(), black.keys());
        for (auto it = plain.cbegin(); it != plain.cend(); ++it) {
            if (mayMove.contains(it.key())) continue;
            QVERIFY2(black.value(it.key()) == it.value(),
                     qPrintable(name + ": the black variant moved " + it.key()));
        }
        // A 10% white wash vanishes over a true-black page, so the hover
        // treatment is the one non-ground that has to follow.
        const QColor was = plain.value("hoverFill").value<QColor>();
        const QColor now = black.value("hoverFill").value<QColor>();
        QVERIFY2(now.alpha() > was.alpha(),
                 qPrintable(name + ": the hover wash did not keep up with the ground"));
    }

    // The picker hides the switch on a light theme, and asking for a black
    // light palette must change nothing.
    void oledIsANoOpOnALightTheme_data() { lightThemeRows(); }
    void oledIsANoOpOnALightTheme() {
        QFETCH(QString, name);
        QFETCH(bool, tinted);
        QCOMPARE(theme::palette(name, true, tinted),
                 theme::palette(name, false, tinted));
    }

    // An unknown stored name still has to paint, with the switch either way.
    void oledSurvivesAnUnknownName() {
        for (const bool tinted : {false, true}) {
            const QVariantMap fallback = theme::palette(theme::defaultTheme(), true, tinted);
            QCOMPARE(theme::palette(QStringLiteral("no-such-theme"), true, tinted), fallback);
            QCOMPARE(theme::palette(QString(), true, tinted), fallback);
            QVERIFY(fallback.value("bg").value<QColor>() == QColor(Qt::black));
        }
    }

    // ── the neutral grey ramp ────────────────────────────────────────────
    // With tinting off, the six palettes share one grey ramp per mode and
    // differ only by their accent. The assertions above would still pass if one
    // theme kept a tint, so the shape is pinned here.

    void theNeutralRampsAreActuallyNeutral() {
        for (const auto &t : theme::themes()) {
            for (const bool oled : {false, true}) {
                if (oled && !t.dark) continue;
                const QVariantMap p = theme::palette(t.name, oled, false);
                // Every ground and every type colour is a true grey, in black
                // as well: scaling a grey by a constant leaves a grey.
                for (const char *k : {"bg", "surface", "surfaceHigh", "surfaceHov", "border",
                                      "textPrimary", "textSec", "textDim"}) {
                    const QColor c = p.value(QLatin1String(k)).value<QColor>();
                    QVERIFY2(c.red() == c.green() && c.green() == c.blue(), qPrintable(
                        t.name + (oled ? " in black." : ".") + QLatin1String(k) + " is "
                        + c.name() + ", which is not a grey"));
                }
            }
        }
    }

    // The two ramps are design decisions, so their values are written down.
    void theNeutralRampsAreTheOnesSignedOff() {
        const QVariantMap dark = theme::palette(QStringLiteral("sea"), false, false);
        const QStringList grounds = {"bg", "surface", "surfaceHigh", "surfaceHov", "border"};
        const QStringList type    = {"textPrimary", "textSec", "textDim"};

        // With the pure-black switch on, this ramp is byte for byte the retired
        // "Deep" palette, which deepMigratesToSeaInBlack() relies on.
        const QStringList darkRamp = {"#0a0a0a", "#141414", "#1e1e1e", "#383838", "#2a2a2a"};
        const QStringList darkType = {"#ffffff", "#a0a0a0", "#6b6b6b"};
        for (int i = 0; i < grounds.size(); ++i)
            QCOMPARE(dark.value(grounds.at(i)).value<QColor>().name(), darkRamp.at(i));
        for (int i = 0; i < type.size(); ++i)
            QCOMPARE(dark.value(type.at(i)).value<QColor>().name(), darkType.at(i));

        // The light ramp is derived: true greys at the same L* as Sky's tinted
        // ramp, which is the lightness the light palettes' contrast was tuned
        // on.
        const QVariantMap light  = theme::palette(QStringLiteral("sky"), false, false);
        const QVariantMap tinted = theme::palette(QStringLiteral("sky"), false, true);
        for (const QString &k : grounds + type) {
            const double was = toLab(tinted.value(k).value<QColor>()).l;
            const double now = toLab(light.value(k).value<QColor>()).l;
            QVERIFY2(qAbs(was - now) <= 0.5, qPrintable(QStringLiteral(
                "the neutral light %1 sits at L* %2 where Sky's is %3; that ramp "
                "is meant to be Sky's lightness with the blue taken out")
                .arg(k, QString::number(now, 'f', 2), QString::number(was, 'f', 2))));
        }
    }

    // Within a mode the six are one palette with six accents.
    void neutralIsOneRampPerMode_data() {
        QTest::addColumn<bool>("dark");
        QTest::newRow("dark")  << true;
        QTest::newRow("light") << false;
    }

    void neutralIsOneRampPerMode() {
        QFETCH(bool, dark);
        QStringList names;
        for (const auto &t : theme::themes())
            if (t.dark == dark) names << t.name;
        QCOMPARE(names.size(), 3);

        const QVariantMap first = theme::palette(names.first(), false, false);
        for (const QString &n : names) {
            const QVariantMap p = theme::palette(n, false, false);
            for (const char *k : {"bg", "surface", "surfaceHigh", "surfaceHov", "border",
                                  "textPrimary", "textSec", "textDim", "hoverFill"}) {
                const QString key = QLatin1String(k);
                QVERIFY2(p.value(key) == first.value(key), qPrintable(
                    n + "." + key + " is " + p.value(key).value<QColor>().name()
                    + " where " + names.first() + " has "
                    + first.value(key).value<QColor>().name()
                    + "; in the neutral state the ramp is shared"));
            }
        }
    }

    // ...and the accent is then the only thing left to choose between, so it
    // has to differ.
    void neutralDiffersOnlyByTheAccent_data() { neutralIsOneRampPerMode_data(); }
    void neutralDiffersOnlyByTheAccent() {
        QFETCH(bool, dark);
        QStringList names;
        for (const auto &t : theme::themes())
            if (t.dark == dark) names << t.name;

        // Everything a palette carries that is neither a ground nor type.
        const QSet<QString> mayDiffer = {
            "accent", "accentDim", "accentInk", "accentSoft", "accentTint", "accentWash",
            "red", "redSoft", "redInk", "green", "greenWash"
        };
        for (int i = 0; i < names.size(); ++i) {
            for (int j = i + 1; j < names.size(); ++j) {
                const QVariantMap a = theme::palette(names.at(i), false, false);
                const QVariantMap b = theme::palette(names.at(j), false, false);
                QCOMPARE(a.keys(), b.keys());
                QVERIFY2(a.value("accent") != b.value("accent"), qPrintable(
                    names.at(i) + " and " + names.at(j)
                    + " are the same palette in the neutral state"));
                for (auto it = a.cbegin(); it != a.cend(); ++it) {
                    if (it.value() == b.value(it.key())) continue;
                    QVERIFY2(mayDiffer.contains(it.key()), qPrintable(
                        names.at(i) + " and " + names.at(j) + " differ at " + it.key()
                        + ", which is neither an accent nor a semantic colour"));
                }
            }
        }
    }

    // ── the colour switch ────────────────────────────────────────────────
    // What flipping it is allowed to move. Legibility is covered above, where
    // every threshold runs over both ramps.

    void tintingTouchesNothingButTheGroundsAndTheType_data() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("oled");
        for (const auto &t : theme::themes()) {
            QTest::newRow(qPrintable(t.name)) << t.name << false;
            if (t.dark) QTest::newRow(qPrintable(t.name + " in black")) << t.name << true;
        }
    }

    void tintingTouchesNothingButTheGroundsAndTheType() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap neutral = theme::palette(name, oled, false);
        const QVariantMap tinted  = theme::palette(name, oled, true);

        // The switch must not touch the accent, the semantic colours, the hover
        // wash or the tokens drawn over cover art.
        const QSet<QString> mayMove = {
            "bg", "surface", "surfaceHigh", "surfaceHov", "border",
            "textPrimary", "textSec", "textDim"
        };
        QCOMPARE(neutral.keys(), tinted.keys());
        for (auto it = neutral.cbegin(); it != neutral.cend(); ++it) {
            if (mayMove.contains(it.key())) continue;
            QVERIFY2(tinted.value(it.key()) == it.value(),
                     qPrintable(name + ": the colour switch moved " + it.key()));
        }

        // ...and it is never a no-op. Not measured at bg alone: with the
        // pure-black switch on, both ramps are black there.
        bool moved = false;
        for (const QString &k : mayMove)
            if (neutral.value(k) != tinted.value(k)) moved = true;
        QVERIFY2(moved, qPrintable(name + ": the colour switch paints nothing"));
    }

    // The pure-black switch scales whatever ramp the colour switch chose, so
    // the implementation has an order. The palette must depend only on the two
    // settings, and it is driven through Prefs to cover the notify wiring.
    void theTwoSwitchesComposeInEitherOrder_data() { darkNameRows(); }
    void theTwoSwitchesComposeInEitherOrder() {
        QFETCH(QString, name);

        auto flip = [&](bool blackFirst, QVariantMap *out) {
            Prefs prefs;
            prefs.setTheme(name);
            prefs.setOledBlack(false);
            prefs.setTintedGreys(false);
            ThemePalette palette(&prefs);
            QCOMPARE(palette.current(), theme::palette(name, false, false));

            if (blackFirst) { prefs.setOledBlack(true);   prefs.setTintedGreys(true); }
            else            { prefs.setTintedGreys(true); prefs.setOledBlack(true);   }
            *out = palette.current();

            // ...and all the way back out again, the other way round each time.
            if (blackFirst) { prefs.setTintedGreys(false); prefs.setOledBlack(false);  }
            else            { prefs.setOledBlack(false);   prefs.setTintedGreys(false); }
            QCOMPARE(palette.current(), theme::palette(name, false, false));
        };

        QVariantMap blackFirst, tintFirst;
        flip(true,  &blackFirst);
        flip(false, &tintFirst);
        QCOMPARE(blackFirst, tintFirst);
        QCOMPARE(blackFirst, theme::palette(name, true, true));

        // The state the pure-black switch exists for, over either ramp.
        QCOMPARE(blackFirst.value("bg").value<QColor>(), QColor(Qt::black));
        QCOMPARE(theme::palette(name, true, false).value("bg").value<QColor>(),
                 QColor(Qt::black));

        { QSettings s; s.clear(); s.sync(); }
    }

    // The picker draws its swatches from available(), which has to answer for
    // the state the app is in. In the neutral state all six show the same two
    // grounds and six different accents.
    void availableFollowsTheColourSwitch() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("sea"));
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette palette(&prefs);

        auto swatches = [&] {
            QHash<QString, QVariantMap> out;
            const QVariantList rows = palette.available();
            for (const QVariant &v : rows)
                out.insert(v.toMap().value("name").toString(), v.toMap());
            return out;
        };

        for (const bool tinted : {false, true}) {
            prefs.setTintedGreys(tinted);
            const auto rows = swatches();
            QCOMPARE(rows.size(), theme::themes().size());
            for (const auto &t : theme::themes()) {
                const QVariantMap p = theme::palette(t.name, false, tinted);
                for (const char *k : {"bg", "border", "accent"}) {
                    QVERIFY2(rows.value(t.name).value(QLatin1String(k))
                                 .value<QColor>() == p.value(QLatin1String(k)).value<QColor>(),
                             qPrintable(t.name + "'s swatch " + QLatin1String(k)
                                        + " is not the one the palette has"));
                }
            }
        }

        // Spelled out: neutral is one ground for the three darks, tinted is three.
        prefs.setTintedGreys(false);
        auto rows = swatches();
        QCOMPARE(rows.value("sea").value("bg"), rows.value("pine").value("bg"));
        QVERIFY(rows.value("sea").value("accent") != rows.value("pine").value("accent"));
        prefs.setTintedGreys(true);
        rows = swatches();
        QVERIFY2(rows.value("sea").value("bg") != rows.value("pine").value("bg"),
                 "the grid did not follow the colour switch");

        { QSettings s; s.clear(); s.sync(); }
    }

    // ── lookup behaviour ─────────────────────────────────────────────────

    void unknownNameFallsBackToTheDefault() {
        for (const bool tinted : {false, true}) {
            const QVariantMap fallback = theme::palette(theme::defaultTheme(), false, tinted);
            QCOMPARE(theme::palette(QStringLiteral("no-such-theme"), false, tinted), fallback);
            QCOMPARE(theme::palette(QString(), false, tinted), fallback);
        }
        QVERIFY(!theme::isKnown(QStringLiteral("no-such-theme")));
    }

    // ── the radius scale ─────────────────────────────────────────────────
    // The scale is a design decision, so drifting off it fails here.
    void radiusScale() {
        const QVariantMap r = theme::radii();
        QCOMPARE(r.value("chip").toInt(), 999);
        QCOMPARE(r.value("field").toInt(), 14);
        QCOMPARE(r.value("row").toInt(), 7);
        QCOMPARE(r.value("button").toInt(), 8);
        QCOMPARE(r.value("art").toInt(), 5);
        QCOMPARE(r.value("card").toInt(), 11);
        QCOMPARE(r.value("popup").toInt(), 14);
        QCOMPARE(r.value("badge").toInt(), 4);
        QCOMPARE(r.value("mark").toInt(), 14);
        QCOMPARE(r.size(), 9);
    }

    // ── the QML-facing object ────────────────────────────────────────────

    // Qt picks a QML_SINGLETON's construction path by checking
    // std::is_default_constructible before it looks for create(). A default
    // constructor would give QML its own instance with a null Prefs.
    void singletonIsNotDefaultConstructible() {
        static_assert(!std::is_default_constructible_v<ThemePalette>,
                      "ThemePalette must not be default-constructible, or Qt "
                      "ignores create() and QML gets an instance with no Prefs");
        QVERIFY(!std::is_default_constructible_v<ThemePalette>);
    }

    // create() is what the QML engine calls. It has to hand back the object
    // Application wired Prefs into.
    void createReturnsTheWiredInstance() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("rust"));
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette::instance()->setPrefs(&prefs);

        ThemePalette *fromQml = ThemePalette::create(nullptr, nullptr);
        QCOMPARE(fromQml, ThemePalette::instance());
        QCOMPARE(fromQml->current(), theme::palette(QStringLiteral("rust")));

        // ...and it keeps following Prefs through that same pointer.
        prefs.setTheme(QStringLiteral("sky"));
        QCOMPARE(fromQml->current(), theme::palette(QStringLiteral("sky")));
        QVERIFY(!fromQml->isDark());
    }

    void currentFollowsPrefs() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("sea"));
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette palette(&prefs);

        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sea")));
        QVERIFY(palette.isDark());

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setTheme(QStringLiteral("sky"));

        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sky")));
        QVERIFY(!palette.isDark());
    }

    // The switch arrives through the same object the theme does, so no binding
    // in the app has to know about it.
    void currentFollowsOledBlack() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("pine"));
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("pine"), false));

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setOledBlack(true);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("pine"), true));
        QVERIFY(palette.isDark());

        // On a light theme the same flip paints nothing, so nothing is emitted.
        prefs.setTheme(QStringLiteral("sand"));
        spy.clear();
        prefs.setOledBlack(false);
        QCOMPARE(spy.count(), 0);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sand")));
    }

    // The colour switch arrives through that same object. On a light theme it
    // is the one of the two that still does something.
    void currentFollowsTintedGreys() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("sand"));
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sand"), false, false));

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setTintedGreys(true);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sand"), false, true));
        QVERIFY(!palette.isDark());

        // Setting the value it already has emits nothing.
        spy.clear();
        prefs.setTintedGreys(true);
        QCOMPARE(spy.count(), 0);

        prefs.setTintedGreys(false);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("sand"), false, false));

        { QSettings s; s.clear(); s.sync(); }
    }

    // Settings needs {name, label, dark} to build the picker, and the three
    // colours a swatch draws.
    void availableIsPickerReady() {
        Prefs prefs;
        ThemePalette palette(&prefs);
        const QVariantList list = palette.available();
        QCOMPARE(list.size(), theme::themes().size());
        for (const QVariant &v : list) {
            const QVariantMap m = v.toMap();
            for (const char *k : {"name", "label", "dark", "bg", "border", "accent"})
                QVERIFY2(m.contains(QLatin1String(k)),
                         qPrintable(m.value("name").toString() + " has no "
                                    + QLatin1String(k)));
            QVERIFY(theme::isKnown(m.value("name").toString()));
            for (const char *k : {"bg", "border", "accent"})
                QVERIFY(m.value(QLatin1String(k)).value<QColor>().isValid());
        }
    }

    // A settings file carrying a theme that a later build removed must not
    // leave the app unpainted.
    void staleSettingStillPaints() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("graphite"));   // not in the table
        prefs.setOledBlack(false);
        prefs.setTintedGreys(false);
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(theme::defaultTheme()));
        QVERIFY(palette.current().contains("bg"));
    }

private:
    // The _data() bodies. darkThemeRows() and lightThemeRows() serve the tests
    // that only make sense on one half, and carry both ramps. themeRows() below
    // has one row per palette a user can be looking at.
    static void darkThemeRows() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("tinted");
        for (const auto &t : theme::themes())
            if (t.dark) rampRows(t.name);
    }

    static void lightThemeRows() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("tinted");
        for (const auto &t : theme::themes())
            if (!t.dark) rampRows(t.name);
    }

    // The dark themes by name alone, for the test that drives the two switches
    // itself.
    static void darkNameRows() {
        QTest::addColumn<QString>("name");
        for (const auto &t : theme::themes())
            if (t.dark) QTest::newRow(qPrintable(t.name)) << t.name;
    }

    static void themeRows() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("dark");
        QTest::addColumn<bool>("oled");
        QTest::addColumn<bool>("tinted");
        for (const auto &t : theme::themes()) {
            for (const bool tinted : {false, true}) {
                const QString ramp = tinted ? QStringLiteral(" tinted")
                                            : QStringLiteral(" neutral");
                QTest::newRow(qPrintable(t.name + ramp))
                    << t.name << t.dark << false << tinted;
                if (t.dark)
                    QTest::newRow(qPrintable(t.name + " in black" + ramp))
                        << t.name << t.dark << true << tinted;
            }
        }
    }

    // One theme, both ramps. Assumes the two columns above.
    static void rampRows(const QString &name) {
        for (const bool tinted : {false, true})
            QTest::newRow(qPrintable(name + (tinted ? QStringLiteral(" tinted")
                                                    : QStringLiteral(" neutral"))))
                << name << tinted;
    }

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestTheme)
#include "tst_theme.moc"
