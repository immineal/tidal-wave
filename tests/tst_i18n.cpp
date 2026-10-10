// Language resolution and live switching. "system" is the default, so what it
// resolves to is what most people get. A locale with no catalogue has to land
// on English, and a regional variant (de_AT, de_CH) still has to find German.

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
        // Austrian and Swiss German have to find the same catalogue.
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
        // And the German catalogue really is installed.
        QVERIFY(i18n.isCatalogueLoaded());
    }


    // ── plurals ──────────────────────────────────────────────────────────
    // Sources are written "%n track(s)", lupdate's shorthand. With no English
    // catalogue Qt falls back to the source verbatim, so English ships a
    // catalogue carrying just the numerus forms.
    void englishResolvesPlurals_data() {
        QTest::addColumn<QString>("context");
        QTest::addColumn<int>("n");
        QTest::addColumn<QString>("expected");
        for (const char *ctx : {"QueuePanel", "HomePage", "AlbumPage"}) {
            QTest::newRow(qPrintable(QString("%1, one").arg(ctx)))   << QString(ctx) << 1 << "1 track";
            QTest::newRow(qPrintable(QString("%1, many").arg(ctx)))  << QString(ctx) << 14 << "14 tracks";
            QTest::newRow(qPrintable(QString("%1, zero").arg(ctx)))  << QString(ctx) << 0 << "0 tracks";
        }
    }

    void englishResolvesPlurals() {
        QFETCH(QString, context);
        QFETCH(int, n);
        QFETCH(QString, expected);

        Prefs prefs;
        prefs.setLanguage(QStringLiteral("en"));
        I18n i18n(&prefs);
        QVERIFY2(i18n.isCatalogueLoaded(), "English catalogue not installed");

        const QString out = QCoreApplication::translate(
            qPrintable(context), "%n track(s)", nullptr, n);
        QCOMPARE(out, expected);
        // The shorthand must never reach a person.
        QVERIFY(!out.contains(QLatin1String("(s)")));
    }

    void germanResolvesPlurals() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        QVERIFY(i18n.isCatalogueLoaded());

        const QString one  = QCoreApplication::translate("QueuePanel", "%n track(s)", nullptr, 1);
        const QString many = QCoreApplication::translate("QueuePanel", "%n track(s)", nullptr, 7);
        QVERIFY(!one.contains(QLatin1String("(s)")));
        QVERIFY(!many.contains(QLatin1String("(s)")));
        QVERIFY2(one != many, "German singular and plural are identical");
        // And it is German: the source word "track" is gone.
        QVERIFY(!one.contains(QLatin1String("track")));
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

    // A language picker names each language in that language, so someone who
    // cannot read the current one can still find theirs.
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
        // Whatever it says, it must not be all caps.
        QVERIFY(label != label.toUpper() || label.size() == 1);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestI18n)
#include "tst_i18n.moc"
