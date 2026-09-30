#include "ThemePalette.h"
#include "Prefs.h"

#include <QCoreApplication>
#include <QHash>

namespace theme {
namespace {

// A palette as written down. Tints and washes are derived from the accent
// rather than spelled out, so they can't drift off-hue and there are eighteen
// fewer hex codes to get wrong.
struct Spec {
    const char *name;
    const char *label;   // translated through QT_TRANSLATE_NOOP below
    bool        dark;
    const char *bg;
    const char *surface;
    const char *surfaceHigh;
    const char *surfaceHov;
    const char *border;
    const char *textPrimary;
    const char *textSec;
    const char *textDim;
    const char *accent;
    const char *accentDim;
    const char *onAccent;    // ink on a solid accent fill
    const char *red;
    const char *onRed;       // ink on a solid red fill
    const char *green;
};

// Four dark, two light.
//
// "Forest" stands where a violet "Graphite" was drafted; the user asked for a
// green one instead. On the dark themes the accent is bright enough that white
// text on it fails contrast, so onAccent is a near-black drawn from the same
// hue; on the light themes the accent is deep and onAccent is white.
const Spec kSpecs[] = {
    { "midnight", QT_TRANSLATE_NOOP("Theme", "Midnight"), true,
      "#0A0A0A", "#141414", "#1E1E1E", "#262626", "#2A2A2A",
      "#FFFFFF", "#A0A0A0", "#555555",
      "#00B2F8", "#0082B8", "#04161F",
      "#FF4D4D", "#2A0A0A", "#1DB954" },

    { "forest",   QT_TRANSLATE_NOOP("Theme", "Forest"),   true,
      "#0B0F0C", "#141A16", "#1C241E", "#242E26", "#29332B",
      "#EEF5F0", "#94A69B", "#56655C",
      "#3DD68C", "#2A9E66", "#04180F",
      "#FF5A5A", "#2A0A0A", "#4ADE80" },

    { "ember",    QT_TRANSLATE_NOOP("Theme", "Ember"),    true,
      "#100D0C", "#1A1614", "#241F1C", "#2E2825", "#332C28",
      "#F7F2EF", "#A89C95", "#615853",
      "#FF7A45", "#C25A2E", "#1F0B04",
      "#FF5F5F", "#2A0A0A", "#5FBF7A" },

    { "deep",     QT_TRANSLATE_NOOP("Theme", "Deep"),     true,
      "#000000", "#0C0C0E", "#16161A", "#1E1E24", "#24242B",
      "#FFFFFF", "#9BA1AB", "#4E545E",
      "#22D3EE", "#0E9BB3", "#03181C",
      "#FF5C6E", "#2A0A0F", "#34D399" },

    { "daylight", QT_TRANSLATE_NOOP("Theme", "Daylight"), false,
      "#FFFFFF", "#F2F5F8", "#E6EBF0", "#D8E0E8", "#CFD9E2",
      "#08111A", "#4C5A66", "#8A97A3",
      "#0A6FC4", "#08528F", "#FFFFFF",
      "#C0392B", "#FFFFFF", "#1B7F4B" },

    { "paper",    QT_TRANSLATE_NOOP("Theme", "Paper"),    false,
      "#FAF7F0", "#F1EBDC", "#E7DFCB", "#DBD1B9", "#CBC0A6",
      "#1B1913", "#5D564A", "#958C7B",
      "#2F6F4E", "#22543A", "#FFFFFF",
      "#A8342A", "#FFFFFF", "#4F7A35" },
};

QColor withAlpha(const QColor &c, double a) {
    QColor out = c;
    out.setAlphaF(static_cast<float>(a));
    return out;
}

// Things layered over cover art are the same in every theme: the artwork
// underneath is whatever it is, so these cannot follow the ground.
constexpr double kArtScrim       = 0.35;
constexpr double kArtScrimStrong = 0.60;
constexpr double kArtBorder      = 0.22;

QVariantMap build(const Spec &s) {
    const QColor accent(QString::fromLatin1(s.accent));
    const QColor red(QString::fromLatin1(s.red));

    // A wash over a light ground has to be heavier than the same wash over a
    // dark one to read at all.
    const double soft = s.dark ? 0.08 : 0.10;
    const double tint = s.dark ? 0.15 : 0.18;
    const double wash = s.dark ? 0.22 : 0.26;

    QVariantMap m;
    m.insert(QStringLiteral("dark"), s.dark);

    m.insert(QStringLiteral("bg"),          QColor(QString::fromLatin1(s.bg)));
    m.insert(QStringLiteral("surface"),     QColor(QString::fromLatin1(s.surface)));
    m.insert(QStringLiteral("surfaceHigh"), QColor(QString::fromLatin1(s.surfaceHigh)));
    m.insert(QStringLiteral("surfaceHov"),  QColor(QString::fromLatin1(s.surfaceHov)));
    m.insert(QStringLiteral("border"),      QColor(QString::fromLatin1(s.border)));

    m.insert(QStringLiteral("textPrimary"), QColor(QString::fromLatin1(s.textPrimary)));
    m.insert(QStringLiteral("textSec"),     QColor(QString::fromLatin1(s.textSec)));
    m.insert(QStringLiteral("textDim"),     QColor(QString::fromLatin1(s.textDim)));

    m.insert(QStringLiteral("accent"),      accent);
    m.insert(QStringLiteral("accentDim"),   QColor(QString::fromLatin1(s.accentDim)));
    m.insert(QStringLiteral("onAccent"),    QColor(QString::fromLatin1(s.onAccent)));
    m.insert(QStringLiteral("accentSoft"),  withAlpha(accent, soft));
    m.insert(QStringLiteral("accentTint"),  withAlpha(accent, tint));
    m.insert(QStringLiteral("accentWash"),  withAlpha(accent, wash));

    // Was Qt.rgba(1,1,1,0.04) everywhere, which is invisible on a light ground.
    m.insert(QStringLiteral("hoverFill"),
             s.dark ? QColor(255, 255, 255, 12) : QColor(0, 0, 0, 14));

    m.insert(QStringLiteral("red"),     red);
    m.insert(QStringLiteral("redSoft"), withAlpha(red, 0.12));
    m.insert(QStringLiteral("onRed"),   QColor(QString::fromLatin1(s.onRed)));
    m.insert(QStringLiteral("green"),   QColor(QString::fromLatin1(s.green)));

    // Dimming the app behind a modal. A light theme needs less of it.
    m.insert(QStringLiteral("scrim"), QColor(0, 0, 0, s.dark ? 140 : 97));

    m.insert(QStringLiteral("artScrim"),       withAlpha(QColor(Qt::black), kArtScrim));
    m.insert(QStringLiteral("artScrimStrong"), withAlpha(QColor(Qt::black), kArtScrimStrong));
    m.insert(QStringLiteral("onArt"),          QColor(Qt::white));
    m.insert(QStringLiteral("artBorder"),      withAlpha(QColor(Qt::white), kArtBorder));

    return m;
}

} // namespace

QList<ThemeInfo> themes() {
    QList<ThemeInfo> out;
    out.reserve(int(std::size(kSpecs)));
    for (const Spec &s : kSpecs) {
        out.append({QString::fromLatin1(s.name),
                    QCoreApplication::translate("Theme", s.label),
                    s.dark});
    }
    return out;
}

bool isKnown(const QString &name) {
    for (const Spec &s : kSpecs)
        if (name == QLatin1String(s.name)) return true;
    return false;
}

QString defaultTheme() { return QStringLiteral("midnight"); }

QVariantMap palette(const QString &name) {
    static const QHash<QString, QVariantMap> built = [] {
        QHash<QString, QVariantMap> out;
        for (const Spec &s : kSpecs) out.insert(QString::fromLatin1(s.name), build(s));
        return out;
    }();
    const auto it = built.constFind(name);
    return it != built.cend() ? *it : built.value(defaultTheme());
}

QVariantMap radii() {
    // The scale the user signed off on. The rounder something is, the more it
    // reads as a control floating above the surface rather than as the surface.
    return {
        {QStringLiteral("chip"),   999},  // pills and filter toggles, fully round
        {QStringLiteral("field"),  14},   // the sidebar search field
        {QStringLiteral("row"),    7},    // nav rows, hover fills, list rows
        {QStringLiteral("button"), 8},
        {QStringLiteral("art"),    5},    // covers and thumbnails
        {QStringLiteral("card"),   11},
        {QStringLiteral("popup"),  14},   // dialogs and panels
        {QStringLiteral("badge"),  4},    // the quality tag and friends
        {QStringLiteral("mark"),   14},   // the app icon tile
    };
}

} // namespace theme

// ─────────────────────────────────────────────────────────────────────────────

ThemePalette::ThemePalette(Prefs *prefs, QObject *parent) : QObject(parent) {
    setPrefs(prefs);
}

ThemePalette *ThemePalette::instance() {
    static ThemePalette *self = new ThemePalette();
    return self;
}

ThemePalette *ThemePalette::create(QQmlEngine *, QJSEngine *) {
    ThemePalette *self = instance();
    // The singleton outlives any one engine, so the engine must not delete it.
    QQmlEngine::setObjectOwnership(self, QQmlEngine::CppOwnership);
    return self;
}

void ThemePalette::setPrefs(Prefs *prefs) {
    if (m_prefs == prefs) {
        if (m_current.isEmpty()) refresh();
        return;
    }
    if (m_prefs) disconnect(m_prefs, nullptr, this, nullptr);
    m_prefs = prefs;
    if (m_prefs) connect(m_prefs, &Prefs::themeChanged, this, &ThemePalette::refresh);
    refresh();
}

void ThemePalette::refresh() {
    const QVariantMap next =
        theme::palette(m_prefs ? m_prefs->theme() : theme::defaultTheme());
    if (next == m_current) return;
    m_current = next;
    emit currentChanged();
}

QVariantList ThemePalette::available() const {
    QVariantList out;
    for (const auto &t : theme::themes()) {
        out.append(QVariantMap{{QStringLiteral("name"),  t.name},
                               {QStringLiteral("label"), t.label},
                               {QStringLiteral("dark"),  t.dark}});
    }
    return out;
}
