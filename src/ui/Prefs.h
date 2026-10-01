#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QString>

// Persisted application preferences, exposed to QML as the `prefs` context
// property. Everything here survives a restart via QSettings; nothing here is
// per-Tidal-account (PinStore handles what is).
class Prefs : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the prefs context property")

    // One of the palette names defined in src/ui/ThemePalette.cpp.
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    // Pull the chosen dark theme's grounds down to true black, for OLED
    // screens. On a light theme it does nothing, and Settings hides the
    // switch rather than greying it out. On by default, because the palette
    // it produces from the default theme is the one the user settled on.
    Q_PROPERTY(bool oledBlack READ oledBlack WRITE setOledBlack NOTIFY oledBlackChanged)
    // "system", "en" or "de".
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // Width of the expanded sidebar, in logical pixels. Clamped to
    // [minSidebarWidth, maxSidebarWidth]; the user drags the sidebar border.
    Q_PROPERTY(int sidebarWidth READ sidebarWidth WRITE setSidebarWidth NOTIFY sidebarWidthChanged)
    // Qt device id of the chosen audio output, or empty to follow the system
    // default (which is the default, and what most people want).
    Q_PROPERTY(QString audioDevice READ audioDevice WRITE setAudioDevice NOTIFY audioDeviceChanged)
    // Draw the interface on the CPU instead of the GPU. Off by default; Qt
    // chooses the scene graph backend once at startup, so a change only takes
    // effect on the next launch.
    Q_PROPERTY(bool softwareRendering READ softwareRendering WRITE setSoftwareRendering NOTIFY softwareRenderingChanged)

public:
    explicit Prefs(QObject *parent = nullptr);

    // 190, not a round 180: the five filter chips need 166px of finder and the
    // finder is the sidebar less 24. Narrower than this and the chips had to
    // resize during the last few pixels of a drag, which read as twitchy.
    static constexpr int minSidebarWidth = 190;
    static constexpr int maxSidebarWidth = 420;
    // Below this window width the sidebar collapses to the icon rail.
    static constexpr int railBreakpoint  = 820;
    // Width of that rail.
    static constexpr int railWidth       = 68;

    QString theme() const        { return m_theme; }
    bool    oledBlack() const    { return m_oledBlack; }
    QString language() const     { return m_language; }
    int     sidebarWidth() const { return m_sidebarWidth; }
    QString audioDevice() const  { return m_audioDevice; }
    bool    softwareRendering() const { return m_softwareRendering; }

    void setTheme(const QString &v);
    void setOledBlack(bool v);
    void setLanguage(const QString &v);
    void setSidebarWidth(int v);
    void setAudioDevice(const QString &v);
    void setSoftwareRendering(bool v);

    // Exposed so QML can lay out against the same numbers the C++ side uses.
    Q_INVOKABLE int minSidebar() const   { return minSidebarWidth; }
    Q_INVOKABLE int maxSidebar() const   { return maxSidebarWidth; }
    Q_INVOKABLE int railBreak() const    { return railBreakpoint; }
    Q_INVOKABLE int rail() const         { return railWidth; }

    // PROJECT_VERSION, so the Settings panel stops claiming v0.1-alpha.
    Q_INVOKABLE QString appVersion() const;

signals:
    void themeChanged();
    void oledBlackChanged();
    void languageChanged();
    void sidebarWidthChanged();
    void audioDeviceChanged();
    void softwareRenderingChanged();

private:
    QSettings m_settings;
    QString   m_theme;
    bool      m_oledBlack;
    QString   m_language;
    int       m_sidebarWidth;
    QString   m_audioDevice;
    bool      m_softwareRendering;
};
