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
constexpr auto kTrackNotifications = "ui/trackNotifications";
constexpr auto kCoverGradient = "ui/coverGradient";
constexpr auto kSpectrumBars = "ui/spectrumBars";
// The one switch for all lyrics sites before they were split.
constexpr auto kExternalLyrics = "lyrics/externalSources";
constexpr auto kLyricsLrclib = "lyrics/lrclib";
constexpr auto kLyricsOtherSites = "lyrics/otherSites";
constexpr auto kLyricsAutoSync = "lyrics/autoSync";
constexpr auto kReducedMotion = "ui/reducedMotion";
constexpr auto kNormalizeLoudness = "playback/normalizeLoudness";
constexpr auto kAutoplay = "playback/autoplay";
constexpr auto kCrossfade = "playback/crossfade";
constexpr auto kCrossfadeSeconds = "playback/crossfadeSeconds";
constexpr auto kWindowGeometry = "window/geometry";
constexpr auto kWindowMaximized = "window/maximized";
constexpr auto kLastPage = "window/lastPage";

// A choice made with the old switch holds for both new ones; written back
// at once so it is not applied again over a later change.
QSettings &migrateLyricsSwitch(QSettings &s) {
    if (s.contains(kExternalLyrics)) {
        const bool on = s.value(kExternalLyrics).toBool();
        if (!s.contains(kLyricsLrclib)) s.setValue(kLyricsLrclib, on);
        if (!s.contains(kLyricsOtherSites)) s.setValue(kLyricsOtherSites, on);
        s.remove(kExternalLyrics);
    }
    return s;
}
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
    , m_trackNotifications(m_settings.value(kTrackNotifications, false).toBool())
    // A missing key means on, the state of a fresh install.
    , m_coverGradient(m_settings.value(kCoverGradient, true).toBool())
    // Opt in: a missing key means off.
    , m_spectrumBars(m_settings.value(kSpectrumBars, false).toBool())
    , m_lyricsLrclib(migrateLyricsSwitch(m_settings).value(kLyricsLrclib, true).toBool())
    , m_lyricsOtherSites(m_settings.value(kLyricsOtherSites, false).toBool())
    , m_lyricsAutoSync(m_settings.value(kLyricsAutoSync, true).toBool())
    , m_reducedMotion(m_settings.value(kReducedMotion, QStringLiteral("system")).toString())
    // On by default, as in Tidal's and Spotify's own apps.
    , m_normalizeLoudness(m_settings.value(kNormalizeLoudness, true).toBool())
    , m_autoplay(m_settings.value(kAutoplay, false).toBool())
    , m_crossfade(m_settings.value(kCrossfade, false).toBool())
    , m_crossfadeSeconds(m_settings.value(kCrossfadeSeconds, 5).toInt())
{
    // A stored width from another build or a corrupted file is clamped.
    m_sidebarWidth = std::clamp(m_sidebarWidth, minSidebarWidth, maxSidebarWidth);
    m_crossfadeSeconds = std::clamp(m_crossfadeSeconds, minCrossfadeSeconds, maxCrossfadeSeconds);
    m_lastPage = m_settings.value(kLastPage).toString();

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

QRect Prefs::windowGeometry() const { return m_settings.value(kWindowGeometry).toRect(); }

void Prefs::setWindowGeometry(const QRect &r) {
    if (r.isValid() && r != windowGeometry()) m_settings.setValue(kWindowGeometry, r);
}

bool Prefs::windowMaximized() const { return m_settings.value(kWindowMaximized, false).toBool(); }

void Prefs::setWindowMaximized(bool v) {
    if (v != windowMaximized()) m_settings.setValue(kWindowMaximized, v);
}

void Prefs::setLastPage(const QString &v) {
    if (v == m_lastPage) return;
    m_lastPage = v;
    m_settings.setValue(kLastPage, v);
    emit lastPageChanged();
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

void Prefs::setTrackNotifications(bool v) {
    if (v == m_trackNotifications) return;
    m_trackNotifications = v;
    m_settings.setValue(kTrackNotifications, v);
    emit trackNotificationsChanged();
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

void Prefs::setLyricsLrclib(bool v) {
    if (v == m_lyricsLrclib) return;
    m_lyricsLrclib = v;
    m_settings.setValue(kLyricsLrclib, v);
    emit lyricsLrclibChanged();
}

void Prefs::setLyricsOtherSites(bool v) {
    if (v == m_lyricsOtherSites) return;
    m_lyricsOtherSites = v;
    m_settings.setValue(kLyricsOtherSites, v);
    emit lyricsOtherSitesChanged();
}

void Prefs::setLyricsAutoSync(bool v) {
    if (v == m_lyricsAutoSync) return;
    m_lyricsAutoSync = v;
    m_settings.setValue(kLyricsAutoSync, v);
    emit lyricsAutoSyncChanged();
}

void Prefs::setReducedMotion(const QString &v) {
    if (v != QLatin1String("system") && v != QLatin1String("on") && v != QLatin1String("off")) return;
    if (v == m_reducedMotion) return;
    m_reducedMotion = v;
    m_settings.setValue(kReducedMotion, v);
    emit reducedMotionChanged();
}

void Prefs::setNormalizeLoudness(bool v) {
    if (v == m_normalizeLoudness) return;
    m_normalizeLoudness = v;
    m_settings.setValue(kNormalizeLoudness, v);
    emit normalizeLoudnessChanged();
}

void Prefs::setAutoplay(bool v) {
    if (v == m_autoplay) return;
    m_autoplay = v;
    m_settings.setValue(kAutoplay, v);
    emit autoplayChanged();
}

void Prefs::setCrossfade(bool v) {
    if (v == m_crossfade) return;
    m_crossfade = v;
    m_settings.setValue(kCrossfade, v);
    emit crossfadeChanged();
}

void Prefs::setCrossfadeSeconds(int v) {
    v = std::clamp(v, minCrossfadeSeconds, maxCrossfadeSeconds);
    if (v == m_crossfadeSeconds) return;
    m_crossfadeSeconds = v;
    m_settings.setValue(kCrossfadeSeconds, v);
    emit crossfadeSecondsChanged();
}

QString Prefs::appVersion() const {
    return QCoreApplication::applicationVersion();
}
