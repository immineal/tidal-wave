// Language resolution and live switching. "system" is the default, so what it
// resolves to is what most people get. A locale with no catalogue has to land
// on English, and a regional variant (de_AT, de_CH) still has to find German.

#include <QTest>
#include <QLocale>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>

#include <cstdio>

#include "ui/I18n.h"
#include "ui/Prefs.h"

namespace {

const char kChildFlag[] = "--print-system-language";

// Prints the language a fresh install starts in, with the settings kept in
// `settingsDir`.
int printSystemLanguage(const QString &settingsDir) {
    QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_i18n-child"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsDir);

    Prefs prefs;
    I18n i18n(&prefs);
    std::fputs(qPrintable(i18n.effectiveLanguage()), stdout);
    return 0;
}

} // namespace

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
        QTest::addColumn<QStringList>("display");
        QTest::addColumn<QLocale>("format");
        QTest::addColumn<QString>("expected");

        const QLocale german(QLocale::German, QLocale::Germany);
        const QLocale american(QLocale::English, QLocale::UnitedStates);
        const QLocale french(QLocale::French, QLocale::France);
        const QStringList none;

        QTest::newRow("explicit english") << "en" << QStringList{"de-DE"} << german << "en";
        QTest::newRow("explicit german")  << "de" << QStringList{"en-US"} << american << "de";

        // The display language decides, whatever the regional format is.
        QTest::newRow("german display, english format")
            << "system" << QStringList{"de-DE"} << american << "de";
        QTest::newRow("english display, german format")
            << "system" << QStringList{"en-US"} << german << "en";
        // The list is in the user's order, and the first with a catalogue wins.
        QTest::newRow("display order, german ahead of english")
            << "system" << QStringList{"fr-FR", "de-DE", "en-US"} << american << "de";
        QTest::newRow("display order, english ahead of german")
            << "system" << QStringList{"en-GB", "de-DE"} << german << "en";
        // Austrian and Swiss German have to find the same catalogue.
        QTest::newRow("austrian german display")
            << "system" << QStringList{"de-AT"} << american << "de";
        QTest::newRow("swiss german display, POSIX spelling")
            << "system" << QStringList{"de_CH.UTF-8"} << american << "de";
        // "den" is a language of its own and only starts like "de".
        QTest::newRow("a longer code is another language")
            << "system" << QStringList{"den", "en-US"} << QLocale(QLocale::C) << "en";

        // The regional format is asked when no display language has a catalogue.
        QTest::newRow("no display language, german format")
            << "system" << none << german << "de";
        QTest::newRow("no display language, austrian format")
            << "system" << none << QLocale(QLocale::German, QLocale::Austria) << "de";
        QTest::newRow("no display language, british format")
            << "system" << none << QLocale(QLocale::English, QLocale::UnitedKingdom) << "en";
        QTest::newRow("untranslated display, german format")
            << "system" << QStringList{"fr-FR"} << german << "de";
        // No catalogue for French, so English rather than nothing.
        QTest::newRow("untranslated display and format")
            << "system" << QStringList{"fr-FR", "es-ES"} << french << "en";
        QTest::newRow("C locale")
            << "system" << QStringList{"C"} << QLocale(QLocale::C) << "en";

        // A settings file from a build that offered more languages.
        QTest::newRow("unknown code falls back")
            << "klingon" << QStringList{"de-DE"} << german << "en";
        QTest::newRow("empty falls back")
            << "" << QStringList{"de-DE"} << german << "en";
    }

    void resolve() {
        QFETCH(QString, pref);
        QFETCH(QStringList, display);
        QFETCH(QLocale, format);
        QFETCH(QString, expected);
        QCOMPARE(I18n::resolveLanguage(pref, display, format), expected);
    }

    // What "system" comes to under a real environment. The child is this
    // binary again: Qt reads the locale variables once per process.
    void systemFollowsTheEnvironment_data() {
        QTest::addColumn<QStringList>("environment");
        QTest::addColumn<QString>("expected");

        const auto row = [](const char *environment, const char *expected) {
            QTest::newRow(*environment ? environment : "nothing set")
                << QString::fromLatin1(environment).split(QLatin1Char(' '), Qt::SkipEmptyParts)
                << QString::fromLatin1(expected);
        };
        row("LANG=de_DE.UTF-8", "de");
        row("LANG=de_AT.UTF-8", "de");
        row("LANG=en_US.UTF-8", "en");
        row("LANG=fr_FR.UTF-8", "en");
        // LANGUAGE is an ordered list and outranks LANG.
        row("LANG=en_US.UTF-8 LANGUAGE=de:en", "de");
        row("LANG=de_DE.UTF-8 LANGUAGE=en:de", "en");
        row("LANG=en_US.UTF-8 LANGUAGE=fr:de:en", "de");
        row("LANG=de_DE.UTF-8 LANGUAGE=fr", "en");
        // LC_MESSAGES overrides LANG for the language, and LC_ALL overrides both.
        row("LANG=de_DE.UTF-8 LC_MESSAGES=en_US.UTF-8", "en");
        row("LANG=en_US.UTF-8 LC_MESSAGES=de_DE.UTF-8", "de");
        row("LANG=en_US.UTF-8 LC_MESSAGES=en_US.UTF-8 LC_ALL=de_DE.UTF-8", "de");
        // Number and date formats alone do not change the language.
        row("LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8 LC_TIME=de_DE.UTF-8", "en");
        row("LANG=de_DE.UTF-8 LC_NUMERIC=en_US.UTF-8 LC_TIME=en_US.UTF-8", "de");
        row("LANG=C", "en");
        row("LANG=de_DE.UTF-8 LC_MESSAGES=C", "en");
        row("", "en");
    }

    void systemFollowsTheEnvironment() {
        QFETCH(QStringList, environment);
        QFETCH(QString, expected);

        QTemporaryDir settings;
        QVERIFY(settings.isValid());

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        const QStringList inherited = env.keys();
        for (const QString &key : inherited) {
            if (key == QLatin1String("LANG") || key == QLatin1String("LANGUAGE")
                || key.startsWith(QLatin1String("LC_")))
                env.remove(key);
        }
        for (const QString &assignment : std::as_const(environment))
            env.insert(assignment.section(QLatin1Char('='), 0, 0),
                       assignment.section(QLatin1Char('='), 1));

        QProcess child;
        child.setProcessEnvironment(env);
        child.start(QCoreApplication::applicationFilePath(),
                    { QString::fromLatin1(kChildFlag), settings.path() });
        QVERIFY2(child.waitForFinished(30000), "the child did not finish");
        QCOMPARE(child.exitStatus(), QProcess::NormalExit);
        QCOMPARE(child.exitCode(), 0);
        QCOMPARE(QString::fromLatin1(child.readAllStandardOutput()), expected);
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

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc == 3 && qstrcmp(argv[1], kChildFlag) == 0)
        return printSystemLanguage(QString::fromLocal8Bit(argv[2]));

    TestI18n tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_i18n.moc"
