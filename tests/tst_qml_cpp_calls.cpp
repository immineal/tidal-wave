// Every C++ method qml/ calls has to be callable from QML.
//
// Written after the third report of "the pins still don't move". The cause was
// one missing Q_INVOKABLE: SideBar.qml's endPinDrag() calls
// pins.indexOf(kind, id) to turn the row indices the gesture was made in into
// PinStore indices, and PinStore::indexOf was a plain public C++ method. QML
// cannot see those, so both lookups came back `undefined`, the
// `fromPin === toPin` guard passed on `undefined === undefined`, and the
// function returned before pins.move(). The drop indicator was always correct,
// which is why two rounds of fixing the *geometry* found real bugs and changed
// nothing the user could see.
//
// It survived two fixes and a full QML suite because tests/TestStubs.h declares
// its own indexOf as Q_INVOKABLE. Every QML test therefore drove a stub that
// was strictly more capable than the shipping class: the call worked in the
// tests and only in the tests. No fixture in the repo could express the bug,
// which is the same shape as the three other fixture defects found this week.
//
// So this test deliberately does not use the stubs. It reads qml/ and asks the
// *real* meta-objects, which is the only place the two can be compared.
//
// It is a name check, not a signature check: moc records a method's name and
// its parameter types, and a QML call site gives neither reliably (a count at
// best, since arguments can be any expression). A name that exists at all is
// what separates "QML can reach this" from "QML gets undefined", and that is
// the failure this is here to stop. An arity or type mismatch is a different
// bug with a loud runtime error; this one is silent.

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

// Everything reachable on an instance from QML: invokables and slots (both are
// in the method table), signals, and property accessors - a QML call like
// prefs.something() can also be a property holding a function, and a property's
// own name is reachable, so they count as present rather than missing.
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
    // The names qml/ uses for our C++ objects, paired with the types actually
    // registered under them. Adding a context property or singleton without
    // adding it here means its calls go unchecked, so the list is asserted to
    // be non-empty and every entry is required to be found in at least one
    // file - a typo here would otherwise quietly check nothing.
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
        // The C++ QML_SINGLETONs, which qml/ reaches by their type name rather
        // than by a context-property name. `Theme` is deliberately absent: it
        // is qml/Theme.qml, not a C++ type, so there is no meta-object to ask.
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

        // `obj.name(` - deliberately not `obj.name` without the paren, because a
        // property read is legal against anything the meta-object exposes and a
        // call is not.
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
        // A row that checks nothing is exactly the defect this file exists to
        // catch, so it fails rather than passing quietly. The first version of
        // this test had a `shortcuts` row spelled in lower case while qml/ says
        // `Shortcuts`, so it matched nothing and passed - a vacuous green in the
        // test written to stop vacuous greens. If a type here genuinely stops
        // being called from qml/, delete its row deliberately.
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

    // The specific one that cost three rounds, pinned by name so the general
    // check above cannot be weakened without this also going red.
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

    // The stub must not be more capable than the real thing. That asymmetry is
    // what hid the bug: a QML test proves nothing about a call the shipping
    // class cannot answer. Checked in the direction that matters - extra
    // helpers on the real class are harmless, extra ones on the stub are not.
    void theStubIsNotMoreCapableThanTheRealPinStore()
    {
        const QSet<QString> real = qmlReachableNames(&PinStore::staticMetaObject);
        // The stub lives in a header the QML tests compile; naming its methods
        // here rather than including it keeps this binary independent of the
        // test-stub translation unit. These are the ones SideBar.qml relies on.
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
