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
    // Paint the chosen theme in its own grounds and type instead of in the
    // neutral grey ramp its mode shares with the other two. Off by default: the
    // six palettes are one grey ramp per mode and six accents until this is
    // turned on, which is the design the user settled on. Unlike the switch
    // above it does something on all six, so Settings always shows it.
    Q_PROPERTY(bool tintedGreys READ tintedGreys WRITE setTintedGreys NOTIFY tintedGreysChanged)
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
    // The interface scale. 0 means Auto, and Auto is a real value rather than
    // the absence of one, so someone who picks 2.0 can still ask for automatic
    // behaviour back afterwards. Otherwise kMinScaleFactor..kMaxScaleFactor in
    // kScaleFactorStep increments.
    //
    // Qt reads the scale factor once, before the QApplication exists, which is
    // why Application reads this same key straight out of QSettings rather than
    // through this object, and why changing it only takes effect at next
    // launch. The Settings row says so.
    Q_PROPERTY(double uiScale READ uiScale WRITE setUiScale NOTIFY uiScaleChanged)
    // Let the window's close button end the process instead of hiding the
    // window in the tray. Off by default, which is the behaviour the app has
    // always had; with no tray icon a close quits whatever this says, because
    // there would be nothing left to click.
    Q_PROPERTY(bool quitOnClose READ quitOnClose WRITE setQuitOnClose NOTIFY quitOnCloseChanged)

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
    bool    tintedGreys() const  { return m_tintedGreys; }
    QString language() const     { return m_language; }
    int     sidebarWidth() const { return m_sidebarWidth; }
    QString audioDevice() const  { return m_audioDevice; }
    bool    softwareRendering() const { return m_softwareRendering; }
    double  uiScale() const { return m_uiScale; }
    bool    quitOnClose() const       { return m_quitOnClose; }

    void setTheme(const QString &v);
    void setOledBlack(bool v);
    void setTintedGreys(bool v);
    void setLanguage(const QString &v);
    void setSidebarWidth(int v);
    void setAudioDevice(const QString &v);
    void setSoftwareRendering(bool v);
    void setUiScale(double v);
    void setQuitOnClose(bool v);

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
    void tintedGreysChanged();
    void languageChanged();
    void sidebarWidthChanged();
    void audioDeviceChanged();
    void softwareRenderingChanged();
    void uiScaleChanged();
    void quitOnCloseChanged();

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
};
