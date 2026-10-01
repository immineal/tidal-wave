#include "ThemePalette.h"
#include "Prefs.h"

#include <QHash>
#include <QMetaProperty>

#include <array>

namespace theme {
namespace {

// A palette as written down. Tints and washes are derived from the accent
// rather than spelled out, so they can't drift off-hue and there are eighteen
// fewer hex codes to get wrong.
//
// The grounds and the type below are the *tinted* half of the design: what the
// colour switch turns on. By default they are not what paints - kNeutralDark
// and kNeutralLight are, one shared ramp per mode - and the accent is then the
// only thing that tells the six palettes apart. See rampFor().
struct Spec {
    const char *name;
    const char *label;   // a product name, shown as written in every language
    bool        dark;
    const char *bg;
    const char *surface;
    const char *surfaceHigh;
    const char *surfaceHov;
    const char *border;
    // The hover wash's alpha, 0-255. Per theme rather than one number for
    // light and one for dark, because the pure-black transform below has to
    // raise it: a 10% white wash over a true-black page lands at 1.21:1,
    // just under the floor tst_theme.cpp holds it to.
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

// Three dark, three light, paired by hue: Sea with Sky (blue), Pine with Sand
// (green), Rust with Clay (amber). Settings lays the two lists out as columns
// and relies on that order, so a theme inserted here moves a row in the picker.
//
// Each name is one ordinary thing of roughly that colour, and nothing more.
// The picker is already a grid with a Dark column and a Light column, so the
// names these replaced - Midnight, Daylight, Forest, Paper, Ember, Dawn - were
// either repeating the column heading or reading as a set of times of day. The
// labels are also not translated: they are product names, so the German build
// shows the same six words, which is why there is no QT_TRANSLATE_NOOP here
// and no entry for them in i18n/tidal-wave_de.ts.
//
// "Pine" stands where a violet "Graphite" was drafted; the user asked for a
// green one instead. A teal "Deep" stood where the OLED switch now is: it was
// the blue dark theme with its grounds pulled to black, which is a treatment
// rather than a palette, so it became one - see kOled* below.
//
// accentInk and redInk are white in all six. They were a near-black on the
// dark themes, because white on those bright accents measured 1.8-2.6:1 and
// failed; the user wants the label on a filled chip white, so the fill moved
// instead of the ink. Every accent and every red below is now dark enough to
// carry white at 4.5:1 and still light enough to read as text and icons on
// bg, surface and surfaceHigh at 3:1. Those two pull against each other and
// leave a relative luminance band of roughly 0.15 to 0.18 on the dark themes,
// which is why the dark accents are so much deeper than they were. The hue of
// each is untouched, so Sea is still azure, Pine green and Rust orange, and
// the light themes did not have to move at all: their accents were already
// deep enough.
//
// Two columns were moved after a screenshot audit, and both are load-bearing:
//
//   textDim    carries the track number and duration columns, "Playing from",
//              every Settings heading and the login disclaimer, so it is
//              content and not decoration. It sat at 2.2-3.1:1 and now clears
//              3:1 on bg, surface and surfaceHigh while staying roughly half
//              of textSec's contrast, which is what makes it read as quiet.
//   surfaceHov is the hover fill for a track row and the highlight for a menu
//              item. At 1.27-1.42:1 against the page you could not tell a
//              hovered row from its neighbours; it is ~1.69:1 now.
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

    // Rust's light partner. The paragraph that used to sit here claimed these
    // grounds were "peach rather than cream" and that the two "never read as
    // the same idea". On screen they did: the user reported Sand and Clay as
    // almost the same theme, and measuring agreed - their backgrounds were
    // 1.90 apart in CIE Lab, below the ~2.3 that is the smallest difference an
    // eye can resolve. The hue separation the comment described was real only
    // deep in the ramp, where the least page area is.
    //
    // So both warm palettes now carry a deliberate hue, strong enough to
    // survive being a near-white: Sand sits at Lab hue 108 deg (R=G with green
    // leading blue - a cream that leans olive) and Clay at 44 deg (red leading
    // green by 18-46 - a blush). That is dE 9.36 at the background and more
    // further down. groundsAreTellableApart() in tests/tst_theme.cpp holds it.
    { "clay", "Clay", false,
      "#FFEDE4", "#FFE0D4", "#FFD1C2", "#E7AC99", "#FAC2B0", 26,
      "#241510", "#6E4F3E", "#96705D",
      "#B4481C", "#8A3310", "#FFFFFF",
      "#B3302A", "#FFFFFF", "#3F7A3A" },
};

// ── the neutral ramps ────────────────────────────────────────────────────
//
// The default state: one grey ramp per mode, shared by all three palettes on
// that side, with each theme keeping its own accent. The user asked for "the 6
// themes with the three accents we have at the moment but with almost neutral,
// consistent grays", and for the tinted grounds above to be a switch over the
// top of that, which is Prefs::tintedGreys.
//
// The dark ramp is not a new invention. It is what Sea carried before the
// tinted grounds landed, and it was already perfectly neutral - every step is
// R == G == B. Reusing it rather than inventing one means the pure-black switch
// over the neutral state is byte for byte the retired "Deep" palette, so the
// migration in migrated() below still reproduces what Deep painted.
//
// The light ramp is derived rather than chosen: the true grey at the same CIE
// L* as each step of Sky's tinted ramp, to within a fifth of a unit. Sky's own
// values are faintly blue, which is what "almost neutral" rules out, but its
// *lightness* is what the light palettes' contrast was tuned against - about
// forty places in the QML were written assuming a dark ground - so carrying the
// L* over carries every threshold in tests/tst_theme.cpp over with it instead
// of guessing at a replacement ramp and hoping it measured the same.
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

// Which greys a palette is painted in. This is the whole of the colour switch:
// it chooses a ramp, and everything else about the palette - the accent, the
// washes derived from it, the semantic colours, the tokens drawn over cover
// art - is the same either way.
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
//
// What the retired "Deep" palette was, as an operation any dark theme can
// take. Deep was the blue dark theme with its grounds pulled down, and these
// factors are the ratios it sat at, rounded: 12/20, 22/30, 36/42 and 52/56.
// Scaling each channel rather than subtracting a constant is what keeps the
// tint - Pine stays green down there and Rust stays warm, which a flat
// subtraction would have bleached out.
//
// They are not one number because the ramp has to survive being compressed.
// bg goes all the way to black, and if the rest followed it that far the
// elevation steps would close up: tst_theme.cpp wants surface, surfaceHigh
// and surfaceHov still separated, and - the binding constraint - it wants an
// opaque surfaceHov to stay stronger against surfaceHigh than the hoverFill
// wash laid over it. The wash gets *heavier* here (below), so the top of the
// ramp has to give up the least ground. Hence a curve: the darker the step,
// the harder it is pulled.
constexpr double kOledSurface     = 0.60;
constexpr double kOledSurfaceHigh = 0.72;
constexpr double kOledBorder      = 0.86;
constexpr double kOledSurfaceHov  = 0.96;

// A 10% white wash over a true-black page measures 1.21:1, which is under the
// floor, so the hover treatment is dialled up along with the grounds. Deep
// used 32 for the same reason; 30 reads the same and leaves more room between
// a hovered row and a selected one.
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

// Things layered over cover art are the same in every theme: the artwork
// underneath is whatever it is, so these cannot follow the ground.
constexpr double kArtScrim       = 0.35;
constexpr double kArtScrimStrong = 0.60;
constexpr double kArtBorder      = 0.22;

// `oled` is only ever honoured on a dark theme; palette() already refuses to
// pass it for a light one, and the assert here is what keeps that true if a
// second caller appears.
//
// The two switches are applied in this order and only this order: the ramp is
// chosen first, then its grounds are pulled down. The other way round - pull a
// ground down, then swap the ramp out from under it - would hand the page the
// un-pulled neutral ramp and leave bg at #0A0A0A with the pure-black switch on,
// which is that switch silently not working for everybody on the default
// state. tests/tst_theme.cpp pins both halves: oledPullsEveryGroundDown() runs
// over both ramps, and theTwoSwitchesComposeInEitherOrder() holds the palette
// to being a function of the two settings rather than of the order they were
// flipped in.
QVariantMap build(const Spec &s, bool oled, bool tintedGreys) {
    Q_ASSERT(!oled || s.dark);
    const Ramp ramp = rampFor(s, tintedGreys);
    const QColor accent(QString::fromLatin1(s.accent));
    const QColor red(QString::fromLatin1(s.red));

    auto ground = [oled](const char *hex, double factor) {
        const QColor c(QString::fromLatin1(hex));
        return oled ? pulledToBlack(c, factor) : c;
    };

    // A wash reads by what it paints, not by its alpha. The dark accents lost
    // about half their luminance when they were darkened to carry white text,
    // so these went up to keep the painted result near where the user signed
    // it off: the album hero and the playing row's tint land within a few
    // hundredths of what they measured before. The wash stops at 0.26 and
    // does not fully recover its old weight, because the accent is drawn on
    // top of it too, on the mix cover placeholder, and a heavier wash closes
    // the gap between the two. The dark themes now take more alpha than the
    // light ones, which is the reverse of the old rule.
    const double soft = s.dark ? 0.12 : 0.10;
    const double tint = s.dark ? 0.22 : 0.18;
    const double wash = 0.26;   // the same in both directions now

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

    // Was Qt.rgba(1,1,1,0.04) everywhere, which is invisible on a light
    // ground, then ~5% in both directions, which was barely better: a hovered
    // row came out at 1.1:1 against the ground it sits on. Strong enough now
    // to be unmistakable, and still well short of surfaceHov, which the
    // sidebar uses for the row you are actually on - see tst_theme.cpp,
    // hoverIsVisibleButNotASelection().
    const int hoverAlpha = oled ? kOledHoverAlpha : s.hoverAlpha;
    m.insert(QStringLiteral("hoverFill"),
             s.dark ? QColor(255, 255, 255, hoverAlpha)
                    : QColor(0, 0, 0, hoverAlpha));

    m.insert(QStringLiteral("red"),     red);
    m.insert(QStringLiteral("redSoft"), withAlpha(red, 0.12));
    m.insert(QStringLiteral("redInk"),   QColor(QString::fromLatin1(s.redInk)));
    m.insert(QStringLiteral("green"),   QColor(QString::fromLatin1(s.green)));
    // Pairs with accentWash. The two audio-quality badges were filled with a
    // hardcoded #1a4a7a / #1a4a3a, which are dark chips that vanish into a
    // light theme; a wash over whatever surface they sit on works in both.
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

// Sea with the pure-black switch on and the greys neutral, which is byte for
// byte what the user was running when Deep was still a palette of its own: the
// neutral dark ramp is Sea's old one, and Deep was that pulled to black.
QString defaultTheme()     { return QStringLiteral("sea"); }
bool    defaultOledBlack() { return true; }
bool    defaultTintedGreys() { return false; }

// The colour switch has no entry here and needs none: no theme name implies
// it. What a settings file written before it existed says about the greys is
// nothing, and nothing resolves to defaultTintedGreys() - the neutral state,
// which is also the state those files were painting, because the grounds in
// kSpecs only gained their tint in this release. Prefs writes the resolved
// value back alongside the renamed theme, so the palette an old install comes
// back to cannot move later if the default ever does.
bool migrated(const QString &stored, QString *theme, bool *oledBlack) {
    // The rename, kept in this file rather than in Prefs because kSpecs above
    // is what these old names are being migrated *to*: rename a palette up
    // there and this is the table that has to gain a row, and nothing in the
    // compiler will say so. A rename carries no change of look, so the
    // pure-black switch is left exactly as the user had it.
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

    // "deep" is the one key that is not a rename: it was a palette in its own
    // right, the blue dark one with its grounds already pulled to black,
    // before that treatment became a switch. It lands on "sea" with the switch
    // forced on, which is byte for byte what it painted.
    if (stored != QLatin1String("deep")) return false;
    if (theme)     *theme     = QStringLiteral("sea");
    if (oledBlack) *oledBlack = true;
    return true;
}

QVariantMap palette(const QString &name, bool oledBlack, bool tintedGreys) {
    // Four tables, built once each: the two ramps, each as written and with the
    // grounds pulled down. Building on demand instead would re-run both
    // transforms on every repaint, and ThemePalette compares the whole map to
    // decide whether to emit currentChanged().
    static const std::array<QHash<QString, QVariantMap>, 4> tables = [] {
        std::array<QHash<QString, QVariantMap>, 4> out;
        for (const Spec &s : kSpecs) {
            const QString key = QString::fromLatin1(s.name);
            for (const bool tinted : {false, true}) {
                out[slot(false, tinted)].insert(key, build(s, false, tinted));
                // Light themes have no black variant, so they are absent from
                // the two black tables and the lookup below falls back to the
                // plain one. That is the whole of "the switch does nothing on
                // Sky". The colour switch, by contrast, is offered on all six.
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
        // An unknown name falls back to the default palette, and the default
        // palette is a dark one, so it gets the transform too.
        if (!plain.contains(name)) return black.value(defaultTheme());
    }
    const auto it = plain.constFind(name);
    return it != plain.cend() ? *it : plain.value(defaultTheme());
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
        // Connect by meta-object rather than to Prefs::themeChanged, so a test
        // double works here without the palette knowing the concrete type.
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
    // Read live, not cached: in the neutral state every swatch shows the same
    // two grounds and six different accents, and that is what the user is
    // choosing between there, so a grid still drawn in the tinted grounds after
    // the colour switch flipped would be the picker lying about what it is
    // about to paint. SettingsPanel.qml keeps a dependency on prefs.tintedGreys
    // in the binding that calls this, so the call happens again on a flip.
    const bool tinted = m_source ? m_source->property("tintedGreys").toBool()
                                 : theme::defaultTintedGreys();
    QVariantList out;
    for (const auto &t : theme::themes()) {
        // The three a swatch draws come from here rather than from a table in
        // the QML. SettingsPanel.qml used to repeat them by hand and its own
        // comment admitted the columns had "sat two accent revisions behind
        // the C++ for a while and nothing noticed"; the palette edit that
        // separated Sand from Clay drifted them again the same day. A hand
        // copy of a table that changes is a bug with a delay on it, so there
        // is no longer a copy to drift.
        // The pure-black switch is deliberately not applied here: it has its
        // own row in the panel, and a swatch strip where three of the six were
        // the same black rectangle would say less than this one does.
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
