// Every C++ method qml/ calls has to be callable from QML. A plain public
// method is invisible there: the call yields `undefined` and silently does
// nothing. This test does not use the stubs. It reads qml/ and asks the real
// meta-objects. It checks names only: a call site gives no reliable signature,
// and an arity or type mismatch already fails loudly at runtime.

#include <QTest>
#include <QMetaObject>
#include <QMetaMethod>
#include <QMetaProperty>
#include <QDirIterator>
#include <QRegularExpression>
#include <QSet>
#include <QFileInfo>

#include "ui/PinStore.h"
#include "ui/Prefs.h"
#include "ui/Shortcuts.h"
#include "api/LibraryIndex.h"
#include "api/TidalBridge.h"
#include "api/Auth.h"
#include "player/Player.h"
#include "ui/ThemePalette.h"
#include "ui/Feedback.h"

namespace {

// Everything reachable on an instance from QML: invokables, slots, signals and
// properties. A call like prefs.something() can be a property holding a
// function, so property names count as present.
QSet<QString> qmlReachableNames(const QMetaObject *mo)
{
    QSet<QString> names;
    for (int i = 0; i < mo->methodCount(); ++i) {
        const QMetaMethod m = mo->method(i);
        switch (m.methodType()) {
        case QMetaMethod::Method:
        case QMetaMethod::Slot:
        case QMetaMethod::Signal:
            names.insert(QString::fromUtf8(m.name()));
            break;
        default:
            break;
        }
    }
    for (int i = 0; i < mo->propertyCount(); ++i)
        names.insert(QString::fromUtf8(mo->property(i).name()));
    return names;
}

} // namespace

class TestQmlCppCalls : public QObject
{
    Q_OBJECT

private slots:
    // The names qml/ uses for the C++ objects, paired with the types registered
    // under them. A context property or singleton missing here goes unchecked.
    // Every row must match at least one call, so a typo cannot check nothing.
    void everyCallFromQmlIsReachable_data()
    {
        QTest::addColumn<QString>("objectName");
        QTest::addColumn<QSet<QString>>("reachable");

        QTest::newRow("pins")      << "pins"      << qmlReachableNames(&PinStore::staticMetaObject);
        QTest::newRow("library")   << "library"   << qmlReachableNames(&LibraryIndex::staticMetaObject);
        QTest::newRow("player")    << "player"    << qmlReachableNames(&Player::staticMetaObject);
        QTest::newRow("bridge")    << "bridge"    << qmlReachableNames(&TidalBridge::staticMetaObject);
        QTest::newRow("prefs")     << "prefs"     << qmlReachableNames(&Prefs::staticMetaObject);
        QTest::newRow("auth")      << "auth"      << qmlReachableNames(&Auth::staticMetaObject);
        // The C++ QML_SINGLETONs, which qml/ reaches by type name. `Theme` is
        // absent on purpose: it is qml/Theme.qml and has no C++ meta-object.
        QTest::newRow("Shortcuts")    << "Shortcuts"    << qmlReachableNames(&Shortcuts::staticMetaObject);
        QTest::newRow("ThemePalette") << "ThemePalette" << qmlReachableNames(&ThemePalette::staticMetaObject);
        QTest::newRow("Feedback")     << "Feedback"     << qmlReachableNames(&Feedback::staticMetaObject);
    }

    void everyCallFromQmlIsReachable()
    {
        QFETCH(QString, objectName);
        QFETCH(QSet<QString>, reachable);

        QVERIFY2(!reachable.isEmpty(),
                 qPrintable(QStringLiteral("%1's meta-object exposes nothing, so this "
                                           "row cannot fail and is not a test")
                                .arg(objectName)));

        // Matches `obj.name(`, a call. A plain `obj.name` is not collected: a
        // property read is legal against anything the meta-object exposes.
        const QRegularExpression call(
            QStringLiteral("\\b%1\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\(").arg(objectName));

        QStringList missing;
        int filesScanned = 0, callsSeen = 0;
        QDirIterator it(QStringLiteral(TIDALWAVE_QML_DIR),
                        QStringList{ QStringLiteral("*.qml") },
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
                continue;
            ++filesScanned;
            const QString text = QString::fromUtf8(f.readAll());
            auto m = call.globalMatch(text);
            while (m.hasNext()) {
                const QString name = m.next().captured(1);
                ++callsSeen;
                if (!reachable.contains(name))
                    missing << QStringLiteral("%1: %2.%3()")
                                   .arg(QFileInfo(path).fileName(), objectName, name);
            }
        }

        QVERIFY2(filesScanned > 0, "no .qml files were scanned");
        // A row that matches no call checks nothing, so it fails. If a type
        // really stops being called from qml/, delete its row.
        QVERIFY2(callsSeen > 0,
                 qPrintable(QStringLiteral(
                     "qml/ makes no %1.*() calls, so this row asserts nothing. "
                     "Either the name is spelled differently in qml/ than here, "
                     "or the row is stale and should be removed.")
                                .arg(objectName)));

        missing.removeDuplicates();
        QVERIFY2(missing.isEmpty(),
                 qPrintable(QStringLiteral(
                     "qml/ calls these on `%1`, but %1's type exposes no such "
                     "method, slot, signal or property - QML gets `undefined` "
                     "and the call silently does nothing (add Q_INVOKABLE):\n  %2")
                                .arg(objectName, missing.join(QStringLiteral("\n  ")))));
    }

    // Pinned by name, so the general check above cannot be weakened unnoticed.
    void pinStoreIndexOfIsInvokableFromQml()
    {
        const QSet<QString> names = qmlReachableNames(&PinStore::staticMetaObject);
        QVERIFY2(names.contains(QStringLiteral("indexOf")),
                 "PinStore::indexOf is not reachable from QML, so "
                 "SideBar.qml's endPinDrag() gets undefined for both pin "
                 "indices, its fromPin === toPin guard passes, and dragging a "
                 "pin never reorders anything");
        QVERIFY2(names.contains(QStringLiteral("move")),
                 "PinStore::move is not reachable from QML, so nothing can "
                 "commit a pin reorder");
    }

    // The stub must not be more capable than the real class: a QML test proves
    // nothing about a call the shipping class cannot answer. Extra helpers on
    // the real class are harmless.
    void theStubIsNotMoreCapableThanTheRealPinStore()
    {
        const QSet<QString> real = qmlReachableNames(&PinStore::staticMetaObject);
        // Listed by name to keep this binary independent of the stub header.
        // These are the ones SideBar.qml relies on.
        const QStringList stubExposes{
            QStringLiteral("isPinned"), QStringLiteral("pin"),
            QStringLiteral("unpin"),    QStringLiteral("toggle"),
            QStringLiteral("move"),     QStringLiteral("indexOf"),
            QStringLiteral("items"),
        };
        QStringList onlyOnTheStub;
        for (const QString &n : stubExposes)
            if (!real.contains(n))
                onlyOnTheStub << n;
        QVERIFY2(onlyOnTheStub.isEmpty(),
                 qPrintable(QStringLiteral(
                     "tests/TestStubs.h's pin store exposes these to QML and the "
                     "shipping PinStore does not, so every QML test drives "
                     "something more capable than the app: %1")
                                .arg(onlyOnTheStub.join(QStringLiteral(", ")))));
    }
};

QTEST_MAIN(TestQmlCppCalls)
#include "tst_qml_cpp_calls.moc"
