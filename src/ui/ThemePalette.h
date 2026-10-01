#pragma once
#include <QColor>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class Prefs;
class QQmlEngine;
class QJSEngine;

// The six palettes, the two grey ramps, the OLED transform and the
// corner-radius scale.
//
// qml/Theme.qml is a thin wrapper over this: it declares one `readonly property
// color` per token, bound to the map ThemePalette::current() hands back, so
// every existing `Theme.accent` binding in the app repaints when the palette
// changes with nothing else to touch.
//
// The table lives in C++ rather than in QML so the palettes can be tested
// properly - see tests/tst_theme.cpp, which checks WCAG contrast for every
// token against every ground it is drawn on. That matters most for the two
// light themes: about forty places in the QML were written assuming a dark
// ground, and a palette that looks plausible as a swatch strip can still put
// hint text at 1.4:1 on white.
namespace theme {

struct ThemeInfo {
    QString name;   // settings key, lowercase
    QString label;  // shown in Settings; a product name, never translated
    bool    dark;
};

// In the order Settings lays them out: the three dark ones, then the three
// light ones, each list in the same hue order, so the picker's two columns
// line up row by row as blue / green / amber.
//
// By value: six small structs built on demand, which is cheap enough that the
// picker can ask whenever it rebuilds. It used to be rebuilt because the
// labels were translated and a cached list would have kept the old language
// after a live switch; the labels are product names now, so that reason is
// gone but the shape is still the simple one.
QList<ThemeInfo> themes();

bool    isKnown(const QString &name);
QString defaultTheme();
// Whether a fresh install starts with the pure-black transform on.
bool    defaultOledBlack();
// ...and whether it starts with the tinted grounds on. False: the six palettes
// share one neutral grey ramp per mode until somebody asks otherwise.
bool    defaultTintedGreys();

// What a theme name written by an older build becomes: the six pre-rename
// names, plus "deep", which was a palette and is now the pure-black switch.
// Returns false when `stored` is nothing special, so the caller leaves it
// alone; see Prefs, which is the only thing that should be rewriting a
// settings file. `oledBlack` is only written for the keys that need it, so
// pass the stored value in and it survives a plain rename untouched.
bool migrated(const QString &stored, QString *theme, bool *oledBlack);

// Every colour token plus "dark". An unknown or empty name gives the default
// palette rather than an empty map, so a settings file written by a build that
// had different theme names still paints.
//
// Two switches, neither of them a palette of its own:
//
//   `oledBlack`    pulls the grounds down to true black. A transform rather
//                  than a seventh palette so that it composes with whichever
//                  dark theme is picked; on a light theme it is ignored,
//                  because there is no sense in which Sky has an OLED variant.
//   `tintedGreys`  paints the palette in its own grounds and type, as written
//                  down in kSpecs, instead of in the neutral grey ramp its mode
//                  shares. Off by default, which is the state where the accent
//                  is the only thing telling the six apart - and that is the
//                  design, not a fallback. Offered on all six, unlike the one
//                  above.
//
// The ramp is chosen first and the grounds are then pulled down, which is the
// only order that leaves the pure-black switch working in both states; see
// build() in the .cpp, and theTwoSwitchesComposeInEitherOrder() in
// tests/tst_theme.cpp, which holds the result to being a function of the two
// settings rather than of the order they were flipped in.
QVariantMap palette(const QString &name, bool oledBlack = false,
                    bool tintedGreys = false);

// The radius scale, keyed chip/field/row/button/art/card/popup/badge/mark.
QVariantMap radii();

} // namespace theme

// QML singleton in front of the table above. Tracks Prefs::theme,
// Prefs::oledBlack and Prefs::tintedGreys so QML never has to ask which palette
// is current, and so nothing in the QML has to know either switch exists: both
// arrive as a different `current` map and every binding repaints on its own.
class ThemePalette : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap current READ current NOTIFY currentChanged)
    Q_PROPERTY(QVariantMap radius READ radius CONSTANT)
    Q_PROPERTY(bool isDark READ isDark NOTIFY currentChanged)

public:
    // `prefs` is deliberately NOT defaulted. Qt decides how to build a
    // QML_SINGLETON by checking std::is_default_constructible FIRST and only
    // then looking for create(); with a default on every argument this type
    // was default-constructible, so QML quietly built its own instance with a
    // null Prefs and create() was never called. The app then wired a second,
    // different object, and every palette painted as the default one.
    explicit ThemePalette(Prefs *prefs, QObject *parent = nullptr);

    // The instance QML gets. Application wires Prefs into it before the engine
    // loads Main.qml; without that it still serves the default palette rather
    // than nothing, so a QML test can instantiate a page with no app around it.
    static ThemePalette *instance();
    static ThemePalette *create(QQmlEngine *, QJSEngine *);

    void setPrefs(Prefs *prefs);

    // The same thing, against anything exposing a notifying QString "theme"
    // property and notifying bool "oledBlack" and "tintedGreys" ones. It exists
    // so a test double can stand in for Prefs: the QML tests install a stub
    // with extra hooks the real class has no business carrying, and this is the
    // whole of what the palette needs from it. A source missing one of the
    // three warns rather than painting something nobody asked for.
    void setThemeSource(QObject *source);

    QVariantMap current() const { return m_current; }
    QVariantMap radius() const  { return theme::radii(); }
    bool        isDark() const  { return m_current.value(QStringLiteral("dark")).toBool(); }

    // [{name, label, dark, bg, border, accent}] for the Settings picker: the
    // three colours a swatch draws come from here rather than from a copy of
    // the table in the QML, which drifted two accent revisions behind it.
    //
    // Read live off the theme source, so the swatches show the state the colour
    // switch is actually in. The caller has to re-read it when that switch
    // moves - it is an invokable, not a bound property - which is why
    // SettingsPanel.qml keeps prefs.tintedGreys in the binding that calls it.
    Q_INVOKABLE QVariantList available() const;

signals:
    void currentChanged();

private slots:
    // A slot so it can be connected to the source's notify signal by name,
    // without knowing the concrete type.
    void refresh();

private:
    // QPointer, not a bare pointer: setThemeSource() disconnects from the old
    // one, and a source destroyed before the palette made that a hard crash.
    QPointer<QObject> m_source;
    QVariantMap m_current;
};
