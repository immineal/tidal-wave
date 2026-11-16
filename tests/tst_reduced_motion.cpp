// SPDX-License-Identifier: GPL-3.0-or-later

// Reduced motion: the Settings choice (system, on, off) over what the
// desktop asks for, and the choice kept across a restart.

#include <QTest>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "ui/Prefs.h"
#include "ui/ReducedMotion.h"

class TestReducedMotion : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_reduced_motion"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() {
        QSettings().clear();
        QSettings().sync();
        qunsetenv("TIDALWAVE_REDUCED_MOTION");
    }

    void theChoiceWinsOverTheSystem_data() {
        QTest::addColumn<QString>("pref");
        QTest::addColumn<bool>("system");
        QTest::addColumn<bool>("reduced");
        QTest::newRow("system, desktop asks")      << "system" << true  << true;
        QTest::newRow("system, desktop does not")  << "system" << false << false;
        QTest::newRow("on, desktop does not")      << "on"     << false << true;
        QTest::newRow("off, desktop asks")         << "off"    << true  << false;
        // A value from a newer or broken file means "follow the system".
        QTest::newRow("unknown, desktop asks")     << "maybe"  << true  << true;
    }
    void theChoiceWinsOverTheSystem() {
        QFETCH(QString, pref);
        QFETCH(bool, system);
        QFETCH(bool, reduced);
        QCOMPARE(ReducedMotion::resolve(pref, system), reduced);
    }

    // The environment override still beats both, on every platform.
    void theEnvironmentOverridesTheSystem() {
        qputenv("TIDALWAVE_REDUCED_MOTION", "1");
        QVERIFY(ReducedMotion::systemPrefers());
        qputenv("TIDALWAVE_REDUCED_MOTION", "0");
        QVERIFY(!ReducedMotion::systemPrefers());
        qunsetenv("TIDALWAVE_REDUCED_MOTION");
    }

    void thePrefDefaultsToSystemAndPersists() {
        {
            Prefs p;
            QCOMPARE(p.reducedMotion(), QStringLiteral("system"));
            QSignalSpy spy(&p, &Prefs::reducedMotionChanged);
            p.setReducedMotion(QStringLiteral("on"));
            QCOMPARE(spy.count(), 1);
            // Only the three known values are kept.
            p.setReducedMotion(QStringLiteral("sometimes"));
            QCOMPARE(p.reducedMotion(), QStringLiteral("on"));
        }
        Prefs again;
        QCOMPARE(again.reducedMotion(), QStringLiteral("on"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestReducedMotion)
#include "tst_reduced_motion.moc"
