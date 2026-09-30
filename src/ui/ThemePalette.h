#pragma once
#include <QColor>
#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class Prefs;
class QQmlEngine;
class QJSEngine;

// The six palettes and the corner-radius scale.
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
    QString label;  // shown in Settings, translated
    bool    dark;
};

// In the order Settings lists them: the four dark ones, then the two light.
// By value, and rebuilt per call: the labels are translated, so a cached list
// would keep the old language after a live switch.
QList<ThemeInfo> themes();

bool    isKnown(const QString &name);
QString defaultTheme();

// Every colour token plus "dark". An unknown or empty name gives the default
// palette rather than an empty map, so a settings file written by a build that
// had different theme names still paints.
QVariantMap palette(const QString &name);

// The radius scale, keyed chip/field/row/button/art/card/popup/badge/mark.
QVariantMap radii();

} // namespace theme

// QML singleton in front of the table above. Tracks Prefs::theme so QML never
// has to ask which palette is current.
class ThemePalette : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap current READ current NOTIFY currentChanged)
    Q_PROPERTY(QVariantMap radius READ radius CONSTANT)
    Q_PROPERTY(bool isDark READ isDark NOTIFY currentChanged)

public:
    explicit ThemePalette(Prefs *prefs = nullptr, QObject *parent = nullptr);

    // The instance QML gets. Application wires Prefs into it before the engine
    // loads Main.qml; without that it still serves the default palette rather
    // than nothing, so a QML test can instantiate a page with no app around it.
    static ThemePalette *instance();
    static ThemePalette *create(QQmlEngine *, QJSEngine *);

    void setPrefs(Prefs *prefs);

    QVariantMap current() const { return m_current; }
    QVariantMap radius() const  { return theme::radii(); }
    bool        isDark() const  { return m_current.value(QStringLiteral("dark")).toBool(); }

    // [{name, label, dark}] for the Settings picker. Labels are translated at
    // call time, so the picker re-reads this when the language changes.
    Q_INVOKABLE QVariantList available() const;

signals:
    void currentChanged();

private:
    void refresh();

    Prefs      *m_prefs = nullptr;
    QVariantMap m_current;
};
