// Prefs: persistence, clamping and the defaults a brand new install gets.
//
// Written before Prefs::softwareRendering. The defaults matter more than they
// look: they are what someone sees on first launch, before they have opened
// Settings even once.

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
        // Sea with the pure-black switch on, which is what the retired
        // "Deep" palette was. Both halves matter: the theme alone is a
        // lighter app than the user signed off on.
        QCOMPARE(p.theme(), QStringLiteral("sea"));
        QCOMPARE(p.oledBlack(), true);
        // Off: the six themes share one neutral grey ramp per mode until
        // somebody asks for the tinted grounds, which is the state the user
        // settled on as the default.
        QCOMPARE(p.tintedGreys(), false);
        QCOMPARE(p.language(), QStringLiteral("system"));
        QCOMPARE(p.audioDevice(), QString());          // follow the system
        QCOMPARE(p.softwareRendering(), false);        // GPU path by default
        // Closing the window hides it in the tray, which is what the app has
        // always done; the switch is there for the people who want otherwise.
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
    // fixed size, because nothing in LibraryFinder shrinks any more. SideBar
    // gives the finder a 12px margin on each side, and inside it the strip
    // keeps a 4px inset either end with 2px between chips, so five 30px chips
    // want 4 + 5*30 + 4*2 + 4 = 166px of finder. Drop minSidebarWidth below
    // what that needs and the fifth chip is sliced by the finder's clip.
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
            p.setTintedGreys(true);
            p.setLanguage(QStringLiteral("de"));
            p.setSidebarWidth(310);
            p.setAudioDevice(QStringLiteral("alsa_output.pci-0000_00_1f.3"));
            p.setSoftwareRendering(true);
            p.setQuitOnClose(true);
        }
        Prefs p2;
        QCOMPARE(p2.theme(), QStringLiteral("sand"));
        // Off has to survive as well as on: this one defaults to true, so a
        // setter that only ever wrote the non-default value would still pass
        // a round trip in the other direction.
        QCOMPARE(p2.oledBlack(), false);
        // This one defaults off, so on is the direction a setter that never
        // wrote anything would get wrong.
        QCOMPARE(p2.tintedGreys(), true);
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

    // The key is written out here rather than taken from Prefs.cpp, so renaming
    // it shows up as a failing test instead of quietly putting everyone who had
    // asked for a quitting close button back on minimise-to-tray.
    void quitOnCloseIsStoredUnderItsOwnKey() {
        { Prefs p; p.setQuitOnClose(true); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/quitOnClose")).toBool(), true);
        }
        Prefs p2;
        QVERIFY(p2.quitOnClose());
        // ...and back off again, which a setter that only wrote the non-default
        // value would get wrong in one direction only.
        p2.setQuitOnClose(false);
        Prefs p3;
        QVERIFY(!p3.quitOnClose());
    }

    // The key is written out rather than taken from Prefs.cpp, the same way
    // quitOnClose' is: rename it and everyone who had asked for the tinted
    // grounds silently goes back to the neutral ones.
    void tintedGreysIsStoredUnderItsOwnKey() {
        { Prefs p; p.setTintedGreys(true); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/tintedGreys")).toBool(), true);
        }
        Prefs p2;
        QVERIFY(p2.tintedGreys());
        p2.setTintedGreys(false);
        Prefs p3;
        QVERIFY(!p3.tintedGreys());
    }

    // The migration story for the colour switch, which is the whole of it: a
    // settings file written before it existed carries no key, and the default
    // behind that key is the neutral state. The file below is one a 0.4.0 beta
    // actually wrote - a theme, the pure-black switch, a language, a width -
    // and it has to come back as the app it was, with greys that are neutral
    // rather than with whatever a missing key coerces to.
    void aSettingsFileFromBeforeTheColourSwitchLandsOnNeutral() {
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
        QCOMPARE(p.tintedGreys(), false);
        QCOMPARE(p.language(), QStringLiteral("de"));
        QCOMPARE(p.sidebarWidth(), 260);
        QCOMPARE(theme::palette(p.theme(), p.oledBlack(), p.tintedGreys()),
                 theme::palette(QStringLiteral("rust"), true, false));
    }

    // ...and a key holding something that is not a bool reads exactly the way
    // the pure-black key does, because it is declared and stored the same way.
    // The INI backend hands bools back as text, so "true" comes back true -
    // and so does any other non-empty word, because that is
    // QVariant::toBool()'s rule and not a decision made in Prefs. Pinned
    // rather than papered over: a damaged file has to resolve both switches
    // the same way, and either answer is a real palette rather than garbage.
    // The case that actually happens to people - no key at all - is the one
    // above, and that one lands on neutral.
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

        QSignalSpy greys(&p, &Prefs::tintedGreysChanged);
        p.setTintedGreys(true);
        p.setTintedGreys(true);
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
        // ...and through the setter too, not only on load.
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

    // "Deep" was a teal palette whose grounds were pure black; it is now the
    // pure-black switch over whichever dark theme is picked. Someone who was
    // on it has to come back to the same app, so the stored name is rewritten
    // on load rather than falling through to the default palette, which would
    // have put them on the blue dark theme with the switch off and no idea why
    // the app got lighter.
    void storedDeepBecomesSeaInBlack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "deep"); }
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("sea"));
        QCOMPARE(p.oledBlack(), true);
        // Deep was Sea's old grounds pulled to black, and Sea's old grounds are
        // the neutral ramp, so the state that reproduces it is the neutral one
        // with the switch on. A file this old has no colour key, so that is
        // where it lands - but it is written back below rather than left to a
        // default, because the pixels are the promise, not the default.
        QCOMPARE(p.tintedGreys(), false);
        QCOMPARE(theme::palette(p.theme(), p.oledBlack(), p.tintedGreys())
                     .value("bg").value<QColor>(),
                 QColor(Qt::black));
    }

    // ...and the rewrite reaches the settings file, so it happens once rather
    // than every launch. A user who migrates and then turns the switch off
    // must not find it back on next time.
    void theDeepMigrationIsWrittenBack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "deep"); }
        { Prefs p; QCOMPARE(p.oledBlack(), true); p.setOledBlack(false); }
        {
            QSettings s;
            QCOMPARE(s.value(QStringLiteral("ui/theme")).toString(), QStringLiteral("sea"));
            // The state the migration landed on is written down as well, so a
            // later change to what a fresh install defaults to cannot move an
            // old user's palette out from under them.
            QCOMPARE(s.value(QStringLiteral("ui/tintedGreys")).toBool(), false);
        }
        Prefs p2;
        QCOMPARE(p2.theme(), QStringLiteral("sea"));
        QCOMPARE(p2.oledBlack(), false);
    }

    // The six palettes were renamed, so the same write-back has to happen for
    // a stored name that is only a word out of date. Without it the file keeps
    // the old name and every launch migrates again, which is how the switch
    // ends up back on after the user turns it off.
    void aRenamedThemeIsWrittenBack() {
        { QSettings s; s.setValue(QStringLiteral("ui/theme"), "forest"); }
        { Prefs p; QCOMPARE(p.theme(), QStringLiteral("pine")); }
        QSettings s;
        QCOMPARE(s.value(QStringLiteral("ui/theme")).toString(), QStringLiteral("pine"));
    }

    // ...and the rename must not drag the pure-black switch with it: the
    // palette is the one the user already had, so only the word changes.
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
        // Nor the colour switch: a rename moves no pixels, so somebody who had
        // asked for the tinted grounds keeps them.
        QCOMPARE(p.tintedGreys(), true);
    }

    // A theme name is free-form on the way in, because the palette table is
    // the thing that decides what is real, but a stored theme that no longer
    // exists still has to paint.
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
        // The old hardcoded string, in case anything reintroduces it.
        QVERIFY(p.appVersion() != QLatin1String("v0.1-alpha"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestPrefs)
#include "tst_prefs.moc"
