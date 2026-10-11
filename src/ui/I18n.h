// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QStringList>
#include <QTranslator>
#include <QVariantList>

class QQmlEngine;
class QLocale;
class Prefs;

// Installs the QTranslator for Prefs::language and retranslates the live QML
// tree. Constructed before the QML engine, so the tray menu and early startup
// errors are translated; setEngine() adds live retranslation later.
class I18n : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the i18n context property")
    // The resolved language in use: "en" or "de", never "system".
    Q_PROPERTY(QString effectiveLanguage READ effectiveLanguage NOTIFY languageApplied)
public:
    explicit I18n(Prefs *prefs, QObject *parent = nullptr);

    // Must be called once the engine exists; retranslate() needs it.
    void setEngine(QQmlEngine *engine);

    QString effectiveLanguage() const { return m_effective; }

    // The catalogues that ship, source language first.
    static QStringList supportedLanguages();

    // Resolves "system" against a locale, or an explicit code. Anything
    // unrecognised, or a locale with no catalogue, gives the source language.
    static QString resolveLanguage(const QString &pref, const QLocale &systemLocale);

    // True once a .qm for the effective language is installed.
    bool isCatalogueLoaded() const { return m_loaded; }

    // The languages offered in Settings, as [{code, label}].
    Q_INVOKABLE QVariantList availableLanguages() const;

signals:
    void languageApplied();

private:
    void apply();

    Prefs      *m_prefs  = nullptr;
    // Guarded: the engine is destroyed before this object.
    QPointer<QQmlEngine> m_engine;
    QTranslator m_appTranslator;
    QTranslator m_qtTranslator;
    QString     m_effective;
    bool        m_loaded = false;
};
