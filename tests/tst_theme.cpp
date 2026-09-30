// Palette tests. Written before src/ui/ThemePalette.cpp per the project's
// tests-first rule.
//
// The point of the contrast assertions is the two light themes: about forty
// places in the QML were written against a dark ground, and a palette that
// looks fine in a swatch strip can still put #8A97A3 hint text on white. The
// thresholds are WCAG contrast ratios against the surface a token is actually
// drawn on, so a palette edit that breaks legibility fails here rather than in
// the user's eyes.

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

// Every key a palette must carry. Theme.qml surfaces exactly these, so a token
// added to one theme and forgotten in another is a failure, not a silent
// "undefined" in a QML binding.
const QStringList kColourTokens = {
    // grounds
    "bg", "surface", "surfaceHigh", "surfaceHov", "border",
    // type
    "textPrimary", "textSec", "textDim",
    // accent and the tints derived from it
    "accent", "accentDim", "onAccent", "accentSoft", "accentTint", "accentWash",
    // interaction
    "hoverFill",
    // semantic
    "red", "redSoft", "onRed", "green",
    // things drawn over arbitrary cover art, which is neither light nor dark
    "scrim", "artScrim", "artScrimStrong", "onArt", "artBorder",
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

    void sixThemes_fourDarkTwoLight() {
        const auto all = theme::themes();
        QCOMPARE(all.size(), 6);

        int dark = 0, light = 0;
        for (const auto &t : all) (t.dark ? dark : light)++;
        QCOMPARE(dark, 4);
        QCOMPARE(light, 2);
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
    }

    // Prefs ships "midnight" as its default; if the palette table ever renames
    // it the app would boot to the fallback and silently ignore the setting.
    void prefsDefaultResolves() {
        Prefs prefs;
        QVERIFY(theme::isKnown(prefs.theme()));
    }

    // ── each palette is complete ─────────────────────────────────────────

    void everyPaletteHasEveryToken_data() { themeRows(); }
    void everyPaletteHasEveryToken() {
        QFETCH(QString, name);
        const QVariantMap p = theme::palette(name);

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

    void darkFlagMatchesTheGround_data() { themeRows(); }
    void darkFlagMatchesTheGround() {
        QFETCH(QString, name);
        QFETCH(bool, dark);
        const QColor bg = theme::palette(name).value("bg").value<QColor>();
        QCOMPARE(luminance(bg) < 0.5, dark);
    }

    // ── legibility ───────────────────────────────────────────────────────

    void textIsLegible_data() { themeRows(); }
    void textIsLegible() {
        QFETCH(QString, name);
        const QVariantMap p = theme::palette(name);
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
            // textDim is deliberately quiet (timestamps, placeholders); it only
            // has to stay readable, not pass AA.
            QVERIFY2(contrast(col("textDim"), g) >= 2.0,
                     qPrintable(where + ": textDim illegible ("
                                + QString::number(contrast(col("textDim"), g), 'f', 2) + ")"));
            // The accent is used for icons and small bold labels.
            QVERIFY2(contrast(col("accent"), g) >= 3.0,
                     qPrintable(where + ": accent below AA-large ("
                                + QString::number(contrast(col("accent"), g), 'f', 2) + ")"));
        }

        // Text on a solid accent fill (PillButton, the play button).
        QVERIFY2(contrast(col("onAccent"), col("accent")) >= 4.0,
                 qPrintable(name + ": onAccent on accent is "
                            + QString::number(contrast(col("onAccent"), col("accent")), 'f', 2)));

        // Error text has to be readable too, not just red.
        QVERIFY2(contrast(col("red"), col("surface")) >= 3.0, qPrintable(name + ": red too dim"));
        // ...and the label on a solid red fill (the sidebar's Log out button).
        QVERIFY2(contrast(col("onRed"), col("red")) >= 4.0,
                 qPrintable(name + ": onRed on red is "
                            + QString::number(contrast(col("onRed"), col("red")), 'f', 2)));
    }

    void structureIsVisible_data() { themeRows(); }
    void structureIsVisible() {
        QFETCH(QString, name);
        const QVariantMap p = theme::palette(name);
        auto col = [&](const char *k) { return p.value(QLatin1String(k)).value<QColor>(); };

        // A border that matches its surface is not a border.
        QVERIFY2(contrast(col("border"), col("surface")) >= 1.12,
                 qPrintable(name + ": border invisible against surface"));
        // The elevation ramp has to actually ramp.
        QVERIFY(luminance(col("surfaceHigh")) != luminance(col("surface")));
        QVERIFY(luminance(col("surfaceHov")) != luminance(col("surfaceHigh")));
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

    // The hover wash was Qt.rgba(1,1,1,0.04) everywhere, which disappears on a
    // light ground. Each theme picks its own, and it has to be translucent or
    // it would paint over the row underneath.
    void translucentTokensAreTranslucent_data() { themeRows(); }
    void translucentTokensAreTranslucent() {
        QFETCH(QString, name);
        const QVariantMap p = theme::palette(name);
        for (const char *k : {"hoverFill", "accentSoft", "accentTint", "accentWash",
                              "redSoft", "scrim", "artScrim", "artScrimStrong", "artBorder"}) {
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

    // Things layered over cover art can't depend on the theme: the artwork is
    // whatever it is. Those tokens are shared, so they must be identical.
    void artTokensAreThemeIndependent() {
        const QVariantMap first = theme::palette(theme::themes().first().name);
        for (const auto &t : theme::themes()) {
            const QVariantMap p = theme::palette(t.name);
            for (const char *k : {"artScrim", "artScrimStrong", "onArt", "artBorder"}) {
                QCOMPARE(p.value(QLatin1String(k)).value<QColor>(),
                         first.value(QLatin1String(k)).value<QColor>());
            }
        }
    }

    void noTwoThemesAreTheSame() {
        QList<QVariantMap> seen;
        for (const auto &t : theme::themes()) {
            const QVariantMap p = theme::palette(t.name);
            for (const QVariantMap &other : seen) QVERIFY(p != other);
            seen.append(p);
        }
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

    void currentFollowsPrefs() {
        Prefs prefs;
        prefs.setTheme(QStringLiteral("midnight"));
        ThemePalette palette(&prefs);

        QCOMPARE(palette.current(), theme::palette(QStringLiteral("midnight")));
        QVERIFY(palette.isDark());

        QSignalSpy spy(&palette, &ThemePalette::currentChanged);
        prefs.setTheme(QStringLiteral("daylight"));

        QCOMPARE(spy.count(), 1);
        QCOMPARE(palette.current(), theme::palette(QStringLiteral("daylight")));
        QVERIFY(!palette.isDark());
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
        ThemePalette palette(&prefs);
        QCOMPARE(palette.current(), theme::palette(theme::defaultTheme()));
        QVERIFY(palette.current().contains("bg"));
    }

private:
    // Shared _data() body: one row per theme.
    static void themeRows() {
        QTest::addColumn<QString>("name");
        QTest::addColumn<bool>("dark");
        for (const auto &t : theme::themes())
            QTest::newRow(qPrintable(t.name)) << t.name << t.dark;
    }

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestTheme)
#include "tst_theme.moc"
