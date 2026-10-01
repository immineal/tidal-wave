// Palette tests. Written before src/ui/ThemePalette.cpp per the project's
// tests-first rule.
//
// The point of the contrast assertions is the three light themes: about forty
// places in the QML were written against a dark ground, and a palette that
// looks fine in a swatch strip can still put #8A97A3 hint text on white. The
// thresholds are WCAG contrast ratios against the surface a token is actually
// drawn on, so a palette edit that breaks legibility fails here rather than in
// the user's eyes.
//
// Every one of those thresholds is checked twice over on a dark theme: once
// as written, and once with the pure-black transform applied. themeRows()
// below emits both, so a test added here covers the OLED variant for free and
// a transform that gains contrast in one place by losing it in another cannot
// land. That is the half most likely to break: the transform moves the
// grounds and leaves the type and the accents where they were.

#include <QTest>
#include <QColor>
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

// Every key a palette must carry. Theme.qml surfaces exactly these, so a token
// added to one theme and forgotten in another is a failure, not a silent
// "undefined" in a QML binding.
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
    // table order to pair them up by hue: Midnight beside Daylight, Forest
    // beside Paper, Ember beside Dawn. That is a layout contract, not a
    // coincidence, so the shape it needs is asserted here rather than left to
    // whoever next inserts a palette in the middle of the list.
    void darkThenLight_pairedByPosition() {
        const auto all = theme::themes();
        QCOMPARE(all.size(), 6);
        for (int i = 0; i < 3; ++i)
            QVERIFY2(all.at(i).dark, qPrintable(all.at(i).name + " is not in the dark half"));
        for (int i = 3; i < 6; ++i)
            QVERIFY2(!all.at(i).dark, qPrintable(all.at(i).name + " is not in the light half"));

        const QStringList expected{"midnight", "forest", "ember", "daylight", "paper", "dawn"};
        QStringList actual;
        for (const auto &t : all) actual << t.name;
        QCOMPARE(actual, expected);
    }

    // The accent is what makes a row read as one colour family, so the two
    // halves of each row have to agree about hue. Loosely: these are an azure
    // and a blue, a green and a green, a burnt orange and a burnt orange, not
    // matched swatches.
    void eachRowIsOneHue_data() {
        QTest::addColumn<QString>("darkName");
        QTest::addColumn<QString>("lightName");
        QTest::newRow("blue")  << "midnight" << "daylight";
        QTest::newRow("green") << "forest"   << "paper";
        QTest::newRow("amber") << "ember"    << "dawn";
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
        // Which one is a design decision, so it is written down here the way
        // the radius scale is. Midnight with the pure-black switch on is what
        // the retired "Deep" palette was, which is what the user settled on.
        QCOMPARE(theme::defaultTheme(), QStringLiteral("midnight"));
        QCOMPARE(theme::defaultOledBlack(), true);
        // ...and the switch does nothing on a light theme, so a light default
        // with it on would be a default that quietly lies about itself.
        for (const auto &t : theme::themes())
            if (t.name == theme::defaultTheme()) QVERIFY(t.dark);
    }

    // The one palette this build dropped. Someone on Deep has to come back to
    // the same pixels, not to a theme one shade lighter, or the removal reads
    // as a bug.
    void deepMigratesToMidnightInBlack() {
        QString name;
        bool    oled = false;
        QVERIFY(theme::migrated(QStringLiteral("deep"), &name, &oled));
        QCOMPARE(name, QStringLiteral("midnight"));
        QCOMPARE(oled, true);
        QVERIFY(!theme::isKnown(QStringLiteral("deep")));

        // ...and nothing else is rewritten behind the user's back.
        for (const auto &t : theme::themes())
            QVERIFY2(!theme::migrated(t.name, nullptr, nullptr),
                     qPrintable(t.name + " is being migrated away from"));
        QVERIFY(!theme::migrated(QStringLiteral("graphite"), nullptr, nullptr));
        QVERIFY(!theme::migrated(QString(), nullptr, nullptr));
    }

    // Prefs takes its default from the table above rather than keeping its own
    // copy of the name; if the two ever stopped agreeing the app would boot to
    // the fallback palette and silently ignore the stored setting.
    void prefsDefaultResolves() {
        Prefs prefs;
        QVERIFY(theme::isKnown(prefs.theme()));
    }

    // ── each palette is complete ─────────────────────────────────────────

    void everyPaletteHasEveryToken_data() { themeRows(); }
    void everyPaletteHasEveryToken() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);

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

    // QML parses a property named on<Name> declared beside a property <name>
    // as a signal handler, not a binding, so Theme.onAccent never evaluated and
    // kept QColor's default: black. Every label on an accent fill was black in
    // all six themes, and nothing here noticed, because these tests read the
    // C++ table and the table was always right.
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
        const QColor bg = theme::palette(name, oled).value("bg").value<QColor>();
        QCOMPARE(luminance(bg) < 0.5, dark);
    }

    // ── legibility ───────────────────────────────────────────────────────

    void textIsLegible_data() { themeRows(); }
    void textIsLegible() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);
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
            // textDim is deliberately quiet, but it is not decoration: it
            // carries the track number and duration columns, "Playing from",
            // the login disclaimer and every Settings section heading. The
            // threshold was 2.0 and every theme sat just under 3, which is
            // where a screenshot audit found it. AA-large, no lower.
            QVERIFY2(contrast(col("textDim"), g) >= 3.0,
                     qPrintable(where + ": textDim below AA-large ("
                                + QString::number(contrast(col("textDim"), g), 'f', 2) + ")"));
            // ...and still clearly quieter than textSec, which is the whole
            // point of having both. Raising textDim until the two matched
            // would pass the line above and lose the distinction.
            QVERIFY2(contrast(col("textSec"), g) >= 1.5 * contrast(col("textDim"), g),
                     qPrintable(where + ": textDim is not quieter than textSec ("
                                + QString::number(contrast(col("textDim"), g), 'f', 2) + " vs "
                                + QString::number(contrast(col("textSec"), g), 'f', 2) + ")"));
            // The accent is used for icons and small bold labels: the active
            // nav row, an artist link, the title of the playing row. This is
            // the floor the accents are darkened down to and no further, now
            // that they also have to carry white ink from the other side.
            QVERIFY2(contrast(col("accent"), g) >= 3.0,
                     qPrintable(where + ": accent below AA-large ("
                                + QString::number(contrast(col("accent"), g), 'f', 2) + ")"));
        }

        // Text on a solid accent fill (PillButton, the play button, the
        // Collection filter pills). AA, not AA-large: a filter pill's count is
        // small text, and this is the requirement the accents were darkened to
        // meet.
        QVERIFY2(contrast(col("accentInk"), col("accent")) >= 4.5,
                 qPrintable(name + ": accentInk on accent is "
                            + QString::number(contrast(col("accentInk"), col("accent")), 'f', 2)));

        // Error text has to be readable too, not just red.
        QVERIFY2(contrast(col("red"), col("surface")) >= 3.0, qPrintable(name + ": red too dim"));
        // ...and the label on a solid red fill (the danger buttons in
        // Settings, which fill with red on hover). Same argument as the
        // accent, same threshold.
        QVERIFY2(contrast(col("redInk"), col("red")) >= 4.5,
                 qPrintable(name + ": redInk on red is "
                            + QString::number(contrast(col("redInk"), col("red")), 'f', 2)));
    }

    // The ratio above would still pass with near-black ink on a bright accent,
    // which is the arrangement the user asked to be rid of: on the Collection
    // filter pills the word, the parentheses and the count all have to be
    // white on the accent fill. So the ink is white in all six, and this is
    // what stops a later palette edit from quietly putting dark ink back.
    void inkOnAFillIsWhite_data() { themeRows(); }
    void inkOnAFillIsWhite() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);
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
        const QVariantMap p = theme::palette(name, oled);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        // A border that matches its surface is not a border.
        QVERIFY2(contrast(col("border"), col("surface")) >= 1.12,
                 qPrintable(name + ": border invisible against surface"));

        // The elevation ramp has to actually ramp, and by enough to see. This
        // was "the luminances differ", which a transform that compresses the
        // ramp toward black passes while flattening the page into one slab;
        // 1.06 is just under the tightest step any palette here takes.
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

    // A hover you cannot see is not feedback. Both hover treatments were
    // measured off screenshots and both were too faint: hoverFill (sidebar nav
    // rows, the finder's kind chips, the theme tiles in Settings) landed near
    // 1.1:1 against its ground, and surfaceHov, which TrackRow and every menu
    // use, near 1.3:1.
    //
    // 3:1 is the WCAG figure for a control's own boundary; a wash laid over a
    // row cannot reach it without reading as a filled, selected row, so these
    // thresholds are the honest ones: roughly double the step that was there,
    // and far enough apart that the two treatments stay distinct.
    void hoverIsVisibleButNotASelection_data() { themeRows(); }
    void hoverIsVisibleButNotASelection() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);
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

    // The hover wash was Qt.rgba(1,1,1,0.04) everywhere, which disappears on a
    // light ground. Each theme picks its own, and it has to be translucent or
    // it would paint over the row underneath.
    void translucentTokensAreTranslucent_data() { themeRows(); }
    void translucentTokensAreTranslucent() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);
        for (const char *k : {"hoverFill", "accentSoft", "accentTint", "accentWash",
                              "redSoft", "greenWash", "scrim", "artScrim",
                              "artScrimStrong", "artBorder"}) {
            const QColor c = p.value(QLatin1String(k)).value<QColor>();
            QVERIFY2(c.alphaF() < 1.0, qPrintable(name + "." + QLatin1String(k) + " is opaque"));
            QVERIFY2(c.alphaF() > 0.0, qPrintable(name + "." + QLatin1String(k) + " is invisible"));
        }
        // ...and the accent tints have to read as the accent, not as grey.
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

    // The album, mix and playlist heroes are accentTint fading into bg.
    // Darkening the accents took luminance out of the tints along with them,
    // so the tint alphas went up to compensate; this is the check that the
    // compensation held and the hero did not fade to nothing.
    void heroGradientStillReads_data() { themeRows(); }
    void heroGradientStillReads() {
        QFETCH(QString, name);
        QFETCH(bool, oled);
        const QVariantMap p = theme::palette(name, oled);
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
            const QVariantMap p = theme::palette(t.name);
            for (const char *k : {"artScrim", "artScrimStrong", "artInk", "artBorder"}) {
                QCOMPARE(p.value(QLatin1String(k)).value<QColor>(),
                         first.value(QLatin1String(k)).value<QColor>());
            }
        }
    }

    // Including the black variants: nine distinct palettes, so the switch is
    // never a no-op on a theme that is supposed to have one, and no theme is
    // secretly another theme's black variant.
    void noTwoThemesAreTheSame() {
        QList<QVariantMap> seen;
        QStringList tags;
        for (const auto &t : theme::themes()) {
            for (bool oled : {false, true}) {
                if (oled && !t.dark) continue;
                const QVariantMap p = theme::palette(t.name, oled);
                const QString tag = t.name + (oled ? " in black" : "");
                for (int i = 0; i < seen.size(); ++i)
                    QVERIFY2(p != seen.at(i),
                             qPrintable(tag + " is identical to " + tags.at(i)));
                seen.append(p);
                tags.append(tag);
            }
        }
        QCOMPARE(seen.size(), 9);
    }

    // ── the pure-black transform ─────────────────────────────────────────
    //
    // What it is allowed to touch. Everything above already runs twice on a
    // dark theme, as written and in black, so legibility is covered; these
    // are about the transform itself behaving like one.

    void oledPullsEveryGroundDown_data() { darkThemeRows(); }
    void oledPullsEveryGroundDown() {
        QFETCH(QString, name);
        const QVariantMap plain = theme::palette(name, false);
        const QVariantMap black = theme::palette(name, true);
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

        // The tint survives the trip: scaling the channels rather than
        // subtracting a constant is what stops Forest going grey down there.
        for (const char *k : {"surface", "surfaceHigh", "surfaceHov", "border"}) {
            const QColor a = col(plain, k), b = col(black, k);
            if (a.saturation() < 12) continue;   // Midnight is grey on purpose
            QVERIFY2(qAbs(a.hue() - b.hue()) <= 12, qPrintable(
                name + "." + QLatin1String(k) + " changed hue, " + a.name()
                + " -> " + b.name()));
        }
    }

    // Nothing but the grounds and the hover wash. The type and the accents
    // were tuned against the thresholds above and have no business moving
    // because a switch was flipped.
    void oledTouchesNothingButTheGrounds_data() { darkThemeRows(); }
    void oledTouchesNothingButTheGrounds() {
        QFETCH(QString, name);
        const QVariantMap plain = theme::palette(name, false);
        const QVariantMap black = theme::palette(name, true);

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

    // There is no such thing as a black Daylight, and the picker hides the
    // switch rather than greying it out, so asking for one has to be inert
    // rather than merely harmless.
    void oledIsANoOpOnALightTheme_data() { lightThemeRows(); }
    void oledIsANoOpOnALightTheme() {
        QFETCH(QString, name);
        QCOMPARE(theme::palette(name, true), theme::palette(name, false));
    }

    // An unknown stored name still has to paint, with the switch either way.
    void oledSurvivesAnUnknownName() {
        const QVariantMap fallback = theme::palette(theme::defaultTheme(), true);
        QCOMPARE(theme::palette(QStringLiteral("no-such-theme"), true), fallback);
        QCOMPARE(theme::palette(QString(), true), fallback);
        QVERIFY(fallback.value("bg").value<QColor>() == QColor(Qt::black));
    }

    // ── lookup behaviour ─────────────────────────────────────────────────

    void unknownNameFallsBackToTheDefault() {
        const QVariantMap fallback = theme::palette(theme::defaultTheme());
        QCOMPARE(theme::palette(QStringLiteral("no-such-theme")), fallback);
        QCOMPARE(theme::palette(QString()), fallback);
        QVERIFY(!theme::isKnown(QStringLiteral("no-such-theme")));
    }

    // ── the radius scale ─────────────────────────────────────────────────
    //
    // The numbers the user signed off on. Hardcoding them here is the point:
    // the scale is a design decision, so drifting off it should fail a test.
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
    // std::is_default_constructible before it looks for create(). While every
    // constructor argument had a default, QML silently built its own instance
    // with a null Prefs instead of calling create(), the app wired a second
    // object, and all six palettes painted as the default one. Theme switching
    // was dead in the shipped app and every test here still passed, because
    // they only ever called the free functions.
    void singletonIsNotDefaultConstructible() {
        static_assert(!std::is_default_constructible_v<ThemePalette>,
                      "ThemePalette must not be default-constructible, or Qt "
                      "ignores create() and QML gets an instance with no Prefs");
        QVERIFY(!std::is_default_constructible_v<ThemePalette>);
    }

    // create() is what the QML engine calls. It has to hand back the same
    // object Application wired Prefs into, not a fresh one.
    void createReturnsTheWiredInstance() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("ember"));
        prefs.setOledBlack(false);
        ThemePalette::instance()->setPrefs(&prefs);

        ThemePalette *fromQml = ThemePalette::create(nullptr, nullptr);
        QCOMPARE(fromQml, ThemePalette::instance());
        QCOMPARE(fromQml->current(), theme::palette(QStringLiteral("ember")));

        // ...and it keeps following Prefs through that same pointer.
        prefs.setTheme(QStringLiteral("daylight"));
        QCOMPARE(fromQml->current(), theme::palette(QStringLiteral("daylight")));
        QVERIFY(!fromQml->isDark());
    }

    void currentFollowsPrefs() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("midnight"));
        prefs.setOledBlack(false);
        ThemePalette palette(&prefs);

        QCOMPARE(palette.current(), theme::palette(QStringLiteral("midnight")));
        QVERIFY(palette.isDark());

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setTheme(QStringLiteral("daylight"));

        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("daylight")));
        QVERIFY(!palette.isDark());
    }

    // The switch has to arrive through the same pipe the theme does, or the
    // app would need a binding that knows about it - which is the thing
    // qml/Theme.qml is built to avoid.
    void currentFollowsOledBlack() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("forest"));
        prefs.setOledBlack(false);
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("forest"), false));

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setOledBlack(true);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("forest"), true));
        QVERIFY(palette.isDark());

        // On a light theme the same flip paints nothing, so it must not even
        // claim to have changed anything.
        prefs.setTheme(QStringLiteral("paper"));
        spy.clear();
        prefs.setOledBlack(false);
        QCOMPARE(spy.count(), 0);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("paper")));
    }

    // Settings needs {name, label, dark} to build the picker.
    void availableIsPickerReady() {
        Prefs prefs;
        ThemePalette palette(&prefs);
        const QVariantList list = palette.available();
        QCOMPARE(list.size(), theme::themes().size());
        for (const QVariant &v : list) {
            const QVariantMap m = v.toMap();
            QVERIFY(m.contains("name"));
            QVERIFY(m.contains("label"));
            QVERIFY(m.contains("dark"));
            QVERIFY(theme::isKnown(m.value("name").toString()));
        }
    }

    // A settings file carrying a theme that a later build removed must not
    // leave the app unpainted.
    void staleSettingStillPaints() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("graphite"));   // renamed to "forest"
        prefs.setOledBlack(false);
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(theme::defaultTheme()));
        QVERIFY(palette.current().contains("bg"));
    }

private:
    // Shared _data() body: one row per palette a user can actually be looking
    // at. That is every theme as written, plus the pure-black variant of each
    // dark one - the light themes have no second variant, because the switch
    // is a no-op there and a duplicate row would only make the output longer.
    // The dark half and the light half on their own, for the tests that only
    // make sense on one of the two.
    static void darkThemeRows() {
        QTest::addColumn<QString>("name");
        for (const auto &t : theme::themes())
            if (t.dark) QTest::newRow(qPrintable(t.name)) << t.name;
    }

    static void lightThemeRows() {
        QTest::addColumn<QString>("name");
        for (const auto &t : theme::themes())
            if (!t.dark) QTest::newRow(qPrintable(t.name)) << t.name;
    }

    static void themeRows() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("dark");
        QTest::addColumn<bool>("oled");
        for (const auto &t : theme::themes()) {
            QTest::newRow(qPrintable(t.name)) << t.name << t.dark << false;
            if (t.dark)
                QTest::newRow(qPrintable(t.name + " in black")) << t.name << t.dark << true;
        }
    }

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestTheme)
#include "tst_theme.moc"
