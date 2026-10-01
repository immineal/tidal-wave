// The keyboard shortcut table, and the two places that have to agree with it.
//
// There used to be no table. qml/Main.qml bound each Shortcut to a literal, and
// qml/components/SettingsPanel.qml printed a second, independent set of literals
// beside them. Two things went wrong with that and neither was visible from
// Linux:
//
//   * The printed half was simply false off Linux. Qt maps "Ctrl" in a portable
//     sequence onto the Command key on macOS, so a panel row reading "Ctrl+Q"
//     was telling a Mac user to press Command-Q, which is Quit.
//   * The queue toggle *was* Ctrl+Q, so on macOS pressing what the panel said
//     ended the process instead of opening the queue. Measured on the Mac: the
//     queue never toggled.
//
// Both halves now read src/ui/Shortcuts.cpp. The first two tests here are about
// the table itself; the last two are the ones that would have caught the drift,
// and they work by reading the two QML files as text. That is deliberate: a QML
// binding cannot be checked without instantiating the window it lives in, and
// the thing under test is whether the *source* still routes through the table,
// which reading it is the direct way to answer. TIDALWAVE_QML_DIR comes from
// tests/CMakeLists.txt.

#include <QTest>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QDirIterator>
#include <QKeySequence>
#include <QRegularExpression>
#include <QSet>
#include <QStringList>

#include "ui/Shortcuts.h"

namespace {

QString readQml(const QString &relativePath) {
    QFile f(QStringLiteral(TIDALWAVE_QML_DIR) + QLatin1Char('/') + relativePath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(f.readAll());
}

// Every capture group 1 of `pattern` in `text`, as a set.
QSet<QString> captures(const QString &text, const QString &pattern) {
    QSet<QString> out;
    QRegularExpression re(pattern);
    auto it = re.globalMatch(text);
    while (it.hasNext())
        out.insert(it.next().captured(1));
    return out;
}

QString sorted(const QSet<QString> &s) {
    QStringList l(s.cbegin(), s.cend());
    l.sort();
    return l.join(QStringLiteral(", "));
}

} // namespace

class TestShortcuts : public QObject {
    Q_OBJECT

private slots:
    // A sequence that QKeySequence cannot parse back is not a compile error and
    // not a runtime warning. It is a shortcut that silently never fires, which
    // is the hardest kind of mistake to find in this table, so every entry is
    // round-tripped through the parser it will go through at runtime.
    void everyEntryIsAParsableSequence() {
        const Shortcuts shortcuts;
        const QStringList ids = shortcuts.ids();
        QVERIFY(!ids.isEmpty());

        for (const QString &id : ids) {
            const QString seq = shortcuts.sequence(id);
            QVERIFY2(!seq.isEmpty(), qPrintable(id));

            const QKeySequence parsed(seq, QKeySequence::PortableText);
            QVERIFY2(!parsed.isEmpty(),
                     qPrintable(QStringLiteral("%1: QKeySequence cannot parse \"%2\"")
                                    .arg(id, seq)));
            // Round-trip, which is what catches a typo in a modifier: Qt parses
            // "Ctrl+Shft+J" into the single key Shft, and prints back something
            // that is not what was written.
            QCOMPARE(parsed.toString(QKeySequence::PortableText), seq);

            // And there is something to print for it, since this is what the
            // Settings panel puts in the badge.
            QVERIFY2(!shortcuts.display(id).isEmpty(), qPrintable(id));
        }

        // No two ids may share a sequence; the second one would never fire.
        QSet<QString> seen;
        for (const QString &id : ids) {
            const QString seq = shortcuts.sequence(id);
            QVERIFY2(!seen.contains(seq),
                     qPrintable(QStringLiteral("%1 reuses the sequence %2").arg(id, seq)));
            seen.insert(seq);
        }

        // An id that is not in the table answers with nothing rather than
        // guessing, because QML's Shortcut ignores an empty sequence and a typo
        // should disable one shortcut, not bind an arbitrary key.
        QVERIFY(shortcuts.sequence(QStringLiteral("noSuchShortcut")).isEmpty());
        QVERIFY(shortcuts.display(QStringLiteral("noSuchShortcut")).isEmpty());
    }

    // The regression guard for the bug that started this: nothing in the table
    // may use a sequence the system takes before the app ever sees it.
    //
    // Only the four that cost the user their session or their window are
    // refused. On macOS, where Qt maps Ctrl onto Command, Ctrl+Q is Quit,
    // Ctrl+W closes the window, Ctrl+H hides the app and Ctrl+Shift+Q logs out.
    //
    // Two collisions are known and deliberately allowed, so this test does not
    // pretend the list is clean: Ctrl+M is Minimize on macOS and F11 is Mission
    // Control's Show Desktop, so mute and fullscreen do not reach the app there.
    // Both are right on Linux, which is where the app ships, and neither
    // destroys anything - they cost a shortcut, not a session.
    void noEntryTakesASequenceTheSystemOwns() {
        const Shortcuts shortcuts;
        const QStringList reserved = {
            QStringLiteral("Ctrl+Q"),        // macOS Quit; the conventional quit on Linux too
            QStringLiteral("Ctrl+W"),        // macOS Close Window
            QStringLiteral("Ctrl+H"),        // macOS Hide
            QStringLiteral("Ctrl+Shift+Q"),  // macOS Log Out
        };

        const QStringList ids = shortcuts.ids();
        for (const QString &id : ids) {
            const QString seq = shortcuts.sequence(id);
            QVERIFY2(!reserved.contains(seq),
                     qPrintable(QStringLiteral(
                         "%1 is bound to %2, which the system takes before the app sees it")
                                    .arg(id, seq)));
        }

        // Specifically: the queue toggle, which is where this came from.
        QCOMPARE(shortcuts.sequence(QStringLiteral("queue")), QStringLiteral("Ctrl+J"));
    }

    // Main.qml binds every shortcut from the table and binds nothing else.
    void mainQmlBindsEveryEntryAndNoLiterals() {
        const QString main = readQml(QStringLiteral("Main.qml"));
        QVERIFY2(!main.isEmpty(), "qml/Main.qml could not be read");

        const QSet<QString> bound =
            captures(main, QStringLiteral("Shortcuts\\.sequence\\(\"([^\"]+)\"\\)"));
        const QStringList idList = Shortcuts().ids();
        const QSet<QString> table(idList.cbegin(), idList.cend());

        QVERIFY2(bound == table,
                 qPrintable(QStringLiteral(
                     "qml/Main.qml and the Shortcuts table disagree.\n"
                     "  bound in Main.qml: %1\n"
                     "  in the table:      %2\n"
                     "  bound but not in the table: %3\n"
                     "  in the table but never bound: %4")
                                .arg(sorted(bound), sorted(table),
                                     sorted(bound - table), sorted(table - bound))));

        // And no Shortcut has crept back to a literal, which is how the two
        // lists drifted apart in the first place.
        const QSet<QString> literals =
            captures(main, QStringLiteral("sequence:\\s*(\"[^\"]*\")"));
        QVERIFY2(literals.isEmpty(),
                 qPrintable(QStringLiteral(
                     "qml/Main.qml binds a sequence to a literal (%1); put it in "
                     "src/ui/Shortcuts.cpp and bind Shortcuts.sequence(\"id\")")
                                .arg(sorted(literals))));
    }

    // The Settings panel prints a row for every shortcut and names no id that
    // does not exist. A shortcut the app has and the panel does not mention is
    // undiscoverable; a row for a shortcut that was removed is a lie.
    void settingsPanelPrintsARowForEveryEntry() {
        const QString panel = readQml(QStringLiteral("components/SettingsPanel.qml"));
        QVERIFY2(!panel.isEmpty(), "qml/components/SettingsPanel.qml could not be read");

        // The rows are `{ ids: ["a", "b"], d: qsTr("...") }`; take every quoted
        // string inside each ids array.
        QSet<QString> printed;
        QRegularExpression rows(QStringLiteral("ids:\\s*\\[([^\\]]*)\\]"));
        auto it = rows.globalMatch(panel);
        while (it.hasNext())
            printed += captures(it.next().captured(1), QStringLiteral("\"([^\"]+)\""));

        const QStringList idList = Shortcuts().ids();
        const QSet<QString> table(idList.cbegin(), idList.cend());

        QVERIFY2(printed == table,
                 qPrintable(QStringLiteral(
                     "the Settings shortcut table and the Shortcuts table disagree.\n"
                     "  printed in Settings: %1\n"
                     "  in the table:        %2\n"
                     "  printed but not in the table: %3\n"
                     "  in the table but never printed: %4")
                                .arg(sorted(printed), sorted(table),
                                     sorted(printed - table), sorted(table - printed))));

        // The badge text is derived, never written out: a row that spelled its
        // own key would be wrong on macOS again the moment it was added.
        QVERIFY2(panel.contains(QStringLiteral("Shortcuts.display(")),
                 "the Settings rows no longer derive their key text from Shortcuts.display()");
    }

    // No QML file asks for a font family that is a generic name rather than a
    // real one.
    //
    // The key badges used to say font.family: "monospace". On Linux that
    // resolves and nothing looks wrong, which is exactly why it survived. On
    // macOS it does not resolve, and Qt answers a missing family by populating
    // its font-family alias table - 37 ms, measured on the Mac, on every single
    // launch, against about 470 ms to first frame.
    //
    // The same measurement killed the narrower fix. Removing "Inter" from the
    // macOS branch changed nothing at all, because the 37 ms line simply came
    // back naming "Monospace" instead: the cost is paid once by whichever
    // missing family comes first, so removing one just promotes the next. The
    // rule has to be that no missing family is named anywhere, which is a thing
    // about the whole tree rather than about one line, so it is checked over
    // the whole tree.
    void noQmlFileNamesAGenericFontFamily() {
        static const QStringList generics{
            QStringLiteral("monospace"), QStringLiteral("Monospace"),
            QStringLiteral("sans-serif"), QStringLiteral("Sans Serif"),
            QStringLiteral("sans"), QStringLiteral("serif"),
            QStringLiteral("cursive"), QStringLiteral("fantasy"),
        };
        QStringList offenders;
        QDirIterator it(QStringLiteral(TIDALWAVE_QML_DIR),
                        QStringList{ QStringLiteral("*.qml") },
                        QDir::Files, QDirIterator::Subdirectories);
        int scanned = 0;
        while (it.hasNext()) {
            const QString path = it.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
                continue;
            ++scanned;
            const QStringList lines =
                QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size(); ++i) {
                QRegularExpression re(
                    QStringLiteral("font\\.famil(?:y|ies)\\s*:\\s*\"([^\"]+)\""));
                auto m = re.match(lines.at(i));
                if (m.hasMatch() && generics.contains(m.captured(1))) {
                    offenders << QStringLiteral("%1:%2 names \"%3\"")
                                     .arg(QFileInfo(path).fileName())
                                     .arg(i + 1)
                                     .arg(m.captured(1));
                }
            }
        }
        QVERIFY2(scanned > 0, "no .qml files were scanned - TIDALWAVE_QML_DIR is wrong");
        QVERIFY2(offenders.isEmpty(),
                 qPrintable(QStringLiteral(
                     "a QML file names a generic font family, which is not a family on "
                     "every platform and costs ~37 ms of alias population on the ones "
                     "where it is missing. Ask the font database for a real name "
                     "instead (Shortcuts.monospaceFamily() does this).\n  %1")
                                .arg(offenders.join(QStringLiteral("\n  ")))));
    }
};

QTEST_GUILESS_MAIN(TestShortcuts)
#include "tst_shortcuts.moc"
