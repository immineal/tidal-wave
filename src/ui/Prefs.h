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

    // One of the palette names defined in qml/Theme.qml.
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    // "system", "en" or "de".
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // Width of the expanded sidebar, in logical pixels. Clamped to
    // [minSidebarWidth, maxSidebarWidth]; the user drags the sidebar border.
    Q_PROPERTY(int sidebarWidth READ sidebarWidth WRITE setSidebarWidth NOTIFY sidebarWidthChanged)
    // Qt device id of the chosen audio output, or empty to follow the system
    // default (which is the default, and what most people want).
    Q_PROPERTY(QString audioDevice READ audioDevice WRITE setAudioDevice NOTIFY audioDeviceChanged)

public:
    explicit Prefs(QObject *parent = nullptr);

    static constexpr int minSidebarWidth = 180;
    static constexpr int maxSidebarWidth = 420;
    // Below this window width the sidebar collapses to the icon rail.
    static constexpr int railBreakpoint  = 820;
    // Width of that rail.
    static constexpr int railWidth       = 68;
    // At or above this sidebar width the filter chips can afford text labels.
    static constexpr int chipLabelWidth  = 268;

    QString theme() const        { return m_theme; }
    QString language() const     { return m_language; }
    int     sidebarWidth() const { return m_sidebarWidth; }
    QString audioDevice() const  { return m_audioDevice; }

    void setTheme(const QString &v);
    void setLanguage(const QString &v);
    void setSidebarWidth(int v);
    void setAudioDevice(const QString &v);

    // Exposed so QML can lay out against the same numbers the C++ side uses.
    Q_INVOKABLE int minSidebar() const   { return minSidebarWidth; }
    Q_INVOKABLE int maxSidebar() const   { return maxSidebarWidth; }
    Q_INVOKABLE int railBreak() const    { return railBreakpoint; }
    Q_INVOKABLE int rail() const         { return railWidth; }
    Q_INVOKABLE int chipLabelMin() const { return chipLabelWidth; }

    // PROJECT_VERSION, so the Settings panel stops claiming v0.1-alpha.
    Q_INVOKABLE QString appVersion() const;

signals:
    void themeChanged();
    void languageChanged();
    void sidebarWidthChanged();
    void audioDeviceChanged();

private:
    QSettings m_settings;
    QString   m_theme;
    QString   m_language;
    int       m_sidebarWidth;
    QString   m_audioDevice;
};
