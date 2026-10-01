#include "Prefs.h"
#include "ThemePalette.h"
#include <QCoreApplication>
#include <algorithm>

namespace {
constexpr auto kTheme    = "ui/theme";
constexpr auto kOled     = "ui/oledBlack";
constexpr auto kTinted   = "ui/tintedGreys";
constexpr auto kLanguage = "ui/language";
constexpr auto kSidebar  = "ui/sidebarWidth";
constexpr auto kAudioDev = "audio/outputDevice";
constexpr auto kSoftRender = "ui/softwareRendering";
constexpr auto kUiScale    = "ui/scaleFactor";
constexpr auto kQuitOnClose = "ui/quitOnClose";
}

Prefs::Prefs(QObject *parent)
    : QObject(parent)
    // The default comes from the palette table rather than a second copy of
    // the name here, so the two cannot disagree about which theme ships.
    , m_theme(m_settings.value(kTheme, theme::defaultTheme()).toString())
    , m_oledBlack(m_settings.value(kOled, theme::defaultOledBlack()).toBool())
    // The migration story for this one is the absence of a key: a settings file
    // written before the colour switch existed says nothing about the greys, and
    // nothing resolves to the default, which is the neutral ramp - and the
    // neutral ramp is also roughly what those builds painted, because the
    // grounds in kSpecs only gained their tint in this release. A key holding
    // something that is not a bool at all lands there too, rather than on
    // garbage: QVariant::toBool() of nonsense is false.
    , m_tintedGreys(m_settings.value(kTinted, theme::defaultTintedGreys()).toBool())
    , m_language(m_settings.value(kLanguage, QStringLiteral("system")).toString())
    , m_sidebarWidth(m_settings.value(kSidebar, 220).toInt())
    , m_audioDevice(m_settings.value(kAudioDev).toString())
    , m_softwareRendering(m_settings.value(kSoftRender, false).toBool())
    , m_uiScale(m_settings.value(kUiScale, 0.0).toDouble())
    , m_quitOnClose(m_settings.value(kQuitOnClose, false).toBool())
{
    // A width written by a future build, or a corrupted settings file, must not
    // leave the sidebar unusable.
    m_sidebarWidth = std::clamp(m_sidebarWidth, minSidebarWidth, maxSidebarWidth);

    // A theme name the last build wrote and this one does not know: the six
    // names from before the rename, and "deep", which was a palette of its own
    // and maps onto the pure-black switch. Either way the app comes back
    // looking exactly as it was left rather than falling through to the
    // default. Written back immediately: leaving the old name in the file would
    // make the migration run again every launch and quietly undo a later change
    // of mind about the switch.
    if (theme::migrated(m_theme, &m_theme, &m_oledBlack)) {
        m_settings.setValue(kTheme, m_theme);
        m_settings.setValue(kOled, m_oledBlack);
        // The resolved colour state goes down as well, even though nothing
        // migrates it. "Deep" promises a particular set of pixels - Sea's old
        // grounds pulled to black, which is the neutral ramp in black - and
        // leaving that to a default would let a later change to what a fresh
        // install gets move an old user's palette out from under them.
        m_settings.setValue(kTinted, m_tintedGreys);
    }
}

void Prefs::setTheme(const QString &v) {
    if (v.isEmpty() || v == m_theme) return;
    m_theme = v;
    m_settings.setValue(kTheme, v);
    emit themeChanged();
}

void Prefs::setOledBlack(bool v) {
    if (v == m_oledBlack) return;
    m_oledBlack = v;
    m_settings.setValue(kOled, v);
    emit oledBlackChanged();
}

void Prefs::setTintedGreys(bool v) {
    if (v == m_tintedGreys) return;
    m_tintedGreys = v;
    m_settings.setValue(kTinted, v);
    emit tintedGreysChanged();
}

void Prefs::setLanguage(const QString &v) {
    if (v != QLatin1String("system") && v != QLatin1String("en") && v != QLatin1String("de")) return;
    if (v == m_language) return;
    m_language = v;
    m_settings.setValue(kLanguage, v);
    emit languageChanged();
}

void Prefs::setSidebarWidth(int v) {
    const int clamped = std::clamp(v, minSidebarWidth, maxSidebarWidth);
    if (clamped == m_sidebarWidth) return;
    m_sidebarWidth = clamped;
    m_settings.setValue(kSidebar, clamped);
    emit sidebarWidthChanged();
}

void Prefs::setAudioDevice(const QString &v) {
    if (v == m_audioDevice) return;
    m_audioDevice = v;
    m_settings.setValue(kAudioDev, v);
    emit audioDeviceChanged();
}

void Prefs::setSoftwareRendering(bool v) {
    if (v == m_softwareRendering) return;
    m_softwareRendering = v;
    m_settings.setValue(kSoftRender, v);
    emit softwareRenderingChanged();
}

void Prefs::setUiScale(double v) {
    // +1 on both sides: qFuzzyCompare is documented as unusable when either
    // operand is zero, and zero is Auto - the value this property spends most
    // of its life holding.
    if (qFuzzyCompare(v + 1.0, m_uiScale + 1.0)) return;
    m_uiScale = v;
    m_settings.setValue(kUiScale, v);
    emit uiScaleChanged();
}

void Prefs::setQuitOnClose(bool v) {
    if (v == m_quitOnClose) return;
    m_quitOnClose = v;
    m_settings.setValue(kQuitOnClose, v);
    emit quitOnCloseChanged();
}

QString Prefs::appVersion() const {
    return QCoreApplication::applicationVersion();
}
