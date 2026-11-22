// The app turns Qt's incremental QML garbage collector off on Qt 6.8 and
// later: it can sweep objects of a component still being built, and the main
// window then crashes now and then. tst_qml_gc_whole_heap checks the effect.

#include <QTest>
#include <QByteArray>
#include <QLibraryInfo>
#include <QVersionNumber>

#include "QtRuntimeAs.h"
#include "ui/Application.h"

namespace {

// Sets an environment variable for one scope and puts the old value back.
class ScopedEnv {
public:
    ScopedEnv(const char *name, const QByteArray &value)
        : m_name(name), m_had(qEnvironmentVariableIsSet(name)), m_old(qgetenv(name)) {
        if (value.isNull()) qunsetenv(name);
        else qputenv(name, value);
    }
    ~ScopedEnv() {
        if (m_had) qputenv(m_name, m_old);
        else qunsetenv(m_name);
    }

private:
    const char *m_name;
    bool m_had;
    QByteArray m_old;
};

} // namespace

class TstQmlGc : public QObject {
    Q_OBJECT

private slots:
    // By the Qt that runs, not the one built against: a .deb built on 6.4
    // runs on 6.8 and later too, and has the collector there.
    void the_app_turns_the_incremental_collector_off_data() { runningQts(); }
    void the_app_turns_the_incremental_collector_off() {
        QFETCH(QString, qt);
        QFETCH(bool, incremental);
        const QtRuntimeAs as(qt);
        ScopedEnv unset("QV4_GC_TIMELIMIT", QByteArray());
        Application::useWholeHeapQmlCollector();
        if (incremental)
            QCOMPARE(qgetenv("QV4_GC_TIMELIMIT"), QByteArray("0"));
        else
            QVERIFY2(!qEnvironmentVariableIsSet("QV4_GC_TIMELIMIT"),
                     "Qt before 6.8 has no incremental collector to turn off");
    }

    // Qt reads an empty value as its default step, which is the buggy one.
    void an_empty_time_limit_counts_as_unset_data() { runningQts(); }
    void an_empty_time_limit_counts_as_unset() {
        QFETCH(QString, qt);
        QFETCH(bool, incremental);
        const QtRuntimeAs as(qt);
        ScopedEnv empty("QV4_GC_TIMELIMIT", QByteArray(""));
        Application::useWholeHeapQmlCollector();
        if (incremental) QCOMPARE(qgetenv("QV4_GC_TIMELIMIT"), QByteArray("0"));
    }

    void a_time_limit_set_by_the_user_wins() {
        ScopedEnv user("QV4_GC_TIMELIMIT", "3");
        Application::useWholeHeapQmlCollector();
        QCOMPARE(qgetenv("QV4_GC_TIMELIMIT"), QByteArray("3"));
    }

private:
    static void runningQts() {
        QTest::addColumn<QString>("qt");
        QTest::addColumn<bool>("incremental");
        QTest::newRow("this Qt") << QString()
            << (QLibraryInfo::version() >= QVersionNumber(6, 8));
        QTest::newRow("Qt 6.4.2") << QStringLiteral("6.4.2")  << false;
        QTest::newRow("Qt 6.7.3") << QStringLiteral("6.7.3")  << false;
        QTest::newRow("Qt 6.8.0") << QStringLiteral("6.8.0")  << true;
        QTest::newRow("Qt 6.10.2") << QStringLiteral("6.10.2") << true;
    }
};

QTEST_MAIN(TstQmlGc)
#include "tst_qml_gc.moc"
