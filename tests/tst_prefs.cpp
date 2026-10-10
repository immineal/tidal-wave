// Prefs: persistence, clamping and the defaults a brand new install gets.
// The defaults are what someone sees on first launch, before they have opened
// Settings.

#include <QTest>
#include <QColor>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "ui/Prefs.h"
#include "ui/ThemePalette.h"

class TestPrefs : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_prefs"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() {
        // Each test starts from an empty settings file, the way a fresh
        // install does.
        QSettings().clear();
        QSettings().sync();
    }

    // ── what a fresh install gets ────────────────────────────────────────

    void freshInstallDefaults() {
        Prefs p;
        // Sea with the pure-black switch on.
        QCOMPARE(p.theme(), QStringLiteral("sea"));
        QCOMPARE(p.oledBlack(), true);
        // Tinted greys are on by default. Switching them off gives the neutral
        // six.
        QCOMPARE(p.tintedGreys(), true);
        QCOMPARE(p.language(), QStringLiteral("system"));
        QCOMPARE(p.audioDevice(), QString());          // follow the system
        QCOMPARE(p.softwareRendering(), false);        // GPU path by default
        // Closing the window hides it in the tray by default.
        QCOMPARE(p.quitOnClose(), false);
        // The default width has to be inside the range the drag handle allows,
        // or the sidebar jumps on the first drag.
        QVERIFY(p.sidebarWidth() >= Prefs::minSidebarWidth);
        QVERIFY(p.sidebarWidth() <= Prefs::maxSidebarWidth);
        // ...and wider than the rail it replaces, or the sidebar would come up
        // narrower than its own collapsed form.
        QVERIFY(p.sidebarWidth() > Prefs::railWidth);
    }

    // The layout constants have to be consistent with each other, or the rail
    // and the expanded sidebar can both be "correct" and still overlap.
    void layoutConstantsAreCoherent() {
        QVERIFY(Prefs::railWidth < Prefs::minSidebarWidth);
        QVERIFY(Prefs::minSidebarWidth < Prefs::maxSidebarWidth);
        // A rail appears below this window width; the sidebar it replaces has
        // to fit above it with room for content beside it.
        QVERIFY(Prefs::railBreakpoint > Prefs::maxSidebarWidth);
        // The default width has to sit inside the draggable range too, or the
        // sidebar jumps the first time the handle is touched.
        QVERIFY(Prefs().sidebarWidth() >= Prefs::minSidebarWidth);
        QVERIFY(Prefs().sidebarWidth() <= Prefs::maxSidebarWidth);
    }

    // The narrowest sidebar still has to hold the five filter chips at their
    // fixed size. The numbers below mirror SideBar's margin and the strip's
    // inset and spacing, so five 30px chips want 166px of finder.
    void theNarrowestSidebarStillFitsTheFilterChips() {
        constexpr int finderMargin = 12;
        constexpr int chipInset    = 4;
        constexpr int chipSpacing  = 2;
        constexpr int chipWidth    = 30;
        constexpr int chips        = 5;

        const int needed = 2 * chipInset + chips * chipWidth + (chips - 1) * chipSpacing;
        QCOMPARE(needed, 166);
        QVERIFY2(Prefs::minSidebarWidth - 2 * finderMargin >= needed,
                 "the narrowest sidebar cannot hold five filter chips");
    }

    // ── persistence ──────────────────────────────────────────────────────

    void valuesSurviveARestart() {
        {
            Prefs p;
            p.setTheme(QStringLiteral("sand"));
            p.setOledBlack(false);
            p.setTintedGreys(false);
            p.setLanguage(QStringLiteral("de"));
            p.setSidebarWidth(310);
            p.setAudioDevice(QStringLiteral("alsa_output.pci-0000_00_1f.3"));
            p.setSoftwareRendering(true);
            p.setQuitOnClose(true);
        }
        Prefs p2;
        QCOMPARE(p2.theme(), QStringLiteral("sand"));
        // This one defaults to true, so off is the direction that needs a write.
        QCOMPARE(p2.oledBlack(), false);
        // The same for the tinted greys, which also default on.
        QCOMPARE(p2.tintedGreys(), false);
        QCOMPARE(p2.language(), QStringLiteral("de"));
        QCOMPARE(p2.sidebarWidth(), 310);
        QCOMPARE(p2.audioDevice(), QStringLiteral("alsa_output.pci-0000_00_1f.3"));
        QCOMPARE(p2.softwareRendering(), true);
        QCOMPARE(p2.quitOnClose(), true);
    }

    // Someone who needs software rendering to see anything must not lose it,
    // so it has to be read back even from a settings file that has nothing
    // else in it.
    void softwareRenderingSurvivesAlone() {
        { QSettings s; s.setValue(QStringLiteral("ui/softwareRendering"), true); }
        Prefs p;
        QVERIFY(p.softwareRendering());
    }

    // The key is written out here as a literal, so renaming it in Prefs.cpp
    // fails this test. A rename would reset everyone's close-button choice.
    void quitOnCloseIsStoredUnderItsOwnKey() {
        { Prefs p; p.setQuitOnClose(true); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/quitOnClose")).toBool(), true);
        }
        Prefs p2;
        QVERIFY(p2.quitOnClose());
        // ...and back off again.
        p2.setQuitOnClose(false);
        Prefs p3;
        QVERIFY(!p3.quitOnClose());
    }

    // The key is written out for the same reason as quitOnClose's: a rename
    // would silently put everyone back on the default.
    void tintedGreysIsStoredUnderItsOwnKey() {
        // Written away from the default first, so a setter that never wrote
        // anything cannot pass this by accident.
        { Prefs p; p.setTintedGreys(false); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/tintedGreys")).toBool(), false);
        }
        Prefs p2;
        QVERIFY(!p2.tintedGreys());
        p2.setTintedGreys(true);
        Prefs p3;
        QVERIFY(p3.tintedGreys());
    }

    // A settings file from before the colour switch carries no key for it, so
    // it takes the default, which is colour on. A file that has the key keeps
    // what it says, including an explicit false.
    void aSettingsFileFromBeforeTheColourSwitchTakesTheNewDefault() {
        {
            QSettings s;
            s.setValue(QStringLiteral("ui/theme"), "rust");
            s.setValue(QStringLiteral("ui/oledBlack"), true);
            s.setValue(QStringLiteral("ui/language"), "de");
            s.setValue(QStringLiteral("ui/sidebarWidth"), 260);
            QVERIFY(!s.contains(QStringLiteral("ui/tintedGreys")));
        }
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("rust"));
        QCOMPARE(p.oledBlack(), true);
        QCOMPARE(p.tintedGreys(), true);
        QCOMPARE(p.language(), QStringLiteral("de"));
        QCOMPARE(p.sidebarWidth(), 260);
        QCOMPARE(theme::palette(p.theme(), p.oledBlack(), p.tintedGreys()),
                 theme::palette(QStringLiteral("rust"), true, true));

        // An explicit false in the file survives the default.
        {
            QSettings s;
            s.setValue(QStringLiteral("ui/tintedGreys"), false);
        }
        Prefs kept;
        QCOMPARE(kept.tintedGreys(), false);
    }

    // A key holding something that is not a bool reads the way the pure-black
    // key does. The INI backend hands bools back as text, and QVariant::toBool()
    // takes any non-empty word but "false" and "0" as true. Both switches agree.
    void aDamagedColourKeyReadsLikeTheBlackOne() {
        for (const char *stored : {"true", "false", "1", "0", "banana", ""}) {
            {
                QSettings s;
                s.setValue(QStringLiteral("ui/tintedGreys"), QString::fromLatin1(stored));
                s.setValue(QStringLiteral("ui/oledBlack"),   QString::fromLatin1(stored));
            }
            Prefs p;
            QCOMPARE(p.tintedGreys(), p.oledBlack());
            QVERIFY(theme::palette(p.theme(), p.oledBlack(), p.tintedGreys())
                        .contains(QStringLiteral("bg")));
        }
    }

    void signalsFireOnceOnChange() {
        Prefs p;
        QSignalSpy theme(&p, &Prefs::themeChanged);
        QSignalSpy render(&p, &Prefs::softwareRenderingChanged);

        p.setTheme(QStringLiteral("rust"));
        p.setTheme(QStringLiteral("rust"));     // same value, no churn
        QCOMPARE(theme.count(), 1);

        p.setSoftwareRendering(true);
        p.setSoftwareRendering(true);
        QCOMPARE(render.count(), 1);

        QSignalSpy oled(&p, &Prefs::oledBlackChanged);
        p.setOledBlack(false);
        p.setOledBlack(false);
        QCOMPARE(oled.count(), 1);

        QSignalSpy closeQuits(&p, &Prefs::quitOnCloseChanged);
        p.setQuitOnClose(true);
        p.setQuitOnClose(true);
        QCOMPARE(closeQuits.count(), 1);

        // Away from the default, or the first set is a no-op and the spy
        // never fires at all.
        QSignalSpy greys(&p, &Prefs::tintedGreysChanged);
        p.setTintedGreys(false);
        p.setTintedGreys(false);
        QCOMPARE(greys.count(), 1);
    }

    // ── guarding against a bad settings file ─────────────────────────────

    void sidebarWidthIsClamped_data() {
        QTest::addColumn<int>("stored");
        QTest::addColumn<int>("expected");
        QTest::newRow("far too narrow") << 0   << Prefs::minSidebarWidth;
        QTest::newRow("negative")       << -40 << Prefs::minSidebarWidth;
        QTest::newRow("far too wide")   << 9000 << Prefs::maxSidebarWidth;
        QTest::newRow("in range")       << 240 << 240;
    }

    void sidebarWidthIsClamped() {
        QFETCH(int, stored);
        QFETCH(int, expected);
        { QSettings s; s.setValue(QStringLiteral("ui/sidebarWidth"), stored); }
        Prefs p;
        QCOMPARE(p.sidebarWidth(), expected);
        // ...and through the setter too.
        Prefs q;
        q.setSidebarWidth(stored);
        QCOMPARE(q.sidebarWidth(), expected);
    }

    void languageRejectsNonsense() {
        Prefs p;
        p.setLanguage(QStringLiteral("klingon"));
        QCOMPARE(p.language(), QStringLiteral("system"));   // unchanged
        p.setLanguage(QStringLiteral("de"));
        QCOMPARE(p.language(), QStringLiteral("de"));
    }

    // ── migrating off a palette that no longer exists ────────────────────

    // "Deep" was a palette whose grounds were pure black. It is now the
    // pure-black switch over a dark theme, so a stored "deep" is rewritten on
    // load to Sea with the switch on.
    void storedDeepBecomesSeaInBlack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "deep"); }
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("sea"));
        QCOMPARE(p.oledBlack(), true);
        // The colour switch follows the general rule: a file this old has no
        // colour key, so it takes the default, which is on. Pure black is the
        // same either way.
        QCOMPARE(p.tintedGreys(), true);
        QCOMPARE(theme::palette(p.theme(), p.oledBlack(), p.tintedGreys())
                     .value("bg").value<QColor>(),
                 QColor(Qt::black));
    }

    // ...and the rewrite reaches the settings file, so it happens once. A user
    // who migrates and then turns the switch off must not find it back on.
    void theDeepMigrationIsWrittenBack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "deep"); }
        { Prefs p; QCOMPARE(p.oledBlack(), true); p.setOledBlack(false); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/theme")).toString(), QStringLiteral("sea"));
            // The state the migration landed on is written down too, so a later
            // change of defaults cannot move this user's palette again.
            QCOMPARE(s.value(QStringLiteral("ui/tintedGreys")).toBool(), true);
        }
        Prefs p2;
        QCOMPARE(p2.theme(), QStringLiteral("sea"));
        QCOMPARE(p2.oledBlack(), false);
    }

    // A stored theme name from before the rename is written back as its new
    // name, so the migration runs once.
    void aRenamedThemeIsWrittenBack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "forest"); }
        { Prefs p; QCOMPARE(p.theme(), QStringLiteral("pine")); }
        QSettings s;
        QCOMPARE(s.value(QStringLiteral("ui/theme")).toString(), QStringLiteral("pine"));
    }

    // ...and the rename leaves the pure-black switch as stored.
    void aRenamedThemeLeavesTheBlackSwitchAlone() {
        {
            QSettings s;
            s.setValue(QStringLiteral("ui/theme"), "ember");
            s.setValue(QStringLiteral("ui/oledBlack"), false);
            s.setValue(QStringLiteral("ui/tintedGreys"), true);
        }
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("rust"));
        QCOMPARE(p.oledBlack(), false);
        // The colour switch is kept as stored too.
        QCOMPARE(p.tintedGreys(), true);
    }

    // A theme name is free-form on the way in, because the palette table decides
    // what is real. A stored theme that does not exist still has to paint.
    void unknownStoredThemeStillPaints() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "graphite"); }
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("graphite"));
        QVERIFY(!theme::isKnown(p.theme()));
        QVERIFY(theme::palette(p.theme()).contains(QStringLiteral("bg")));
    }

    void versionIsTheRealOne() {
        QCoreApplication::setApplicationVersion(QStringLiteral(TIDALWAVE_VERSION));
        Prefs p;
        QCOMPARE(p.appVersion(), QStringLiteral(TIDALWAVE_VERSION));
        QVERIFY(!p.appVersion().isEmpty());
        // Never the hardcoded placeholder string.
        QVERIFY(p.appVersion() != QLatin1String("v0.1-alpha"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestPrefs)
#include "tst_prefs.moc"
