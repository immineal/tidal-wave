// An unfocused window still draws, and the clock still ticks behind it.
// No animation may be gated on Qt.application.state or Window.active: both are
// false for a visible, unfocused window, and a hidden window already costs
// nothing because Qt Quick stops its render loop. The offscreen platform always
// reports ApplicationActive, so the first cases read the shipping QML as text.
// The driven cases skip where the platform cannot move keyboard focus.

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
#include <memory>

#include "TestStubs.h"

namespace {

// The module's QML as it ships, in the resources Application::run() loads
// Main.qml from. Needs no TIDALWAVE_QML_DIR.
const char *kModuleRoot = ":/qt/qml/TidalWave";

// Comments may name what they warn about, so they are stripped first. Only `//`
// to end of line: the app's QML has no /* */ blocks, and a `//` inside a string
// literal can at worst hide a token on that one line.
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

// The two ways to ask whether the app is frontmost. Both are true of a focused
// window and false of a visible unfocused one, which must keep drawing.
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
        // Never the real ~/.config/TidalWave: loading Main.qml below brings up
        // the real settings machinery behind the stubs.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_frame_gating"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // ── the scanner's own fixtures, before anything is concluded from it ──
    // A text scan pointed at a wrong prefix or an empty directory passes
    // forever, so its inputs are asserted first and the matcher is run against
    // text known to contain what it looks for.
    void the_scanner_can_see_the_shipping_qml() {
        const QStringList files = moduleQmlFiles();
        // The module ships well over thirty files. Thirty is a floor that tells
        // a tree from a stray file.
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

        // ...and the negative half: a comment naming it is not a hit.
        const QString commented = QStringLiteral(
            "// never write Qt.application.state here\n"
            "running: dial.visible\n");
        QVERIFY2(!codeOnly(commented).contains(QLatin1String(kForbidden[0].needle)),
                 "the matcher cannot tell a warning from the thing warned about");

        // A real file from the module goes through the same function with its
        // content intact, reached through kModuleRoot so a wrong prefix fails
        // here too.
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
        // Repeated from the fixture case on purpose: an empty file list would
        // make this case pass without reading anything.
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

        // Declared after the engine, so it is destroyed first. See hostWindow().
        const std::unique_ptr<QQuickWindow> win = hostWindow(engine, QStringLiteral(R"(
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

        if (!deactivate(win.get()))
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

        // Declared after the engine, so it is destroyed first. See hostWindow().
        const std::unique_ptr<QQuickWindow> win = hostWindow(engine, QStringLiteral(R"(
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

        if (!deactivate(win.get()))
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

        // The app's rule: the countdown only runs while something is playing.
        stubs.player->setPlayingForTest(true);
        QVERIFY(stubs.player->property("playing").toBool());

        QVERIFY(QMetaObject::invokeMethod(root, "startSleepTimer",
                                          Q_ARG(QVariant, QVariant(45)),
                                          Q_ARG(QVariant, QVariant(false))));
        QCOMPARE(root->property("sleepTimerActive").toBool(), true);
        const int started = root->property("sleepTimeLeft").toInt();
        QCOMPARE(started, 45 * 60);

        // Closed to the tray, which is when a sleep timer matters.
        win->hide();
        QVERIFY(!win->isVisible());

        QTRY_VERIFY2(root->property("sleepTimeLeft").toInt() <= started - 2,
                     "the sleep timer stopped counting with the window hidden. "
                     "The countdown and its fade are a Timer writing the volume "
                     "once a second, not an animation, and nothing about the "
                     "window may reach them.");
        QCOMPARE(root->property("sleepTimerActive").toBool(), true);

        // Cancelling still works with the window hidden.
        QVERIFY(QMetaObject::invokeMethod(root, "cancelSleepTimer"));
        QCOMPARE(root->property("sleepTimerActive").toBool(), false);
    }

private:
    // Builds `source` as a Window on `engine` and shows it. The caller owns the
    // window and must destroy it before the engine: Qt 6.4 segfaults when an
    // animation writes to an item whose engine is gone.
    std::unique_ptr<QQuickWindow> hostWindow(QQmlEngine &engine, const QString &source) {
        QQmlComponent component(&engine);
        component.setData(source.toUtf8(),
                          QUrl(QStringLiteral("qrc:/tst_frame_gating/host.qml")));
        if (component.isError()) {
            for (const QQmlError &e : component.errors())
                qWarning() << e.toString();
            return nullptr;
        }
        std::unique_ptr<QObject> obj(component.create());
        auto *win = qobject_cast<QQuickWindow *>(obj.get());
        if (!win) return nullptr;
        obj.release();
        win->show();
        win->requestActivate();
        if (!QTest::qWaitForWindowExposed(win, 2000))
            qWarning("host window was never exposed");
        return std::unique_ptr<QQuickWindow>(win);
    }

    // Moves keyboard focus off `win` onto a second window. False means the
    // platform would not do it, which the callers turn into a skip.
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
        // The result is discarded on purpose: what matters is whether `win` lost
        // focus, which the wait below asks directly.
        (void)QTest::qWaitForWindowExposed(other, 2000);

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
