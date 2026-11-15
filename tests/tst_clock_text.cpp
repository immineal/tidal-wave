// A track's length as the rows show it: m:ss, and h:mm:ss from an hour on,
// the same reading the seek bar gives.

#include <QTest>
#include <QJsonObject>

#include "api/Models.h"
#include "api/TidalBridge.h"

class TestClockText : public QObject {
    Q_OBJECT
private slots:
    void aLengthReadsAsAClock_data() {
        QTest::addColumn<int>("seconds");
        QTest::addColumn<QString>("shown");
        QTest::newRow("none")           << 0    << QStringLiteral("0:00");
        QTest::newRow("seconds")        << 7    << QStringLiteral("0:07");
        QTest::newRow("minutes")        << 247  << QStringLiteral("4:07");
        QTest::newRow("just under 1 h") << 3599 << QStringLiteral("59:59");
        QTest::newRow("an hour")        << 3600 << QStringLiteral("1:00:00");
        QTest::newRow("over an hour")   << 4325 << QStringLiteral("1:12:05");
        QTest::newRow("ten hours")      << 36005 << QStringLiteral("10:00:05");
    }

    void aLengthReadsAsAClock() {
        QFETCH(int, seconds);
        QFETCH(QString, shown);
        Track t;
        t.id = 1;
        t.duration = seconds;
        QCOMPARE(t.durationString(), shown);
        QCOMPARE(TidalBridge::trackToMap(t).value(QStringLiteral("durationStr")).toString(), shown);
    }
};

QTEST_GUILESS_MAIN(TestClockText)
#include "tst_clock_text.moc"
