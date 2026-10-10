// Placeholder test and the pattern for new C++ tests. Everything in
// tidalwave_qml is linkable here with the app's own include paths, and
// tests/TestStubs.h has the QML context doubles. Every tst_*.cpp becomes its
// own binary, so each file carries one QTEST main.

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
