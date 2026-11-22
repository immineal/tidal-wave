// The app's workarounds for Qt's behaviour follow the Qt that runs, which can
// be newer than the one it was built against: the .deb is built on Qt 6.4 and
// installs on 6.8 and 6.10 as well. Each case pretends to run on another Qt.

#include <QTest>
#include <QByteArray>
#include <QLibraryInfo>
#include <QQmlEngine>
#include <QVersionNumber>

#include "QtRuntimeAs.h"
#include "ui/Application.h"

namespace {

int packed(const QVersionNumber &v) {
    return QT_VERSION_CHECK(v.majorVersion(), v.minorVersion(), v.microVersion());
}

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

const QString kEmbedded = QStringLiteral("qrc:/qt/qml");

} // namespace

class TestQtRuntime : public QObject {
    Q_OBJECT

private slots:
    void theVersionIsTheLoadedQt() {
        QCOMPARE(QtRuntime::version(), packed(QLibraryInfo::version()));
        QCOMPARE(QtRuntime::version(), packed(QVersionNumber::fromString(QLatin1String(qVersion()))));
    }

    void aPretendedVersionHoldsUntilItIsDropped() {
        {
            const QtRuntimeAs as(QStringLiteral("6.4.2"));
            QCOMPARE(QtRuntime::version(), QT_VERSION_CHECK(6, 4, 2));
        }
        QCOMPARE(QtRuntime::version(), packed(QLibraryInfo::version()));
    }

    void theMediaBackendIsNamedOnQt64Only_data() {
        QTest::addColumn<QString>("qt");
        QTest::addColumn<bool>("named");
        QTest::newRow("this Qt") << QString() << (QLibraryInfo::version() < QVersionNumber(6, 5));
        QTest::newRow("Qt 6.4.2") << QStringLiteral("6.4.2") << true;
        QTest::newRow("Qt 6.5.0") << QStringLiteral("6.5.0") << false;
        QTest::newRow("Qt 6.8.2") << QStringLiteral("6.8.2") << false;
    }

    // Below 6.5 Qt picks GStreamer, from 6.5 on FFmpeg is its own default.
    void theMediaBackendIsNamedOnQt64Only() {
        QFETCH(QString, qt);
        QFETCH(bool, named);
        const QtRuntimeAs as(qt);
        ScopedEnv unset("QT_MEDIA_BACKEND", QByteArray());
        Application::preferFfmpegMediaBackend();
        if (named) QCOMPARE(qgetenv("QT_MEDIA_BACKEND"), QByteArray("ffmpeg"));
        else       QVERIFY(!qEnvironmentVariableIsSet("QT_MEDIA_BACKEND"));
    }

    void aMediaBackendTheUserNamedWins() {
        const QtRuntimeAs as(QStringLiteral("6.4.2"));
        ScopedEnv user("QT_MEDIA_BACKEND", "gstreamer");
        Application::preferFfmpegMediaBackend();
        QCOMPARE(qgetenv("QT_MEDIA_BACKEND"), QByteArray("gstreamer"));
    }

    void theEmbeddedModulesPathIsAddedOnQt64Only_data() {
        QTest::addColumn<QString>("qt");
        QTest::addColumn<bool>("added");
        QTest::newRow("Qt 6.4.2") << QStringLiteral("6.4.2") << true;
        QTest::newRow("Qt 6.5.0") << QStringLiteral("6.5.0") << false;
        QTest::newRow("Qt 6.8.2") << QStringLiteral("6.8.2") << false;
    }

    // From 6.5 on the path is Qt's own, and adding it would only put it
    // ahead of Qt's modules.
    void theEmbeddedModulesPathIsAddedOnQt64Only() {
        QFETCH(QString, qt);
        QFETCH(bool, added);
        const QtRuntimeAs as(qt);
        QQmlEngine engine;
        const QStringList before = engine.importPathList();
        Application::addEmbeddedQmlImportPath(&engine);
        const QStringList after = engine.importPathList();
        if (added) QCOMPARE(after.value(0), kEmbedded);
        else       QCOMPARE(after, before);
    }
};

QTEST_MAIN(TestQtRuntime)
#include "tst_qt_runtime.moc"
