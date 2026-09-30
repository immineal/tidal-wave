#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QTranslator>
#include <QVariantList>

class QQmlEngine;
class QLocale;
class Prefs;

// Installs the right QTranslator for Prefs::language and retranslates the live
// QML tree, so switching language takes effect without a restart.
//
// Constructed before the QML engine, because the tray menu and the early
// startup errors are built first and have to be translated too; setEngine()
// comes later and only adds the live-retranslate half.
class I18n : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the i18n context property")
    // Resolved language actually in use: "en" or "de" (never "system").
    Q_PROPERTY(QString effectiveLanguage READ effectiveLanguage NOTIFY languageApplied)
public:
    explicit I18n(Prefs *prefs, QObject *parent = nullptr);

    // Must be called once the engine exists; retranslate() needs it.
    void setEngine(QQmlEngine *engine);

    QString effectiveLanguage() const { return m_effective; }

    // The catalogues that ship, source language first.
    static QStringList supportedLanguages();

    // "system" against a locale, or an explicit code. Anything unrecognised,
    // including a locale with no catalogue, resolves to the source language
    // rather than to an empty translator.
    static QString resolveLanguage(const QString &pref, const QLocale &systemLocale);

    // False when the effective language is the source language (nothing to
    // load), true once a .qm is actually installed. Exists so a test can tell
    // "German is selected" from "German is selected and present".
    bool isCatalogueLoaded() const { return m_loaded; }

    // The languages offered in Settings, as [{code, label}].
    Q_INVOKABLE QVariantList availableLanguages() const;

signals:
    void languageApplied();

private:
    void apply();

    Prefs      *m_prefs  = nullptr;
    QQmlEngine *m_engine = nullptr;
    QTranslator m_appTranslator;
    QTranslator m_qtTranslator;
    QString     m_effective;
    bool        m_loaded = false;
};
