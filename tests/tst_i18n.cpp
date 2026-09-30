// Language resolution and live switching. Written before src/ui/I18n.cpp.
//
// The interesting part is "system": the setting defaults to it, so whatever it
// resolves to is what most people actually get. A locale the app has no
// catalogue for has to land on English rather than on an empty translator,
// and a regional variant (de_AT, de_CH) has to still find German.

#include <QTest>
#include <QLocale>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "ui/I18n.h"
#include "ui/Prefs.h"

class TestI18n : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_i18n"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // ── what the app ships ───────────────────────────────────────────────

    void shippedCatalogues() {
        // English is the source language, German is the one translation.
        QCOMPARE(I18n::supportedLanguages(), QStringList({"en", "de"}));
    }

    // Both .qm files have to actually be in the binary. Without this the app
    // silently runs in English and nothing says why.
    void cataloguesAreEmbedded() {
        for (const QString &lang : I18n::supportedLanguages()) {
            const QString path = QStringLiteral(":/i18n/tidal-wave_%1.qm").arg(lang);
            QVERIFY2(QFile::exists(path), qPrintable("missing resource " + path));
        }
    }

    // ── resolving the setting ────────────────────────────────────────────

    void resolve_data() {
        QTest::addColumn<QString>("pref");
        QTest::addColumn<QLocale>("system");
        QTest::addColumn<QString>("expected");

        QTest::newRow("explicit english")
            << "en" << QLocale(QLocale::German, QLocale::Germany) << "en";
        QTest::newRow("explicit german")
            << "de" << QLocale(QLocale::English, QLocale::UnitedStates) << "de";

        QTest::newRow("system, german")
            << "system" << QLocale(QLocale::German, QLocale::Germany) << "de";
        // The user's own machine is de_DE, but Austrian and Swiss German have
        // to find the same catalogue.
        QTest::newRow("system, austrian german")
            << "system" << QLocale(QLocale::German, QLocale::Austria) << "de";
        QTest::newRow("system, swiss german")
            << "system" << QLocale(QLocale::German, QLocale::Switzerland) << "de";
        QTest::newRow("system, british english")
            << "system" << QLocale(QLocale::English, QLocale::UnitedKingdom) << "en";
        // No catalogue for French, so English rather than nothing.
        QTest::newRow("system, untranslated locale")
            << "system" << QLocale(QLocale::French, QLocale::France) << "en";
        QTest::newRow("system, C locale")
            << "system" << QLocale(QLocale::C) << "en";

        // A settings file from a build that offered more languages.
        QTest::newRow("unknown code falls back")
            << "klingon" << QLocale(QLocale::German, QLocale::Germany) << "en";
        QTest::newRow("empty falls back")
            << "" << QLocale(QLocale::German, QLocale::Germany) << "en";
    }

    void resolve() {
        QFETCH(QString, pref);
        QFETCH(QLocale, system);
        QFETCH(QString, expected);
        QCOMPARE(I18n::resolveLanguage(pref, system), expected);
    }

    // ── the live object ──────────────────────────────────────────────────

    void effectiveLanguageTracksPrefs() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("en"));
        I18n i18n(&prefs);
        QCOMPARE(i18n.effectiveLanguage(), QStringLiteral("en"));

        QSignalSpy spy(&i18n, &I18n::languageApplied);
        prefs.setLanguage(QStringLiteral("de"));

        QCOMPARE(spy.count(), 1);
        QCOMPARE(i18n.effectiveLanguage(), QStringLiteral("de"));
    }

    // Setting the same language twice must not churn the translators or make
    // every binding in the app re-evaluate for nothing.
    void reapplyingIsANoOp() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);

        QSignalSpy spy(&i18n, &I18n::languageApplied);
        prefs.setLanguage(QStringLiteral("de"));
        QCOMPARE(spy.count(), 0);
    }

    // It has to work before the QML engine exists: Application constructs I18n
    // first so the tray menu and any early error string are translated too.
    void worksWithoutAnEngine() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);               // no setEngine() call
        QCOMPARE(i18n.effectiveLanguage(), QStringLiteral("de"));
        // And the German catalogue really is installed, not just recorded.
        QVERIFY(i18n.isCatalogueLoaded());
    }

    // ── the Settings picker ──────────────────────────────────────────────

    void availableLanguagesIsPickerReady() {
        Prefs prefs;
        I18n i18n(&prefs);
        const QVariantList list = i18n.availableLanguages();
        QCOMPARE(list.size(), 3);   // System, English, Deutsch

        QStringList codes;
        for (const QVariant &v : list) {
            const QVariantMap m = v.toMap();
            QVERIFY(m.contains("code"));
            QVERIFY(m.contains("label"));
            QVERIFY2(!m.value("label").toString().isEmpty(), "a language has no label");
            codes << m.value("code").toString();
        }
        QCOMPARE(codes, QStringList({"system", "en", "de"}));
    }

    // German is shown as "Deutsch", not as "German": a language picker names
    // each language in that language, so someone who cannot read the current
    // one can still find theirs.
    void languagesAreNamedInTheirOwnLanguage() {
        Prefs prefs;
        I18n i18n(&prefs);
        for (const QVariant &v : i18n.availableLanguages()) {
            const QVariantMap m = v.toMap();
            if (m.value("code") == QLatin1String("de"))
                QCOMPARE(m.value("label").toString(), QStringLiteral("Deutsch"));
            if (m.value("code") == QLatin1String("en"))
                QCOMPARE(m.value("label").toString(), QStringLiteral("English"));
        }
    }

    // Only "System" is translated; the other two are endonyms and stay put.
    void systemLabelIsTranslated() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        const QString label = i18n.availableLanguages().first().toMap().value("label").toString();
        QVERIFY(!label.isEmpty());
        // Whatever it says, it must not be all caps (project rule G1).
        QVERIFY(label != label.toUpper() || label.size() == 1);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestI18n)
#include "tst_i18n.moc"
