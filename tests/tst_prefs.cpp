// Prefs: persistence, clamping and the defaults a brand new install gets.
//
// Written before Prefs::softwareRendering. The defaults matter more than they
// look: they are what someone sees on first launch, before they have opened
// Settings even once.

#include <QTest>
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
        QCOMPARE(p.theme(), QStringLiteral("midnight"));
        QCOMPARE(p.language(), QStringLiteral("system"));
        QCOMPARE(p.audioDevice(), QString());          // follow the system
        QCOMPARE(p.softwareRendering(), false);        // GPU path by default
        // The default width has to be inside the range the drag handle allows,
        // or the sidebar jumps on the first drag.
        QVERIFY(p.sidebarWidth() >= Prefs::minSidebarWidth);
        QVERIFY(p.sidebarWidth() <= Prefs::maxSidebarWidth);
        // ...and wide enough that the filter chips start out with their
        // labels rather than collapsed to icons.
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
        // The chips only get labels somewhere inside the draggable range,
        // otherwise the threshold is unreachable.
        QVERIFY(Prefs::chipLabelWidth > Prefs::minSidebarWidth);
        QVERIFY(Prefs::chipLabelWidth < Prefs::maxSidebarWidth);
    }

    // ── persistence ──────────────────────────────────────────────────────

    void valuesSurviveARestart() {
        {
            Prefs p;
            p.setTheme(QStringLiteral("paper"));
            p.setLanguage(QStringLiteral("de"));
            p.setSidebarWidth(310);
            p.setAudioDevice(QStringLiteral("alsa_output.pci-0000_00_1f.3"));
            p.setSoftwareRendering(true);
        }
        Prefs p2;
        QCOMPARE(p2.theme(), QStringLiteral("paper"));
        QCOMPARE(p2.language(), QStringLiteral("de"));
        QCOMPARE(p2.sidebarWidth(), 310);
        QCOMPARE(p2.audioDevice(), QStringLiteral("alsa_output.pci-0000_00_1f.3"));
        QCOMPARE(p2.softwareRendering(), true);
    }

    // Someone who needs software rendering to see anything must not lose it,
    // so it has to be read back even from a settings file that has nothing
    // else in it.
    void softwareRenderingSurvivesAlone() {
        { QSettings s; s.setValue(QStringLiteral("ui/softwareRendering"), true); }
        Prefs p;
        QVERIFY(p.softwareRendering());
    }

    void signalsFireOnceOnChange() {
        Prefs p;
        QSignalSpy theme(&p, &Prefs::themeChanged);
        QSignalSpy render(&p, &Prefs::softwareRenderingChanged);

        p.setTheme(QStringLiteral("ember"));
        p.setTheme(QStringLiteral("ember"));     // same value, no churn
        QCOMPARE(theme.count(), 1);

        p.setSoftwareRendering(true);
        p.setSoftwareRendering(true);
        QCOMPARE(render.count(), 1);
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
