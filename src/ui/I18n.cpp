#include "I18n.h"
#include "Prefs.h"

#include <QCoreApplication>
#include <QLibraryInfo>
#include <QLocale>
#include <QQmlEngine>

namespace {
// The source language. Strings are written in it, so it needs no catalogue.
const QLatin1String kSource("en");
}

I18n::I18n(Prefs *prefs, QObject *parent) : QObject(parent), m_prefs(prefs) {
    if (m_prefs) connect(m_prefs, &Prefs::languageChanged, this, &I18n::apply);
    apply();
}

void I18n::setEngine(QQmlEngine *engine) {
    m_engine = engine;
}

QStringList I18n::supportedLanguages() {
    return {QStringLiteral("en"), QStringLiteral("de")};
}

QString I18n::resolveLanguage(const QString &pref, const QLocale &systemLocale) {
    const QStringList supported = supportedLanguages();
    if (supported.contains(pref)) return pref;
    if (pref != QLatin1String("system")) return kSource;

    // QLocale::name() is "de_AT"; the catalogues are per language, so match on
    // the language part and let every regional variant find the same file.
    const QString language = QLocale::languageToCode(systemLocale.language());
    if (supported.contains(language)) return language;

    // uiLanguages() carries the user's ordered preference list, which on Linux
    // is LANGUAGE=de:en and is richer than the single locale. Worth a look
    // before giving up.
    const QStringList uiLanguages = systemLocale.uiLanguages();
    for (const QString &tag : uiLanguages) {
        const QString base = tag.left(2).toLower();
        if (supported.contains(base)) return base;
    }
    return kSource;
}

void I18n::apply() {
    const QString next =
        resolveLanguage(m_prefs ? m_prefs->language() : QString(), QLocale::system());
    if (next == m_effective) return;
    m_effective = next;

    QCoreApplication *app = QCoreApplication::instance();
    if (app) {
        app->removeTranslator(&m_appTranslator);
        app->removeTranslator(&m_qtTranslator);
    }
    m_loaded = false;

    if (next != kSource) {
        // The catalogues are compiled into the binary by qt_add_translations()
        // under RESOURCE_PREFIX "/i18n".
        if (m_appTranslator.load(QStringLiteral(":/i18n/tidal-wave_%1.qm").arg(next))) {
            m_loaded = true;
            if (app) app->installTranslator(&m_appTranslator);
        } else {
            qWarning("I18n: no catalogue for \"%s\"; falling back to source strings",
                     qPrintable(next));
        }

        // Qt's own strings (the standard dialog buttons, QLineEdit's context
        // menu) ship separately and are absent on some installs, so a miss
        // here is not worth warning about.
        const QString qtDir = QLibraryInfo::path(QLibraryInfo::TranslationsPath);
        if (m_qtTranslator.load(QLocale(next), QStringLiteral("qtbase"),
                                QStringLiteral("_"), qtDir)) {
            if (app) app->installTranslator(&m_qtTranslator);
        }
    }

    // Re-evaluates every qsTr() binding in the loaded QML tree. Only available
    // once the engine exists; before that there is nothing live to retranslate.
    if (m_engine) m_engine->retranslate();

    emit languageApplied();
}

QVariantList I18n::availableLanguages() const {
    // Only "System" is translated. The other two are endonyms on purpose: a
    // language picker names each language in that language, so someone who
    // cannot read the current one can still find theirs.
    return {
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("system")},
                    {QStringLiteral("label"), tr("System")}},
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("en")},
                    {QStringLiteral("label"), QStringLiteral("English")}},
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("de")},
                    {QStringLiteral("label"), QStringLiteral("Deutsch")}},
    };
}
