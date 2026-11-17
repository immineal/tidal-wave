// SPDX-License-Identifier: GPL-3.0-or-later

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
// corner-radius scale. qml/Theme.qml binds one property per token to the map
// ThemePalette::current() returns. The table is in C++ so tests/tst_theme.cpp
// can check contrast for every token against every ground.
namespace theme {

struct ThemeInfo {
    QString name;   // settings key, lowercase
    QString label;  // shown in Settings; a product name, never translated
    bool    dark;
};

// In the order Settings lays them out: three dark, then three light, both in
// the same hue order.
QList<ThemeInfo> themes();

bool    isKnown(const QString &name);
QString defaultTheme();
// Whether a fresh install starts with the pure-black transform on.
bool    defaultOledBlack();
// Whether a fresh install starts with the tinted grounds on.
bool    defaultTintedGreys();

// Maps a theme name written by an older build. False when `stored` needs no
// migration. `oledBlack` is written only for "deep", so pass the stored value
// in and it survives a plain rename.
bool migrated(const QString &stored, QString *theme, bool *oledBlack);

// Every colour token plus "dark". An unknown or empty name gives the default
// palette. `oledBlack` pulls the grounds to true black and is ignored on a
// light theme; `tintedGreys` swaps the neutral ramp for the palette's own.
QVariantMap palette(const QString &name, bool oledBlack = false,
                    bool tintedGreys = false);

// The radius scale, keyed chip/field/row/button/art/card/popup/badge/mark.
QVariantMap radii();

} // namespace theme

// QML singleton in front of the table above. Tracks Prefs::theme,
// Prefs::oledBlack and Prefs::tintedGreys and republishes `current`.
class ThemePalette : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap current READ current NOTIFY currentChanged)
    Q_PROPERTY(QVariantMap radius READ radius CONSTANT)
    Q_PROPERTY(bool isDark READ isDark NOTIFY currentChanged)

public:
    // `prefs` must not be defaulted: a default-constructible QML_SINGLETON is
    // built by QML directly and create() is never called.
    explicit ThemePalette(Prefs *prefs, QObject *parent = nullptr);

    // The instance QML gets. Without Prefs wired in it serves the default
    // palette, so a QML test can load a page with no app around it.
    static ThemePalette *instance();
    static ThemePalette *create(QQmlEngine *, QJSEngine *);

    void setPrefs(Prefs *prefs);

    // The same, for any object with notifying "theme" (QString), "oledBlack"
    // and "tintedGreys" (bool) properties, so a test double can stand in for
    // Prefs. A missing property is warned about.
    void setThemeSource(QObject *source);

    QVariantMap current() const { return m_current; }
    QVariantMap radius() const  { return theme::radii(); }
    bool        isDark() const  { return m_current.value(QStringLiteral("dark")).toBool(); }

    // [{name, label, dark, bg, border, accent}] for the Settings picker.
    // An invokable has no notify signal, so the caller has to re-read it
    // when the colour switch moves.
    Q_INVOKABLE QVariantList available() const;

signals:
    void currentChanged();

private slots:
    // A slot so it can be connected to the source's notify signal by name,
    // without knowing the concrete type.
    void refresh();

private:
    // QPointer: setThemeSource() disconnects from the old source, which may
    // already be destroyed.
    QPointer<QObject> m_source;
    QVariantMap m_current;
};
