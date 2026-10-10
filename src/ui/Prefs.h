// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QString>

// Persisted application preferences, exposed to QML as the `prefs` context
// property. Stored in QSettings; nothing here is per Tidal account.
class Prefs : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the prefs context property")

    // One of the palette names defined in src/ui/ThemePalette.cpp.
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    // Pulls a dark theme's grounds down to true black. Does nothing on a
    // light theme.
    Q_PROPERTY(bool oledBlack READ oledBlack WRITE setOledBlack NOTIFY oledBlackChanged)
    // Paints the theme in its own grounds and type. Off, it uses the neutral
    // grey ramp its mode shares. Applies to all six themes.
    Q_PROPERTY(bool tintedGreys READ tintedGreys WRITE setTintedGreys NOTIFY tintedGreysChanged)
    // "system", "en" or "de".
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // Width of the expanded sidebar in logical pixels, clamped to
    // [minSidebarWidth, maxSidebarWidth].
    Q_PROPERTY(int sidebarWidth READ sidebarWidth WRITE setSidebarWidth NOTIFY sidebarWidthChanged)
    // Qt device id of the chosen audio output, or empty to follow the system
    // default.
    Q_PROPERTY(QString audioDevice READ audioDevice WRITE setAudioDevice NOTIFY audioDeviceChanged)
    // Qt chooses the scene graph backend once at startup, so a change takes
    // effect on the next launch.
    Q_PROPERTY(bool softwareRendering READ softwareRendering WRITE setSoftwareRendering NOTIFY softwareRenderingChanged)
    // The interface scale. 0 means Auto, otherwise kMinScaleFactor to
    // kMaxScaleFactor. Qt reads the factor before the QApplication exists, so
    // Application reads this key from QSettings and a change needs a restart.
    Q_PROPERTY(double uiScale READ uiScale WRITE setUiScale NOTIFY uiScaleChanged)
    // The close button ends the process and does not hide to the tray. With
    // no tray icon a close quits whatever this says.
    Q_PROPERTY(bool quitOnClose READ quitOnClose WRITE setQuitOnClose NOTIFY quitOnCloseChanged)
    // The fullscreen Now Playing page tops its gradient with a colour from
    // the cover art. The colour is clamped for legibility; see CoverColor.h.
    Q_PROPERTY(bool coverGradient READ coverGradient WRITE setCoverGradient NOTIFY coverGradientChanged)
    // The now-playing bars show a coarse spectrum of the audio. Needs Qt 6.8
    // (QAudioBufferOutput); below that the switch does nothing.
    Q_PROPERTY(bool spectrumBars READ spectrumBars WRITE setSpectrumBars NOTIFY spectrumBarsChanged)

public:
    explicit Prefs(QObject *parent = nullptr);

    // The five filter chips need 166px of finder, and the finder is the
    // sidebar less 24.
    static constexpr int minSidebarWidth = 190;
    static constexpr int maxSidebarWidth = 420;
    // Below this window width the sidebar collapses to the icon rail.
    static constexpr int railBreakpoint  = 820;
    // Width of that rail.
    static constexpr int railWidth       = 68;

    QString theme() const        { return m_theme; }
    bool    oledBlack() const    { return m_oledBlack; }
    bool    tintedGreys() const  { return m_tintedGreys; }
    QString language() const     { return m_language; }
    int     sidebarWidth() const { return m_sidebarWidth; }
    QString audioDevice() const  { return m_audioDevice; }
    bool    softwareRendering() const { return m_softwareRendering; }
    double  uiScale() const { return m_uiScale; }
    bool    quitOnClose() const       { return m_quitOnClose; }
    bool    coverGradient() const     { return m_coverGradient; }
    bool    spectrumBars() const      { return m_spectrumBars; }

    void setTheme(const QString &v);
    void setOledBlack(bool v);
    void setTintedGreys(bool v);
    void setLanguage(const QString &v);
    void setSidebarWidth(int v);
    void setAudioDevice(const QString &v);
    void setSoftwareRendering(bool v);
    void setUiScale(double v);
    void setQuitOnClose(bool v);
    void setCoverGradient(bool v);
    void setSpectrumBars(bool v);

    // So QML lays out against the same numbers as the C++ side.
    Q_INVOKABLE int minSidebar() const   { return minSidebarWidth; }
    Q_INVOKABLE int maxSidebar() const   { return maxSidebarWidth; }
    Q_INVOKABLE int railBreak() const    { return railBreakpoint; }
    Q_INVOKABLE int rail() const         { return railWidth; }

    Q_INVOKABLE QString appVersion() const;

signals:
    void themeChanged();
    void oledBlackChanged();
    void tintedGreysChanged();
    void languageChanged();
    void sidebarWidthChanged();
    void audioDeviceChanged();
    void softwareRenderingChanged();
    void uiScaleChanged();
    void quitOnCloseChanged();
    void coverGradientChanged();
    void spectrumBarsChanged();

private:
    QSettings m_settings;
    QString   m_theme;
    bool      m_oledBlack;
    bool      m_tintedGreys;
    QString   m_language;
    int       m_sidebarWidth;
    QString   m_audioDevice;
    bool      m_softwareRendering;
    double    m_uiScale;
    bool      m_quitOnClose;
    bool      m_coverGradient;
    bool      m_spectrumBars;
};
