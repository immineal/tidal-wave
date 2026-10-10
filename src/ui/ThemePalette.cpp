// SPDX-License-Identifier: GPL-3.0-or-later

#include "ThemePalette.h"
#include "Prefs.h"

#include <QHash>
#include <QMetaProperty>

#include <array>

namespace theme {
namespace {

// A palette as written down. Tints and washes are derived from the accent.
// The grounds and type here paint only with the colour switch on; with it off
// the shared neutral ramp of the mode paints. See rampFor().
struct Spec {
    const char *name;
    const char *label;   // a product name, shown as written in every language
    bool        dark;
    const char *bg;
    const char *surface;
    const char *surfaceHigh;
    const char *surfaceHov;
    const char *border;
    // The hover wash's alpha, 0-255. The pure-black transform raises it.
    int         hoverAlpha;
    const char *textPrimary;
    const char *textSec;
    const char *textDim;
    const char *accent;
    const char *accentDim;
    const char *accentInk;    // ink on a solid accent fill
    const char *red;
    const char *redInk;       // ink on a solid red fill
    const char *green;
};

// Three dark, three light, paired by hue; Settings relies on this order.
// Labels are product names and are not translated. Every accent and red
// carries white ink at 4.5:1, and textDim clears 3:1 on the grounds.
const Spec kSpecs[] = {
    { "sea",  "Sea",  true,
      "#000C14", "#07161E", "#0F202B", "#233B4A", "#192C39", 26,
      "#FFFFFF", "#A0A0A0", "#6B6B6B",
      "#0079A8", "#005A7D", "#FFFFFF",
      "#D82C2C", "#FFFFFF", "#1DB954" },

    { "pine", "Pine", true,
      "#031108", "#0F1B14", "#16251C", "#293E31", "#233429", 26,
      "#EEF5F0", "#94A69B", "#637269",
      "#18814E", "#105F39", "#FFFFFF",
      "#D23535", "#FFFFFF", "#4ADE80" },

    { "rust", "Rust", true,
      "#180A03", "#21140D", "#2C1C16", "#4B342B", "#3B2922", 26,
      "#F7F2EF", "#A89C95", "#736B66",
      "#C14A18", "#93340C", "#FFFFFF",
      "#CF3939", "#FFFFFF", "#5FBF7A" },

    { "sky",  "Sky",  false,
      "#FFFFFF", "#F2F5F8", "#E6EBF0", "#C1C8D0", "#CFD9E2", 26,
      "#08111A", "#4C5A66", "#798591",
      "#0A6FC4", "#08528F", "#FFFFFF",
      "#C0392B", "#FFFFFF", "#1B7F4B" },

    { "sand", "Sand", false,
      "#F6F6E0", "#EBEACC", "#DFDFB9", "#C1C18F", "#C1C193", 26,
      "#1B1913", "#5D564A", "#837B6C",
      "#2F6F4E", "#22543A", "#FFFFFF",
      "#A8342A", "#FFFFFF", "#4F7A35" },

    // Sand and Clay keep distinct hues even at the near-white background;
    // groundsAreTellableApart() in tests/tst_theme.cpp holds the distance.
    { "clay", "Clay", false,
      "#FFEDE4", "#FFE0D4", "#FFD1C2", "#E7AC99", "#FAC2B0", 26,
      "#241510", "#6E4F3E", "#96705D",
      "#B4481C", "#8A3310", "#FFFFFF",
      "#B3302A", "#FFFFFF", "#3F7A3A" },
};

// ── the neutral ramps ────────────────────────────────────────────────────
// One grey ramp per mode, shared by the three palettes on that side when
// Prefs::tintedGreys is off. The light ramp is the true grey at the same CIE
// L* as each step of Sky's ramp, so the contrast thresholds carry over.
struct Ramp {
    const char *bg;
    const char *surface;
    const char *surfaceHigh;
    const char *surfaceHov;
    const char *border;
    const char *textPrimary;
    const char *textSec;
    const char *textDim;
};

constexpr Ramp kNeutralDark{
    "#0A0A0A", "#141414", "#1E1E1E", "#383838", "#2A2A2A",
    "#FFFFFF", "#A0A0A0", "#6B6B6B",
};

constexpr Ramp kNeutralLight{
    "#FFFFFF", "#F5F5F5", "#EAEAEA", "#C7C7C7", "#D8D8D8",
    "#101010", "#585858", "#838383",
};

// The whole of the colour switch: it chooses a ramp and nothing else.
Ramp rampFor(const Spec &s, bool tintedGreys) {
    if (!tintedGreys) return s.dark ? kNeutralDark : kNeutralLight;
    return { s.bg, s.surface, s.surfaceHigh, s.surfaceHov, s.border,
             s.textPrimary, s.textSec, s.textDim };
}

QColor withAlpha(const QColor &c, double a) {
    QColor out = c;
    out.setAlphaF(static_cast<float>(a));
    return out;
}

// ── the pure-black transform ─────────────────────────────────────────────
// Each channel is scaled, which keeps the tint. The darker the step, the
// harder it is pulled: bg goes to black while the elevation steps have to
// stay apart, and surfaceHov has to stay stronger than hoverFill.
constexpr double kOledSurface     = 0.60;
constexpr double kOledSurfaceHigh = 0.72;
constexpr double kOledBorder      = 0.86;
constexpr double kOledSurfaceHov  = 0.96;

// The ordinary hover wash is too faint over true black.
constexpr int kOledHoverAlpha = 30;

// Which of palette()'s four tables a pair of switch positions lands in.
constexpr int slot(bool oled, bool tintedGreys) {
    return (oled ? 2 : 0) + (tintedGreys ? 1 : 0);
}

QColor pulledToBlack(const QColor &c, double factor) {
    return QColor::fromRgb(qRound(c.red()   * factor),
                           qRound(c.green() * factor),
                           qRound(c.blue()  * factor));
}

// Tokens layered over cover art are the same in every theme.
constexpr double kArtScrim       = 0.35;
constexpr double kArtScrimStrong = 0.60;
constexpr double kArtBorder      = 0.22;

// `oled` is only valid on a dark theme. The ramp is chosen first and its
// grounds are pulled down second: the other order would leave the neutral
// ramp un-pulled with the pure-black switch on.
QVariantMap build(const Spec &s, bool oled, bool tintedGreys) {
    Q_ASSERT(!oled || s.dark);
    const Ramp ramp = rampFor(s, tintedGreys);
    const QColor accent(QString::fromLatin1(s.accent));
    const QColor red(QString::fromLatin1(s.red));

    auto ground = [oled](const char *hex, double factor) {
        const QColor c(QString::fromLatin1(hex));
        return oled ? pulledToBlack(c, factor) : c;
    };

    // The dark accents are deep, so they take more alpha than the light ones.
    // The wash stays at 0.26 because the accent is also drawn on top of it.
    const double soft = s.dark ? 0.12 : 0.10;
    const double tint = s.dark ? 0.22 : 0.18;
    const double wash = 0.26;   // the same in both modes

    QVariantMap m;
    m.insert(QStringLiteral("dark"), s.dark);

    m.insert(QStringLiteral("bg"),          ground(ramp.bg, 0.0));
    m.insert(QStringLiteral("surface"),     ground(ramp.surface,     kOledSurface));
    m.insert(QStringLiteral("surfaceHigh"), ground(ramp.surfaceHigh, kOledSurfaceHigh));
    m.insert(QStringLiteral("surfaceHov"),  ground(ramp.surfaceHov,  kOledSurfaceHov));
    m.insert(QStringLiteral("border"),      ground(ramp.border,      kOledBorder));

    m.insert(QStringLiteral("textPrimary"), QColor(QString::fromLatin1(ramp.textPrimary)));
    m.insert(QStringLiteral("textSec"),     QColor(QString::fromLatin1(ramp.textSec)));
    m.insert(QStringLiteral("textDim"),     QColor(QString::fromLatin1(ramp.textDim)));

    m.insert(QStringLiteral("accent"),      accent);
    m.insert(QStringLiteral("accentDim"),   QColor(QString::fromLatin1(s.accentDim)));
    m.insert(QStringLiteral("accentInk"),    QColor(QString::fromLatin1(s.accentInk)));
    m.insert(QStringLiteral("accentSoft"),  withAlpha(accent, soft));
    m.insert(QStringLiteral("accentTint"),  withAlpha(accent, tint));
    m.insert(QStringLiteral("accentWash"),  withAlpha(accent, wash));

    // Visible on its ground but weaker than surfaceHov, which marks the
    // selected row; hoverIsVisibleButNotASelection() in tst_theme.cpp.
    const int hoverAlpha = oled ? kOledHoverAlpha : s.hoverAlpha;
    m.insert(QStringLiteral("hoverFill"),
             s.dark ? QColor(255, 255, 255, hoverAlpha)
                    : QColor(0, 0, 0, hoverAlpha));

    m.insert(QStringLiteral("red"),     red);
    m.insert(QStringLiteral("redSoft"), withAlpha(red, 0.12));
    m.insert(QStringLiteral("redInk"),   QColor(QString::fromLatin1(s.redInk)));
    m.insert(QStringLiteral("green"),   QColor(QString::fromLatin1(s.green)));
    // Pairs with accentWash, for the audio-quality badges.
    m.insert(QStringLiteral("greenWash"), withAlpha(QColor(QString::fromLatin1(s.green)), wash));

    // Dimming the app behind a modal. A light theme needs less of it.
    m.insert(QStringLiteral("scrim"), QColor(0, 0, 0, s.dark ? 140 : 97));

    m.insert(QStringLiteral("artScrim"),       withAlpha(QColor(Qt::black), kArtScrim));
    m.insert(QStringLiteral("artScrimStrong"), withAlpha(QColor(Qt::black), kArtScrimStrong));
    m.insert(QStringLiteral("artInk"),          QColor(Qt::white));
    m.insert(QStringLiteral("artBorder"),      withAlpha(QColor(Qt::white), kArtBorder));

    return m;
}

} // namespace

QList<ThemeInfo> themes() {
    QList<ThemeInfo> out;
    out.reserve(int(std::size(kSpecs)));
    for (const Spec &s : kSpecs) {
        out.append({QString::fromLatin1(s.name),
                    QString::fromLatin1(s.label),
                    s.dark});
    }
    return out;
}

bool isKnown(const QString &name) {
    for (const Spec &s : kSpecs)
        if (name == QLatin1String(s.name)) return true;
    return false;
}

// Sea, pure black on, colour on.
QString defaultTheme()     { return QStringLiteral("sea"); }
bool    defaultOledBlack() { return true; }
bool    defaultTintedGreys() { return true; }

bool migrated(const QString &stored, QString *theme, bool *oledBlack) {
    // Renaming a palette in kSpecs means adding a row here; the compiler
    // will not say so. A rename leaves the pure-black switch as stored.
    static const QHash<QString, QString> renamed = {
        {QStringLiteral("midnight"), QStringLiteral("sea")},
        {QStringLiteral("forest"),   QStringLiteral("pine")},
        {QStringLiteral("ember"),    QStringLiteral("rust")},
        {QStringLiteral("daylight"), QStringLiteral("sky")},
        {QStringLiteral("paper"),    QStringLiteral("sand")},
        {QStringLiteral("dawn"),     QStringLiteral("clay")},
    };
    const auto it = renamed.constFind(stored);
    if (it != renamed.cend()) {
        if (theme) *theme = *it;
        return true;
    }

    // "deep" is not a rename: it maps to "sea" with the pure-black switch on.
    if (stored != QLatin1String("deep")) return false;
    if (theme)     *theme     = QStringLiteral("sea");
    if (oledBlack) *oledBlack = true;
    return true;
}

QVariantMap palette(const QString &name, bool oledBlack, bool tintedGreys) {
    // Four tables, built once: the two ramps, each plain and pulled to black.
    static const std::array<QHash<QString, QVariantMap>, 4> tables = [] {
        std::array<QHash<QString, QVariantMap>, 4> out;
        for (const Spec &s : kSpecs) {
            const QString key = QString::fromLatin1(s.name);
            for (const bool tinted : {false, true}) {
                out[slot(false, tinted)].insert(key, build(s, false, tinted));
                // Light themes are absent from the black tables, so the
                // lookup below falls back to the plain one for them.
                if (s.dark) out[slot(true, tinted)].insert(key, build(s, true, tinted));
            }
        }
        return out;
    }();

    const QHash<QString, QVariantMap> &plain = tables[slot(false, tintedGreys)];
    if (oledBlack) {
        const QHash<QString, QVariantMap> &black = tables[slot(true, tintedGreys)];
        const auto it = black.constFind(name);
        if (it != black.cend()) return *it;
        // An unknown name falls back to the default palette, which is dark
        // and so takes the transform too.
        if (!plain.contains(name)) return black.value(defaultTheme());
    }
    const auto it = plain.constFind(name);
    return it != plain.cend() ? *it : plain.value(defaultTheme());
}

QVariantMap radii() {
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

void ThemePalette::setPrefs(Prefs *prefs) { setThemeSource(prefs); }

ThemePalette *ThemePalette::instance() {
    static ThemePalette *self = new ThemePalette(nullptr);
    return self;
}

ThemePalette *ThemePalette::create(QQmlEngine *, QJSEngine *) {
    ThemePalette *self = instance();
    // The singleton outlives any one engine, so the engine must not delete it.
    QQmlEngine::setObjectOwnership(self, QQmlEngine::CppOwnership);
    return self;
}

void ThemePalette::setThemeSource(QObject *source) {
    if (m_source == source) {
        if (m_current.isEmpty()) refresh();
        return;
    }
    if (m_source) disconnect(m_source, nullptr, this, nullptr);
    m_source = source;

    if (m_source) {
        // Connected by meta-object so a test double can stand in for Prefs.
        const QMetaObject *mo = m_source->metaObject();
        const int slot = metaObject()->indexOfSlot("refresh()");
        for (const char *name : {"theme", "oledBlack", "tintedGreys"}) {
            const int index = mo->indexOfProperty(name);
            if (index < 0) {
                qWarning("ThemePalette: theme source has no \"%s\" property", name);
                continue;
            }
            const QMetaProperty prop = mo->property(index);
            if (prop.hasNotifySignal())
                connect(m_source, prop.notifySignal(), this, metaObject()->method(slot));
        }
    }
    refresh();
}

void ThemePalette::refresh() {
    const QVariantMap next =
        m_source ? theme::palette(m_source->property("theme").toString(),
                                  m_source->property("oledBlack").toBool(),
                                  m_source->property("tintedGreys").toBool())
                 : theme::palette(theme::defaultTheme(), theme::defaultOledBlack(),
                                  theme::defaultTintedGreys());
    if (next == m_current) return;
    m_current = next;
    emit currentChanged();
}

QVariantList ThemePalette::available() const {
    // Read live, so the swatches follow the colour switch. The calling
    // binding in SettingsPanel.qml depends on prefs.tintedGreys to re-run.
    const bool tinted = m_source ? m_source->property("tintedGreys").toBool()
                                 : theme::defaultTintedGreys();
    QVariantList out;
    for (const auto &t : theme::themes()) {
        // The swatch colours come from here so the QML keeps no copy. The
        // pure-black switch is not applied: three swatches would turn black.
        const QVariantMap p = theme::palette(t.name, false, tinted);
        out.append(QVariantMap{{QStringLiteral("name"),   t.name},
                               {QStringLiteral("label"),  t.label},
                               {QStringLiteral("dark"),   t.dark},
                               {QStringLiteral("bg"),     p.value("bg")},
                               {QStringLiteral("border"), p.value("border")},
                               {QStringLiteral("accent"), p.value("accent")}});
    }
    return out;
}
