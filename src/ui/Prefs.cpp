#include "Prefs.h"
#include "ThemePalette.h"
#include <QCoreApplication>
#include <algorithm>

namespace {
constexpr auto kTheme    = "ui/theme";
constexpr auto kOled     = "ui/oledBlack";
constexpr auto kLanguage = "ui/language";
constexpr auto kSidebar  = "ui/sidebarWidth";
constexpr auto kAudioDev = "audio/outputDevice";
constexpr auto kSoftRender = "ui/softwareRendering";
}

Prefs::Prefs(QObject *parent)
    : QObject(parent)
    // The default comes from the palette table rather than a second copy of
    // the name here, so the two cannot disagree about which theme ships.
    , m_theme(m_settings.value(kTheme, theme::defaultTheme()).toString())
    , m_oledBlack(m_settings.value(kOled, theme::defaultOledBlack()).toBool())
    , m_language(m_settings.value(kLanguage, QStringLiteral("system")).toString())
    , m_sidebarWidth(m_settings.value(kSidebar, 220).toInt())
    , m_audioDevice(m_settings.value(kAudioDev).toString())
    , m_softwareRendering(m_settings.value(kSoftRender, false).toBool())
{
    // A width written by a future build, or a corrupted settings file, must not
    // leave the sidebar unusable.
    m_sidebarWidth = std::clamp(m_sidebarWidth, minSidebarWidth, maxSidebarWidth);

    // A palette the last build had and this one does not. Only "deep" is on
    // that list so far, and it maps onto the pure-black switch, so the app
    // comes back looking exactly as it was left rather than a shade lighter.
    // Written back immediately: leaving the old name in the file would make
    // the migration run again every launch and quietly undo a later change of
    // mind about the switch.
    if (theme::migrated(m_theme, &m_theme, &m_oledBlack)) {
        m_settings.setValue(kTheme, m_theme);
        m_settings.setValue(kOled, m_oledBlack);
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

QString Prefs::appVersion() const {
    return QCoreApplication::applicationVersion();
}
