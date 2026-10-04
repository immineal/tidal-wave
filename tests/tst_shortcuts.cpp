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
#include <QHash>
#include <QList>
#include <QRegularExpression>
#include <QSet>
#include <QStringList>
#include <QXmlStreamReader>

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

// ── The German catalogue, keyed the way Qt looks a translation up ────────────

// qsTr("text", "comment") in QML compiles to
// QCoreApplication::translate(context, text, comment), so a lookup is keyed on
// all three parts and a key here has to be all three. Joined with the ASCII
// unit separator, which none of the three can contain.
QString trKey(const QString &context, const QString &source, const QString &comment) {
    return context + QChar(0x1f) + source + QChar(0x1f) + comment;
}

// The context Qt derives for a qsTr() in a .qml file: the file name with the
// directory and the ".qml" taken off, and nothing else.
//
// This is not a guess. It is QQmlTranslation::contextFromQmlFilename() in
// QtQml/private/qqmltranslation_p.h, which is literally
// `mid(lastSlash + 1, size - lastSlash - 5)` over the file's URL.
//
// The consequence that matters here is that an inline `component Foo: Item { }`
// does *not* get a context of its own - everything in a file shares the file's
// one - and the catalogue lupdate writes agrees: PlayerBar.qml's
// `component OutputRow` keeps its "This computer" under PlayerBar, and
// QueuePanel.qml's `component QueueEntry` keeps "Remove from queue" under
// QueuePanel. Checked both ways by the test below, which also requires that no
// entry under a QML context goes unasked-for; a wrong derivation here cannot
// pass that half quietly, it fails it about three hundred times.
//
// completeBaseName() and not baseName(), because baseName() cuts at the *first*
// dot and Qt cuts at ".qml".
QString qmlTrContext(const QString &path) {
    return QFileInfo(path).completeBaseName();
}

// A QML string literal with its backslash escapes resolved, in one left-to-right
// pass. A chain of QString::replace() calls cannot do this correctly: whichever
// of \\ and \" is handled second rewrites what the first one produced.
QString unescapeQmlLiteral(const QString &literal) {
    QString out;
    out.reserve(literal.size());
    for (qsizetype i = 0; i < literal.size(); ++i) {
        const QChar c = literal.at(i);
        if (c != QLatin1Char('\\') || i + 1 >= literal.size()) {
            out += c;
            continue;
        }
        const QChar esc = literal.at(++i);
        switch (esc.unicode()) {
        case 'n': out += QLatin1Char('\n'); break;
        case 'r': out += QLatin1Char('\r'); break;
        case 't': out += QLatin1Char('\t'); break;
        case '0': out += QChar(u'\0');      break;
        default:  out += esc;               break; // \" \' \\ and anything else
        }
    }
    return out;
}

struct CatalogueEntry {
    // Nothing to show, so the UI falls back to English. This is the flag the
    // test below treats as a failure.
    bool blank = true;
    // Parsed but deliberately not enforced - see theUnfinishedFlagIsNotLoadBearing()
    // for why, and for the one condition under which it would have to be. It is
    // parsed anyway so that tightening the rule is a one-line change rather than
    // a reason to put it off.
    bool unfinished = false;
};

// Read a .ts catalogue into (context, source, comment) -> entry.
//
// Read as XML rather than scanned with a regex, because the sources in it are
// XML-escaped - `No results for &quot;%1&quot;`, `Singles &amp; EPs` - and a
// reader un-escapes them already. Doing it by hand is how a guard ends up
// comparing `&quot;` against `"` and finding nothing.
bool parseCatalogue(const QString &path,
                    QHash<QString, CatalogueEntry> *entries,
                    QSet<QString> *contexts,
                    QString *why) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        *why = QStringLiteral("could not read %1").arg(path);
        return false;
    }
    QXmlStreamReader xml(&f);
    QString context;
    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement())
            continue;
        // <name> occurs only as a <context>'s name in the TS format.
        if (xml.name() == QLatin1String("name")) {
            context = xml.readElementText();
            contexts->insert(context);
            continue;
        }
        if (xml.name() != QLatin1String("message"))
            continue;

        const bool numerus =
            xml.attributes().value(QLatin1String("numerus")) == QLatin1String("yes");
        QString source, comment, type;
        bool blank = true;
        while (!xml.hasError()
               && !(xml.isEndElement() && xml.name() == QLatin1String("message"))) {
            xml.readNext();
            if (xml.atEnd())
                break;
            if (!xml.isStartElement())
                continue;
            if (xml.name() == QLatin1String("source")) {
                source = xml.readElementText();
            } else if (xml.name() == QLatin1String("comment")) {
                comment = xml.readElementText();
            } else if (xml.name() == QLatin1String("translation")) {
                type = xml.attributes().value(QLatin1String("type")).toString();
                if (numerus) {
                    // Every plural form has to carry text. Qt picks one of them
                    // by the number at runtime, so one empty form is one count
                    // that renders empty - not one that falls back to English.
                    int forms = 0;
                    bool anyEmpty = false;
                    while (!xml.hasError()
                           && !(xml.isEndElement()
                                && xml.name() == QLatin1String("translation"))) {
                        xml.readNext();
                        if (xml.atEnd())
                            break;
                        if (xml.isStartElement()
                            && xml.name() == QLatin1String("numerusform")) {
                            ++forms;
                            if (xml.readElementText().trimmed().isEmpty())
                                anyEmpty = true;
                        }
                    }
                    blank = (forms == 0) || anyEmpty;
                } else {
                    // trimmed(), because a translation of nothing but spaces is
                    // never deliberate. ArtistLinks' ", " survives it.
                    blank = xml.readElementText().trimmed().isEmpty();
                }
            }
        }
        if (!source.isEmpty()) {
            CatalogueEntry e;
            e.blank = blank;
            e.unfinished = (type == QLatin1String("unfinished"));
            entries->insert(trKey(context, source, comment), e);
        }
    }
    if (xml.hasError()) {
        *why = QStringLiteral("%1 is not well-formed XML: %2").arg(path, xml.errorString());
        return false;
    }
    return true;
}

// "1 call site" / "7 call sites". A guard whose failure message says "1 strings"
// reads as sloppily built as the bug it just found, and nobody trusts it.
QString countOf(qsizetype n, const QString &singular, const QString &plural) {
    return QStringLiteral("%1 %2").arg(n).arg(n == 1 ? singular : plural);
}

// QTest truncates a failure message at about 4 KiB. Measured: a list of 312 call
// sites printed 58 of them and then simply stopped, with nothing in the output to
// say that it had. So every list below is capped here and its real length goes in
// the prose - the count is the part you cannot afford to lose, because it is what
// tells you whether one string broke or the whole check did.
QString firstFew(const QStringList &lines, int limit = 25) {
    QString out = QStringList(lines.mid(0, limit)).join(QStringLiteral("\n  "));
    if (lines.size() > limit)
        out += QStringLiteral("\n  ... and %1 more").arg(lines.size() - limit);
    return out;
}

// One qsTr()/qsTranslate() call found in a .qml file.
struct CallSite {
    QString file;     // for the failure message
    int     line = 0;
    QString context;  // the file's, or the one qsTranslate() names
    QString source;
    QString comment;
};

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

    // Every string the UI asks to be translated is in the German catalogue
    // *under the context Qt will look it up in*, with something to show.
    //
    // qsTr() only marks a string; it does not translate it. A string that was
    // never added to i18n/tidal-wave_de.ts silently renders in English, and on
    // a German desktop that is one English line in the middle of a German
    // panel - which is exactly what a screenshot from the Mac showed for the
    // new "Interface size" row.
    //
    // It also catches the other half, which is worse because it looks fine in
    // the diff: changing the English wording of an already-translated string
    // orphans its entry, so the translation stops being found and the string
    // silently reverts to English. The login page had been reading "Native
    // Desktop Tidal Client" in English on German systems ever since the
    // tagline stopped saying Linux, and nobody noticed.
    //
    // This used to collect every <source> in the catalogue into one flat set
    // and ask whether each qsTr() string was in it *somewhere*. That is not the
    // question. Qt looks a translation up per context, so a string that exists
    // under NewPlaylistDialog and not under PlaylistPage is translated in the
    // first and English in the second, and the flat set could not tell the two
    // apart - which is how `Enter a name for the playlist.` shipped half
    // translated. The old check was blind to the empty translation too: lupdate
    // writes `<translation type="unfinished"></translation>` for a string it has
    // never seen, that counts as a <source>, and the flat set went green on a
    // string with no German at all. Both holes are the same mistake, which is
    // asking a weaker question than the one the runtime asks.
    //
    // So the key here is the whole triple Qt keys on - context, source text and
    // the disambiguation comment - and the entry has to carry text.
    //
    // The gap this guards is narrow and worth naming, because it says what a
    // failure means. lupdate propagates: given `Show less` under ArtistPage and
    // a new qsTr("Show less") in RadioPage.qml, running update_translations
    // copies the German across ("Same-text heuristic provided 1 translation",
    // measured). So a tree whose catalogue is up to date cannot fail the first
    // half of this test. What fails it is a qsTr() added without running
    // update_translations - and, whether or not lupdate was run, a string whose
    // German nobody has written yet, which is the second half.
    void everyTranslatableStringIsInTheGermanCatalogue() {
        // Derived from the QML dir rather than given its own define, so this
        // needs no build-system change to stay true.
        const QString tsPath = QStringLiteral(TIDALWAVE_QML_DIR)
                               + QStringLiteral("/../i18n/tidal-wave_de.ts");
        QHash<QString, CatalogueEntry> entries;
        QSet<QString> catalogueContexts;
        QString why;
        QVERIFY2(parseCatalogue(tsPath, &entries, &catalogueContexts, &why), qPrintable(why));
        QVERIFY2(!entries.isEmpty(), "the German catalogue parsed as empty");

        // `qsTr("text")`, `qsTr("text", "comment")` and
        // `qsTr("%n thing(s)", "comment", n)`: the comment is the second
        // argument when it is a literal, and it is often on the next line, which
        // \s* covers. \bqsTr\s*\( cannot match qsTranslate( or qsTrId(.
        // Written with escaped quotes rather than a raw string literal on
        // purpose: moc does not lex R"delim( ... )delim" reliably, and a raw
        // string here makes it emit an empty .moc and the link fail on a missing
        // vtable, which says nothing about the cause.
        const QString quotedLiteral =
            QStringLiteral("\"((?:[^\"\\\\]|\\\\.)*)\"");
        const QRegularExpression callQsTr(
            QStringLiteral("\\bqsTr\\s*\\(\\s*") + quotedLiteral
            + QStringLiteral("\\s*(?:,\\s*") + quotedLiteral + QStringLiteral(")?"));
        // qsTranslate("Context", "text") names its context outright. Three call
        // sites borrow a string from another file that way - QueuePanel takes
        // TrackRow's "Unknown track", SideBar takes SettingsPanel's "Settings" -
        // and they break in exactly the same silent way when the context they
        // name loses the entry, so they are checked against the context they
        // name rather than against their own file.
        const QRegularExpression callQsTranslate(
            QStringLiteral("\\bqsTranslate\\s*\\(\\s*") + quotedLiteral
            + QStringLiteral("\\s*,\\s*") + quotedLiteral
            + QStringLiteral("\\s*(?:,\\s*") + quotedLiteral + QStringLiteral(")?"));

        QList<CallSite> sites;
        // The *raw* file names, straight off the directory iterator. Used below
        // to decide which catalogue contexts belong to QML, and deliberately not
        // derived through qmlTrContext(): a wrong derivation has to show up as a
        // catalogue full of orphans, and it cannot do that if the same wrong
        // derivation is what decides which contexts to look at. Probed - with
        // qmlTrContext() lower-casing its answer and this set derived from it,
        // the orphan half found nothing at all.
        QSet<QString> qmlFileNames;
        int filesScanned = 0;
        QDirIterator it(QStringLiteral(TIDALWAVE_QML_DIR),
                        QStringList{ QStringLiteral("*.qml") },
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            QFile q(path);
            if (!q.open(QIODevice::ReadOnly | QIODevice::Text))
                continue;
            ++filesScanned;
            const QString text = QString::fromUtf8(q.readAll());
            const QString fileName = QFileInfo(path).fileName();
            const QString ownContext = qmlTrContext(path);
            qmlFileNames.insert(fileName);

            const auto lineOf = [&text](qsizetype offset) {
                return int(QStringView(text).left(offset).count(QLatin1Char('\n'))) + 1;
            };

            auto tit = callQsTr.globalMatch(text);
            while (tit.hasNext()) {
                const auto m = tit.next();
                sites.append({ fileName, lineOf(m.capturedStart()), ownContext,
                               unescapeQmlLiteral(m.captured(1)),
                               unescapeQmlLiteral(m.captured(2)) });
            }
            auto xit = callQsTranslate.globalMatch(text);
            while (xit.hasNext()) {
                const auto m = xit.next();
                sites.append({ fileName, lineOf(m.capturedStart()),
                               unescapeQmlLiteral(m.captured(1)),
                               unescapeQmlLiteral(m.captured(2)),
                               unescapeQmlLiteral(m.captured(3)) });
            }
        }
        QVERIFY2(filesScanned > 0, "no .qml files were scanned - TIDALWAVE_QML_DIR is wrong");

        // Anti-vacuity, first half. A guard like this one does not fail when its
        // extraction breaks - it passes, having examined nothing, and the last
        // one in this repo did exactly that with a row spelled `shortcuts` where
        // the tree says `Shortcuts`. The floors below are deliberately far under
        // the real numbers; they are a tripwire for "the regex stopped matching",
        // not a count anybody has to keep up to date. The real protection is the
        // other direction, checked further down.
        int withComment = 0;
        QSet<QString> contextsCovered;
        for (const CallSite &s : sites) {
            if (!s.comment.isEmpty())
                ++withComment;
            contextsCovered.insert(s.context);
        }
        qInfo("examined %lld qsTr()/qsTranslate() call sites in %d .qml files, "
              "across %lld contexts, %d of them carrying a disambiguation comment, "
              "against %lld catalogue entries",
              qint64(sites.size()), filesScanned, qint64(contextsCovered.size()),
              withComment, qint64(entries.size()));
        QVERIFY2(sites.size() >= 200,
                 qPrintable(QStringLiteral("only %1 qsTr() call sites were found in %2 "
                                           "files; the extraction is broken, not the tree")
                                .arg(sites.size()).arg(filesScanned)));
        QVERIFY2(contextsCovered.size() >= 15,
                 qPrintable(QStringLiteral("call sites were found in only %1 contexts")
                                .arg(contextsCovered.size())));
        // If the comment were being dropped on both sides, every key would still
        // match and the whole test would pass while being blind to a qsTr() whose
        // comment disagrees with the catalogue's. So count the ones that carry
        // one and insist they exist.
        QVERIFY2(withComment >= 25,
                 qPrintable(QStringLiteral("only %1 call sites came back with a "
                                           "disambiguation comment; the comment is being "
                                           "dropped, which makes the key too weak")
                                .arg(withComment)));

        // A whole context missing from the catalogue means something different
        // from one string missing: the .qml file is new and lupdate has never
        // seen it. Said separately, because otherwise the list below is every
        // string in that file and the one fact worth knowing is buried in it.
        QStringList unknownContexts;
        for (const QString &c : contextsCovered)
            if (!catalogueContexts.contains(c))
                unknownContexts << c;
        unknownContexts.sort();
        QVERIFY2(unknownContexts.isEmpty(),
                 qPrintable(QStringLiteral(
                     "i18n/tidal-wave_de.ts has no <context> at all for %1, so every "
                     "qsTr() in %2 renders in English. lupdate has never seen the file: "
                     "run `cmake --build <dir> --target update_translations`, then write "
                     "the German.")
                                .arg(unknownContexts.join(QStringLiteral(", ")),
                                     unknownContexts.size() == 1
                                         ? QStringLiteral("it")
                                         : QStringLiteral("them"))));

        // ── Every call site resolves ─────────────────────────────────────────
        QStringList noEntry, noGerman;
        QSet<QString> asked;
        for (const CallSite &s : sites) {
            const QString key = trKey(s.context, s.source, s.comment);
            asked.insert(key);
            const QString where =
                QStringLiteral("%1:%2  [%3] \"%4\"%5")
                    .arg(s.file).arg(s.line).arg(s.context, s.source,
                         s.comment.isEmpty() ? QString()
                                             : QStringLiteral("  (comment: \"%1\")").arg(s.comment));
            const auto found = entries.constFind(key);
            if (found == entries.cend())
                noEntry << where;
            else if (found->blank)
                noGerman << where;
        }
        noEntry.removeDuplicates();
        noGerman.removeDuplicates();
        noEntry.sort();
        noGerman.sort();

        QVERIFY2(noEntry.isEmpty(),
                 qPrintable(QStringLiteral(
                     "no entry in i18n/tidal-wave_de.ts under the context Qt looks these "
                     "up in, which is the file's own name. An entry under a *different* "
                     "context does not help, because Qt never looks there, so each of "
                     "these renders in English inside an otherwise German UI.\n"
                     "Run `cmake --build <dir> --target update_translations`, which also "
                     "copies an identical string's German across contexts for you.\n"
                     "%1:\n  %2")
                                .arg(countOf(noEntry.size(), QStringLiteral("call site"),
                                             QStringLiteral("call sites")),
                                     firstFew(noEntry))));

        QVERIFY2(noGerman.isEmpty(),
                 qPrintable(QStringLiteral(
                     "an entry in i18n/tidal-wave_de.ts under the right context, but with "
                     "an empty <translation>, which renders in English exactly as if the "
                     "entry were missing. lupdate writes an empty entry for every string "
                     "it has not seen before, so this is what a freshly marked string "
                     "looks like until somebody writes the German. Write it.\n"
                     "%1:\n  %2")
                                .arg(countOf(noGerman.size(), QStringLiteral("call site"),
                                             QStringLiteral("call sites")),
                                     firstFew(noGerman))));

        // ── Anti-vacuity, second half: nothing in the catalogue is orphaned ──
        //
        // The other direction, and the one that cannot pass quietly. For every
        // context in the catalogue that is a .qml file's name, every entry under
        // it has to be a string some call site in the tree actually asks for.
        //
        // That is a real guard - it is how a reworded string gets noticed, since
        // the old entry is left behind keyed on the old English - and it is also
        // what makes the derivation above impossible to get wrong silently. Spell
        // the context differently from the tree, lower-case it, take baseName()
        // instead of completeBaseName(), stop stripping ".qml", and every single
        // entry under every QML context becomes an orphan at once.
        //
        // Contexts with no .qml of their own - Player, Downloader, Application,
        // CastManager, Feedback, I18n and the rest come from src/ - are not this
        // test's business and are skipped by name, not by a hand-kept list.
        QStringList orphans;
        for (auto e = entries.cbegin(); e != entries.cend(); ++e) {
            const QStringList parts = e.key().split(QChar(0x1f));
            if (parts.size() != 3
                || !qmlFileNames.contains(parts.at(0) + QStringLiteral(".qml")))
                continue;
            if (!asked.contains(e.key()))
                orphans << QStringLiteral("[%1] \"%2\"%3")
                               .arg(parts.at(0), parts.at(1),
                                    parts.at(2).isEmpty()
                                        ? QString()
                                        : QStringLiteral("  (comment: \"%1\")").arg(parts.at(2)));
        }
        orphans.sort();
        QVERIFY2(orphans.isEmpty(),
                 qPrintable(QStringLiteral(
                     "i18n/tidal-wave_de.ts holds entries under a context named after a "
                     ".qml file that no qsTr() in that file asks for. Either the English was "
                     "reworded and the old entry was left behind - in which case the string "
                     "on screen is now untranslated - or this test can no longer find the "
                     "call sites, which is worse. `update_translations` drops a genuinely "
                     "dead entry (it runs with -no-obsolete).\n"
                     "%1 unasked-for:\n  %2")
                                .arg(countOf(orphans.size(), QStringLiteral("entry"),
                                             QStringLiteral("entries")),
                                     firstFew(orphans))));
    }

    // The `type="unfinished"` flag is deliberately *not* part of the rule above,
    // and this is the test that keeps that decision honest.
    //
    // lrelease ships an unfinished translation as long as it carries text.
    // Measured on a compiled .qm: "Generated 332 translation(s) (331 finished
    // and 1 unfinished)", and the unfinished one was in the file and came out of
    // the lookup. So the flag is Linguist's bookkeeping about whether a human
    // has signed a string off, not a runtime switch, and requiring it here would
    // fail the build for a string whose German is correct and shipping. It would
    // also fire on every propagated string the moment anyone ran
    // update_translations: lupdate's same-text heuristic fills the German in and
    // marks the result unfinished, so the only way to green would be hand-editing
    // an attribute out of an XML file. A guard that cries wolf gets deleted.
    //
    // That reasoning depends entirely on lrelease being run without
    // --no-unfinished. With that option the flag stops being bookkeeping and
    // starts deciding what exists at runtime, an unfinished entry disappears from
    // the .qm, and "the <translation> carries text" above stops meaning "the user
    // sees German". The project passes no LRELEASE_OPTIONS at all, so the rest of
    // this file is sound - and this test is here to say so the day someone adds
    // them, rather than leaving the discovery to a German screenshot.
    void theUnfinishedFlagIsNotLoadBearing() {
        const QString path = QStringLiteral(TIDALWAVE_QML_DIR)
                             + QStringLiteral("/../CMakeLists.txt");
        QFile f(path);
        QVERIFY2(f.open(QIODevice::ReadOnly | QIODevice::Text),
                 qPrintable(QStringLiteral("could not read %1").arg(path)));
        const QString cmake = QString::fromUtf8(f.readAll());

        QVERIFY2(cmake.contains(QStringLiteral("qt_add_translations")),
                 "CMakeLists.txt no longer calls qt_add_translations(); this test is "
                 "looking at the wrong file and proving nothing");
        QVERIFY2(!cmake.contains(QStringLiteral("no-unfinished")),
                 "the build now passes --no-unfinished to lrelease, which drops every "
                 "entry still marked type=\"unfinished\" out of the .qm. That makes the "
                 "flag load-bearing, and the German catalogue is not kept clean of it: "
                 "lupdate marks every string its same-text heuristic fills in as "
                 "unfinished, with correct German. Either drop the option, or extend "
                 "everyTranslatableStringIsInTheGermanCatalogue() to treat an unfinished "
                 "entry as missing and clear the flag across i18n/tidal-wave_de.ts.");
    }
};

QTEST_GUILESS_MAIN(TestShortcuts)
#include "tst_shortcuts.moc"
