#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QTranslator>

class QQmlEngine;
class Prefs;

// Installs the right QTranslator for Prefs::language and retranslates the live
// QML tree, so switching language takes effect without a restart.
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
};
