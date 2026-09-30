#include "Prefs.h"
#include <QCoreApplication>
#include <algorithm>

namespace {
constexpr auto kTheme    = "ui/theme";
constexpr auto kLanguage = "ui/language";
constexpr auto kSidebar  = "ui/sidebarWidth";
constexpr auto kAudioDev = "audio/outputDevice";
}

Prefs::Prefs(QObject *parent)
    : QObject(parent)
    , m_theme(m_settings.value(kTheme, QStringLiteral("midnight")).toString())
    , m_language(m_settings.value(kLanguage, QStringLiteral("system")).toString())
    , m_sidebarWidth(m_settings.value(kSidebar, 220).toInt())
    , m_audioDevice(m_settings.value(kAudioDev).toString())
{
    // A width written by a future build, or a corrupted settings file, must not
    // leave the sidebar unusable.
    m_sidebarWidth = std::clamp(m_sidebarWidth, minSidebarWidth, maxSidebarWidth);
}

void Prefs::setTheme(const QString &v) {
    if (v.isEmpty() || v == m_theme) return;
    m_theme = v;
    m_settings.setValue(kTheme, v);
    emit themeChanged();
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

QString Prefs::appVersion() const {
    return QCoreApplication::applicationVersion();
}
