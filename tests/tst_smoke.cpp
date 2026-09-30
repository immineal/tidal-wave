// Placeholder QTest for the tst_core target — copy this file as the pattern for
// real C++ tests.
//
// Anything in the tidalwave_qml library is linkable here (Auth, TidalApi,
// TidalClient, Player, Downloader, TidalBridge, the cast backend on Linux), and
// headers resolve with the same short include paths the app uses, e.g.
//   #include "api/Auth.h"   or   #include "Auth.h"
// tests/TestStubs.h is available too if a test needs the QML context doubles.
//
// Add more test files to the tst_core target in tests/CMakeLists.txt; each
// QTEST_*_MAIN macro is its own main(), so one class per binary — either extend
// this class, or add a new target next to it.

#include <QtTest/QtTest>

class TestPlaceholder : public QObject {
    Q_OBJECT

private slots:
    // Runs once before the first test function.
    void initTestCase() {}

    void placeholder() {
        QVERIFY(true);
    }

    // Runs once after the last test function.
    void cleanupTestCase() {}
};

// QTEST_GUILESS_MAIN: no QGuiApplication, so this stays a plain console test.
// Switch to QTEST_MAIN if a test ever needs widgets or a QML engine.
QTEST_GUILESS_MAIN(TestPlaceholder)
#include "tst_smoke.moc"
