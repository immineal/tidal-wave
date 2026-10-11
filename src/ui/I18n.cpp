// SPDX-License-Identifier: GPL-3.0-or-later

#include "I18n.h"
#include "Prefs.h"

#include <QCoreApplication>
#include <QLibraryInfo>
#include <QLocale>
#include <QQmlEngine>

namespace {
// The source language, the one the strings are written in.
const QLatin1String kSource("en");

// The language part of a locale name: "de" for "de-AT" and "de_AT.UTF-8".
// All of it, because "den" is a different language from "de".
QString languageOf(const QString &localeName) {
    qsizetype length = 0;
    while (length < localeName.size() && localeName.at(length).isLetter()) ++length;
    return localeName.left(length).toLower();
}
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

QStringList I18n::systemDisplayLanguages() {
    // On Windows and macOS, Qt below 6.10 puts the regional format's locale
    // first in this list when the list does not contain it.
    return QLocale::system().uiLanguages();
}

QString I18n::resolveLanguage(const QString &pref, const QStringList &displayLanguages,
                              const QLocale &formatLocale) {
    const QStringList supported = supportedLanguages();
    if (supported.contains(pref)) return pref;
    if (pref != QLatin1String("system")) return kSource;

    // Catalogues are per language, so every regional variant finds the same
    // file.
    for (const QString &name : displayLanguages) {
        const QString language = languageOf(name);
        if (supported.contains(language)) return language;
    }

    const QString language = QLocale::languageToCode(formatLocale.language());
    if (supported.contains(language)) return language;
    return kSource;
}

void I18n::apply() {
    const QString next = resolveLanguage(m_prefs ? m_prefs->language() : QString(),
                                         systemDisplayLanguages(), QLocale::system());
    if (next == m_effective) return;
    m_effective = next;

    QCoreApplication *app = QCoreApplication::instance();
    if (app) {
        app->removeTranslator(&m_appTranslator);
        app->removeTranslator(&m_qtTranslator);
    }
    m_loaded = false;

    // English has a catalogue too: plural sources are written "%n track(s)"
    // and only a catalogue resolves the numerus forms. Every other string
    // falls through to the source text.
    if (m_appTranslator.load(QStringLiteral(":/i18n/tidal-wave_%1.qm").arg(next))) {
        m_loaded = true;
        if (app) app->installTranslator(&m_appTranslator);
    } else if (next != kSource) {
        qWarning("I18n: no catalogue for \"%s\"; falling back to source strings",
                 qPrintable(next));
    }

    if (next != kSource) {
        // Qt's own strings ship separately and may be absent, so a miss here
        // is not warned about.
        const QString qtDir = QLibraryInfo::path(QLibraryInfo::TranslationsPath);
        if (m_qtTranslator.load(QLocale(next), QStringLiteral("qtbase"),
                                QStringLiteral("_"), qtDir)) {
            if (app) app->installTranslator(&m_qtTranslator);
        }
    }

    // Re-evaluates every qsTr() binding in the loaded QML tree.
    if (m_engine) m_engine->retranslate();

    emit languageApplied();
}

QVariantList I18n::availableLanguages() const {
    // Only "System" is translated. A language picker names each language in
    // that language.
    return {
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("system")},
                    {QStringLiteral("label"), tr("System")}},
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("en")},
                    {QStringLiteral("label"), QStringLiteral("English")}},
        QVariantMap{{QStringLiteral("code"),  QStringLiteral("de")},
                    {QStringLiteral("label"), QStringLiteral("Deutsch")}},
    };
}
