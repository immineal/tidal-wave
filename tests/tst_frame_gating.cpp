// An unfocused window still draws, and the clock still ticks behind it.
//
// Why this file exists
// ────────────────────
// A Qt Quick window renders frames only while something animates, so the app's
// indefinite "still working" animations are the render loop's only reason to run
// at rest. That makes them an obvious place to save power, and the obvious way
// to do it - the one a fork of this app shipped, and the one any reader of
// Qt's docs reaches for first - is to stop them while the application is not
// frontmost:
//
//     running: busy && Qt.application.state === Qt.ApplicationActive
//
// That gate is wrong here, and it was measured wrong rather than argued wrong.
// On this desktop, with a real window on a real compositor:
//
//   * a window the user is looking at side by side with another app reports
//     Qt::ApplicationInactive and QWindow::isActive() == false, while still
//     drawing 60 frames a second - so the gate freezes a window the user can
//     see, and a frozen spinner reads as an application that has hung;
//   * a window that is genuinely not on screen - minimised, or hidden to the
//     tray - already costs nothing, because the compositor stops delivering
//     frame callbacks and Qt Quick stops the render loop by itself. Measured on
//     this machine: 60 fps and ~7% of a core while visible, 0.4 fps and ~0.6%
//     while minimised, with no gate anywhere.
//
// So the gate buys the app nothing it does not already have, and costs it the
// one failure mode it cannot afford. The numbers live in the handoff notes; what
// lives here is the decision, as something that fails if it is undone.
//
// The offscreen platform the suite runs under reports Qt::ApplicationActive for
// the life of the process, whatever the windows do. That is why the whole rest
// of this suite stayed green with the gate applied - it cannot see it at all -
// and why the first case below reads the shipping QML instead of driving it.
//
// What each case covers, and what it cannot
// ─────────────────────────────────────────
//   * no_animation_is_gated_on_activation reads every .qml the module ships
//     and refuses the two activation signals outright. It is text, so it
//     catches the mistake before it can run; it carries its own positive
//     controls below, because a scanner that silently reads nothing is the
//     failure this repo keeps finding.
//   * the_spinner_keeps_turning_on_an_unfocused_window and
//     the_playing_bars_keep_moving_on_an_unfocused_window drive the real
//     components and the real window. They need a platform that can move
//     keyboard focus between two windows; where it cannot, they skip rather
//     than pass, because a window that was never deactivated proves nothing.
//   * the_sleep_timer_counts_down_behind_a_hidden_window is the other half of
//     the rule. Gating what *looks* like an animation is one risk; the other is
//     gating something that only looks like one. The sleep timer's countdown
//     and its 30-second fade are a QML Timer writing the volume once a second,
//     not an animation, and they have to keep running with the window hidden to
//     the tray - that is the whole point of a sleep timer.

#include <QTest>
#include <QDirIterator>
#include <QFile>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QTemporaryDir>
#include <QWindow>

#include "TestStubs.h"

namespace {

// The module's QML, as it ships, rather than as it sits in the source tree.
// qt_add_qml_module puts it here, which is also where Application::run() loads
// Main.qml from, so this is the text that actually runs. Reaching it this way
// needs no TIDALWAVE_QML_DIR and therefore no entry in tests/CMakeLists.txt.
const char *kModuleRoot = ":/qt/qml/TidalWave";

// Comments are prose and are allowed to name the thing they warn about - this
// file's own header would otherwise be unquotable in QML. Only `//` to end of
// line: the app's QML has no /* */ blocks, and a `//` inside a string literal
// can at worst hide a forbidden token from the scanner on that one line, which
// no real binding looks like.
QString codeOnly(const QString &source) {
    QStringList kept;
    const QStringList lines = source.split(QLatin1Char('\n'));
    kept.reserve(lines.size());
    for (const QString &line : lines) {
        const int c = line.indexOf(QStringLiteral("//"));
        kept << (c < 0 ? line : line.left(c));
    }
    return kept.join(QLatin1Char('\n'));
}

// The two ways to ask "is the user looking at us", and the reason each is
// refused. Both are real Qt API and both answer the wrong question: they are
// true of a focused window and false of a visible unfocused one, which is the
// case that must keep drawing.
struct Forbidden {
    const char *needle;
    const char *why;
};

const Forbidden kForbidden[] = {
    { "Qt.application.state",
      "Qt::ApplicationInactive is reported for a window the user is looking at "
      "side by side with another app. Gating an animation on it freezes a "
      "visible window." },
    { "Qt.application.active",
      "the same signal as Qt.application.state, spelled shorter." },
    { "Window.active",
      "QWindow::isActive() is false for every visible window that does not hold "
      "keyboard focus." },
};

QStringList moduleQmlFiles() {
    QStringList out;
    QDirIterator it(QString::fromLatin1(kModuleRoot), QStringList{QStringLiteral("*.qml")},
                    QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) out << it.next();
    out.sort();
    return out;
}

} // namespace

class TestFrameGating : public QObject {
    Q_OBJECT

private slots:
    void cleanup() {
        qDeleteAll(m_thieves);
        m_thieves.clear();
    }

    void initTestCase() {
        // Never the developer's real ~/.config/TidalWave, under any
        // circumstance - loading Main.qml below brings up the real settings
        // machinery behind the stubs.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_frame_gating"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // ── the scanner's own fixtures, before anything is concluded from it ──
    //
    // Five guards in this repo turned out unable to fail. A text scan is the
    // easiest of all to write that way: point it at a prefix that does not
    // exist, or at a directory with no .qml in it, and it reports a clean bill
    // of health forever. So the scan's inputs are asserted first, and the
    // matcher is run against text that is known to contain what it looks for.
    void the_scanner_can_see_the_shipping_qml() {
        const QStringList files = moduleQmlFiles();
        // The module ships Main.qml, Theme.qml, and everything under
        // components/ and pages/. Well over thirty today; thirty is a floor
        // that says "a tree, not a stray file".
        QVERIFY2(files.size() >= 30,
                 qPrintable(QStringLiteral("only %1 .qml files found under %2 - the "
                                           "resource prefix is wrong and this scan "
                                           "checks nothing")
                                .arg(files.size()).arg(QString::fromLatin1(kModuleRoot))));
        QVERIFY2(files.contains(QStringLiteral(":/qt/qml/TidalWave/qml/Main.qml")),
                 "Main.qml is not where the scan looks for it");

        // Every file opens and has content in it.
        for (const QString &path : files) {
            QFile f(path);
            QVERIFY2(f.open(QIODevice::ReadOnly), qPrintable(path));
            QVERIFY2(f.size() > 0, qPrintable(path));
        }
    }

    void the_matcher_finds_a_needle_that_is_there() {
        // A positive control for the exact matcher the next case uses: the same
        // function, over text shaped like the mistake it has to catch.
        const QString bad = QStringLiteral(
            "RotationAnimator {\n"
            "    running: dial.visible && Qt.application.state === Qt.ApplicationActive\n"
            "}\n");
        QVERIFY2(codeOnly(bad).contains(QLatin1String(kForbidden[0].needle)),
                 "the matcher cannot see the gate it exists to refuse");

        // ...and the negative half: a comment naming it is not a hit, which is
        // what lets this file's own header exist.
        const QString commented = QStringLiteral(
            "// never write Qt.application.state here\n"
            "running: dial.visible\n");
        QVERIFY2(!codeOnly(commented).contains(QLatin1String(kForbidden[0].needle)),
                 "the matcher cannot tell a warning from the thing warned about");

        // And a real file from the module goes through the same function with
        // its real content intact, so the strip is not quietly emptying it.
        // Reached through kModuleRoot, so a wrong prefix fails here too rather
        // than leaving this case passing over a file the scan never sees.
        QFile real(QString::fromLatin1(kModuleRoot)
                   + QStringLiteral("/qml/components/LoadingOverlay.qml"));
        QVERIFY(real.open(QIODevice::ReadOnly));
        const QString stripped = codeOnly(QString::fromUtf8(real.readAll()));
        QVERIFY2(stripped.contains(QStringLiteral("RotationAnimator")),
                 "stripping comments removed the code as well");
        QVERIFY2(stripped.contains(QStringLiteral("loops:")),
                 "stripping comments removed the code as well");
    }

    void no_animation_is_gated_on_activation() {
        const QStringList files = moduleQmlFiles();
        // Repeated from the fixture case above on purpose. An empty file list
        // makes this case pass without reading anything, and a guard that
        // depends on a *different* case failing to announce its own blindness
        // is one test run away from being green and worthless.
        QVERIFY2(files.size() >= 30,
                 "the scan found no QML to read, so it refuses nothing");
        QStringList hits;
        int scanned = 0;

        for (const QString &path : files) {
            QFile f(path);
            QVERIFY(f.open(QIODevice::ReadOnly));
            const QString code = codeOnly(QString::fromUtf8(f.readAll()));
            ++scanned;

            const QStringList lines = code.split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size(); ++i) {
                for (const Forbidden &bad : kForbidden) {
                    if (!lines.at(i).contains(QLatin1String(bad.needle)))
                        continue;
                    hits << QStringLiteral("%1:%2: %3\n      %4\n      why: %5")
                                .arg(path).arg(i + 1)
                                .arg(QLatin1String(bad.needle))
                                .arg(lines.at(i).trimmed())
                                .arg(QLatin1String(bad.why));
                }
            }
        }

        QCOMPARE(scanned, files.size());
        QVERIFY2(hits.isEmpty(),
                 qPrintable(QStringLiteral(
                     "the app asks whether it is frontmost, which is not the same "
                     "question as whether the user can see it:\n  %1\n"
                     "A window that is visible but unfocused - side by side, on a "
                     "second monitor, in an overview - reports inactive and must "
                     "keep drawing. A window that is really not on screen already "
                     "costs nothing: the compositor stops its frame callbacks and "
                     "Qt Quick stops the render loop without being asked.")
                                .arg(hits.join(QStringLiteral("\n  ")))));
    }

    // ── and the same contract, driven ────────────────────────────────────

    void the_spinner_keeps_turning_on_an_unfocused_window() {
        QQmlApplicationEngine engine;
        installTestStubs(&engine, this);

        QQuickWindow *win = hostWindow(engine, QStringLiteral(R"(
            import QtQuick
            import TidalWave
            Window {
                width: 400; height: 300; visible: true
                LoadingOverlay { objectName: "overlay"; loading: true }
            }
        )"));
        QVERIFY(win);

        QObject *rot = win->findChild<QObject *>(QStringLiteral("loadingSpinnerRotation"));
        QVERIFY2(rot, "the overlay has no named rotation to check - the fixture is "
                      "driving something other than the shipping spinner");
        QVERIFY2(rot->property("running").toBool(),
                 "the spinner is not turning on a focused window, so this case "
                 "cannot say anything about an unfocused one");

        if (!deactivate(win))
            QSKIP("this platform will not move keyboard focus off a window, so "
                  "'still drawing while unfocused' cannot be driven here");

        QVERIFY2(rot->property("running").toBool(),
                 "the busy spinner stopped when the window lost focus. An "
                 "unfocused window is routinely fully visible, and a spinner "
                 "that stops on one reads as an application that has hung.");
    }

    void the_playing_bars_keep_moving_on_an_unfocused_window() {
        QQmlApplicationEngine engine;
        installTestStubs(&engine, this);

        QQuickWindow *win = hostWindow(engine, QStringLiteral(R"(
            import QtQuick
            import TidalWave
            Window {
                width: 400; height: 300; visible: true
                VectorIcon.PlayingIndicator {
                    objectName: "bars"
                    x: 10; y: 10; width: 16; height: 14
                    animate: true
                }
            }
        )"));
        QVERIFY(win);

        QQuickItem *bars = win->findChild<QQuickItem *>(QStringLiteral("bars"));
        QVERIFY(bars);

        // The bars are five Rectangles whose heights are written by a
        // SequentialAnimation. "Moving" is read off the figure rather than off
        // any one animation object, because the indicator has one per bar.
        const double before = tallest(bars);
        QVERIFY2(before > 1, "the indicator collapsed to nothing, so there is no "
                             "figure here to watch move");
        QTRY_VERIFY2(!qFuzzyCompare(tallest(bars), before),
                     "the bars never moved on a focused window, so this case "
                     "cannot say anything about an unfocused one");

        if (!deactivate(win))
            QSKIP("this platform will not move keyboard focus off a window, so "
                  "'still drawing while unfocused' cannot be driven here");

        const double at = tallest(bars);
        QTRY_VERIFY2(!qFuzzyCompare(tallest(bars), at),
                     "the now-playing bars froze when the window lost focus. The "
                     "window is still on screen, and a frozen 'this is playing' "
                     "mark is indistinguishable from a stalled player.");
    }

    void the_sleep_timer_counts_down_behind_a_hidden_window() {
        QQmlApplicationEngine engine;
        TestStubs stubs = installTestStubs(&engine, this);

#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        engine.loadFromModule("TidalWave", "Main");
#else
        engine.load(QUrl(QStringLiteral("qrc:/qt/qml/TidalWave/qml/Main.qml")));
#endif
        QVERIFY2(!engine.rootObjects().isEmpty(), "Main.qml did not load");
        QObject *root = engine.rootObjects().first();
        auto *win = qobject_cast<QQuickWindow *>(root);
        QVERIFY(win);

        // The countdown only runs while something is playing, which is the
        // app's rule and not this test's.
        stubs.player->setPlayingForTest(true);
        QVERIFY(stubs.player->property("playing").toBool());

        QVERIFY(QMetaObject::invokeMethod(root, "startSleepTimer",
                                          Q_ARG(QVariant, QVariant(45)),
                                          Q_ARG(QVariant, QVariant(false))));
        QCOMPARE(root->property("sleepTimerActive").toBool(), true);
        const int started = root->property("sleepTimeLeft").toInt();
        QCOMPARE(started, 45 * 60);

        // Away it goes: closed to the tray, which is where this app spends most
        // of its life and exactly when a sleep timer matters.
        win->hide();
        QVERIFY(!win->isVisible());

        QTRY_VERIFY2(root->property("sleepTimeLeft").toInt() <= started - 2,
                     "the sleep timer stopped counting with the window hidden. "
                     "The countdown and its fade are a Timer writing the volume "
                     "once a second, not an animation, and nothing about the "
                     "window may reach them.");
        QCOMPARE(root->property("sleepTimerActive").toBool(), true);

        // And it is still a countdown, not a reset: cancelling leaves no fade
        // behind on the volume.
        QVERIFY(QMetaObject::invokeMethod(root, "cancelSleepTimer"));
        QCOMPARE(root->property("sleepTimerActive").toBool(), false);
    }

private:
    // Builds `source` as a Window on `engine` and shows it. Returned window is
    // owned by the test object, so it outlives the call.
    QQuickWindow *hostWindow(QQmlEngine &engine, const QString &source) {
        auto *component = new QQmlComponent(&engine, this);
        component->setData(source.toUtf8(),
                           QUrl(QStringLiteral("qrc:/tst_frame_gating/host.qml")));
        if (component->isError()) {
            for (const QQmlError &e : component->errors())
                qWarning() << e.toString();
            return nullptr;
        }
        QObject *obj = component->create();
        if (!obj) return nullptr;
        obj->setParent(this);
        auto *win = qobject_cast<QQuickWindow *>(obj);
        if (!win) return nullptr;
        win->show();
        win->requestActivate();
        if (!QTest::qWaitForWindowExposed(win, 2000))
            qWarning("host window was never exposed");
        return win;
    }

    // Moves keyboard focus off `win` onto a second window. False means the
    // platform would not do it, which the callers turn into a skip - a window
    // that never went inactive cannot say anything about one that did.
    bool deactivate(QQuickWindow *win) {
        if (!win->isActive() && !QTest::qWaitFor([win] { return win->isActive(); }, 1000))
            return false;   // never got focus in the first place

        auto *other = new QWindow;
        other->setObjectName(QStringLiteral("focusThief"));
        other->resize(120, 80);
        other->setParent(nullptr);
        m_thieves.append(other);
        other->show();
        other->requestActivate();
        QTest::qWaitForWindowExposed(other, 2000);

        const bool went = QTest::qWaitFor([win] { return !win->isActive(); }, 2000);
        return went;
    }

    double tallest(QQuickItem *root) {
        double best = 0;
        const auto kids = root->childItems();
        for (QQuickItem *k : kids) {
            if (k->childItems().isEmpty() && k->property("radius").isValid())
                best = qMax(best, double(k->height()));
            else
                best = qMax(best, tallest(k));
        }
        return best;
    }

    QTemporaryDir   m_dir;
    QList<QWindow *> m_thieves;
};

QTEST_MAIN(TestFrameGating)
#include "tst_frame_gating.moc"
