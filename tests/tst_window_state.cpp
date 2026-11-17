// The window comes back where it was left: its size, its place, whether it
// was maximised, and the page it showed. A place on a screen that is gone is
// moved onto one that is there.

#include <QSettings>
#include <QTemporaryDir>
#include <QTest>

#include "ui/Application.h"
#include "ui/Prefs.h"

class TestWindowState : public QObject {
    Q_OBJECT

    const QList<QRect> oneScreen{ QRect(0, 0, 1920, 1080) };
    const QSize fallback{ 1280, 800 };

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_window_state"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() { QSettings().clear(); }

    void nothingSavedIsLeftToTheSystem() {
        QVERIFY(!Application::placeWindow(QRect(), oneScreen, fallback).isValid());
    }

    void aPlaceOnScreenIsKept() {
        const QRect saved(100, 80, 1400, 900);
        QCOMPARE(Application::placeWindow(saved, oneScreen, fallback), saved);
    }

    // Saved on a second monitor that is no longer plugged in.
    void aPlaceOnAScreenThatIsGoneMovesOntoOneThatIsThere() {
        const QRect saved(2200, 100, 1200, 800);
        const QRect placed = Application::placeWindow(saved, oneScreen, fallback);
        QCOMPARE(placed.size(), saved.size());
        QVERIFY2(oneScreen.first().contains(placed),
                 qPrintable(QStringLiteral("placed at %1,%2").arg(placed.x()).arg(placed.y())));
    }

    // A title bar off the top cannot be grabbed to drag the window back.
    void theTopStaysOnTheScreen() {
        const QRect placed = Application::placeWindow(QRect(300, -400, 1200, 800), oneScreen, fallback);
        QVERIFY(placed.top() >= 0);
    }

    void aWindowLargerThanTheScreenIsShrunkToIt() {
        const QRect placed = Application::placeWindow(QRect(0, 0, 3000, 2000), oneScreen, fallback);
        QVERIFY(oneScreen.first().contains(placed));
    }

    void theOtherOfTwoScreensIsKept() {
        const QList<QRect> two{ QRect(0, 0, 1920, 1080), QRect(1920, 0, 2560, 1440) };
        const QRect saved(2400, 200, 1400, 900);
        QCOMPARE(Application::placeWindow(saved, two, fallback), saved);
    }

    void theStateSurvivesARestart() {
        {
            Prefs p;
            QVERIFY(!p.windowGeometry().isValid());
            QVERIFY(!p.windowMaximized());
            QVERIFY(p.lastPage().isEmpty());
            p.setWindowGeometry(QRect(10, 20, 1100, 700));
            p.setWindowMaximized(true);
            p.setLastPage(QStringLiteral("{\"page\":\"album\",\"params\":{\"albumId\":5}}"));
        }
        Prefs again;
        QCOMPARE(again.windowGeometry(), QRect(10, 20, 1100, 700));
        QVERIFY(again.windowMaximized());
        QCOMPARE(again.lastPage(), QStringLiteral("{\"page\":\"album\",\"params\":{\"albumId\":5}}"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestWindowState)
#include "tst_window_state.moc"
