// SPDX-License-Identifier: GPL-3.0-or-later

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
constexpr auto kCoverGradient = "ui/coverGradient";
constexpr auto kSpectrumBars = "ui/spectrumBars";
}

Prefs::Prefs(QObject *parent)
    : QObject(parent)
    // The theme defaults come from the palette table, so there is one copy.
    , m_theme(m_settings.value(kTheme, theme::defaultTheme()).toString())
    , m_oledBlack(m_settings.value(kOled, theme::defaultOledBlack()).toBool())
    , m_tintedGreys(m_settings.value(kTinted, theme::defaultTintedGreys()).toBool())
    , m_language(m_settings.value(kLanguage, QStringLiteral("system")).toString())
    , m_sidebarWidth(m_settings.value(kSidebar, 220).toInt())
    , m_audioDevice(m_settings.value(kAudioDev).toString())
    , m_softwareRendering(m_settings.value(kSoftRender, false).toBool())
    , m_uiScale(m_settings.value(kUiScale, 0.0).toDouble())
    , m_quitOnClose(m_settings.value(kQuitOnClose, false).toBool())
    // A missing key means on, the state of a fresh install.
    , m_coverGradient(m_settings.value(kCoverGradient, true).toBool())
    // Opt in: a missing key means off.
    , m_spectrumBars(m_settings.value(kSpectrumBars, false).toBool())
{
    // A stored width from another build or a corrupted file is clamped.
    m_sidebarWidth = std::clamp(m_sidebarWidth, minSidebarWidth, maxSidebarWidth);

    // A theme name from an older build is migrated and written back at once.
    // Left in the file, the migration would run on every launch and undo a
    // later change to the pure-black switch.
    if (theme::migrated(m_theme, &m_theme, &m_oledBlack)) {
        m_settings.setValue(kTheme, m_theme);
        m_settings.setValue(kOled, m_oledBlack);
        // The resolved colour state is pinned too, so a later change of the
        // default cannot move a migrated palette.
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
    // +1 on both sides: qFuzzyCompare does not work when an operand is zero,
    // and zero is Auto.
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

void Prefs::setCoverGradient(bool v) {
    if (v == m_coverGradient) return;
    m_coverGradient = v;
    m_settings.setValue(kCoverGradient, v);
    emit coverGradientChanged();
}

void Prefs::setSpectrumBars(bool v) {
    if (v == m_spectrumBars) return;
    m_spectrumBars = v;
    m_settings.setValue(kSpectrumBars, v);
    emit spectrumBarsChanged();
}

QString Prefs::appVersion() const {
    return QCoreApplication::applicationVersion();
}
