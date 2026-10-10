// The keyboard shortcut table in src/ui/Shortcuts.cpp, and the two QML files
// that must agree with it. Qt maps "Ctrl" onto Command on macOS, so a literal
// sequence in QML or a literal key name in Settings is wrong there.
// The last tests read the QML sources as text: the question is whether the
// source still routes through the table. TIDALWAVE_QML_DIR comes from
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
// QCoreApplication::translate(context, text, comment), so a key is all three
// parts, joined with the ASCII unit separator, which none of them can contain.
QString trKey(const QString &context, const QString &source, const QString &comment) {
    return context + QChar(0x1f) + source + QChar(0x1f) + comment;
}

// The context Qt derives for a qsTr() in a .qml file: the file name without
// directory and ".qml" (QQmlTranslation::contextFromQmlFilename). An inline
// `component` shares the file's context. baseName() would cut at the first dot.
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
    // Parsed only, see theUnfinishedFlagIsNotLoadBearing().
    bool unfinished = false;
};

// Read a .ts catalogue into (context, source, comment) -> entry. Read as XML
// because the sources are XML-escaped (`&quot;`, `&amp;`) and a reader
// un-escapes them.
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
                    // Every plural form has to carry text. Qt picks one by the
                    // number at runtime, and an empty form renders empty.
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

// "1 call site" / "7 call sites".
QString countOf(qsizetype n, const QString &singular, const QString &plural) {
    return QStringLiteral("%1 %2").arg(n).arg(n == 1 ? singular : plural);
}

// QTest truncates a failure message at about 4 KiB without saying so, so every
// list is capped here and its real length goes in the prose.
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
    // A sequence QKeySequence cannot parse is a shortcut that silently never
    // fires, so every entry is round-tripped through the runtime parser.
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

        // An id that is not in the table answers with nothing. QML's Shortcut
        // ignores an empty sequence, so a typo disables one shortcut and binds
        // no arbitrary key.
        QVERIFY(shortcuts.sequence(QStringLiteral("noSuchShortcut")).isEmpty());
        QVERIFY(shortcuts.display(QStringLiteral("noSuchShortcut")).isEmpty());
    }

    // Nothing in the table may use a sequence the system takes before the app
    // sees it. Only the four that cost the user their session or window on
    // macOS are refused. Ctrl+M and F11 also collide there and are allowed.
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

        // The queue toggle in particular.
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

        // And no Shortcut is bound to a literal.
        const QSet<QString> literals =
            captures(main, QStringLiteral("sequence:\\s*(\"[^\"]*\")"));
        QVERIFY2(literals.isEmpty(),
                 qPrintable(QStringLiteral(
                     "qml/Main.qml binds a sequence to a literal (%1); put it in "
                     "src/ui/Shortcuts.cpp and bind Shortcuts.sequence(\"id\")")
                                .arg(sorted(literals))));
    }

    // The Settings panel prints a row for every shortcut and names no id that
    // does not exist.
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

        // The badge text is derived: a row that spelled its own key would be
        // wrong on macOS.
        QVERIFY2(panel.contains(QStringLiteral("Shortcuts.display(")),
                 "the Settings rows no longer derive their key text from Shortcuts.display()");
    }

    // No QML file asks for a generic font family such as "monospace". Where the
    // name does not resolve, as on macOS, Qt populates its font-family alias
    // table on every launch, whichever missing family comes first.
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

    // Every string the UI marks with qsTr() is in the German catalogue under
    // the context Qt looks it up in, keyed on context, source and comment, and
    // carries text. A missing or reworded string silently renders in English.
    void everyTranslatableStringIsInTheGermanCatalogue() {
        // Derived from the QML dir, so it needs no define of its own.
        const QString tsPath = QStringLiteral(TIDALWAVE_QML_DIR)
                               + QStringLiteral("/../i18n/tidal-wave_de.ts");
        QHash<QString, CatalogueEntry> entries;
        QSet<QString> catalogueContexts;
        QString why;
        QVERIFY2(parseCatalogue(tsPath, &entries, &catalogueContexts, &why), qPrintable(why));
        QVERIFY2(!entries.isEmpty(), "the German catalogue parsed as empty");

        // Matches qsTr("text"), qsTr("text", "comment") and the %n form, with the
        // comment on the next line too. \bqsTr\s*\( cannot match qsTranslate( or
        // qsTrId(. No raw string literal: moc does not lex R"( )" reliably.
        const QString quotedLiteral =
            QStringLiteral("\"((?:[^\"\\\\]|\\\\.)*)\"");
        const QRegularExpression callQsTr(
            QStringLiteral("\\bqsTr\\s*\\(\\s*") + quotedLiteral
            + QStringLiteral("\\s*(?:,\\s*") + quotedLiteral + QStringLiteral(")?"));
        // qsTranslate("Context", "text") names its context outright, so those
        // call sites are checked against the context they name.
        const QRegularExpression callQsTranslate(
            QStringLiteral("\\bqsTranslate\\s*\\(\\s*") + quotedLiteral
            + QStringLiteral("\\s*,\\s*") + quotedLiteral
            + QStringLiteral("\\s*(?:,\\s*") + quotedLiteral + QStringLiteral(")?"));

        QList<CallSite> sites;
        // The raw file names, used below to decide which catalogue contexts
        // belong to QML. Not derived through qmlTrContext(), so that a wrong
        // derivation there shows up as orphans.
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

        // Anti-vacuity, first half. A broken extraction examines nothing and
        // passes. The floors are far under the real numbers and only catch a
        // regex that stopped matching.
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
        // If the comment were dropped on both sides every key would still match,
        // so the call sites that carry one are counted.
        QVERIFY2(withComment >= 25,
                 qPrintable(QStringLiteral("only %1 call sites came back with a "
                                           "disambiguation comment; the comment is being "
                                           "dropped, which makes the key too weak")
                                .arg(withComment)));

        // A whole context missing from the catalogue means the .qml file is new
        // and lupdate has never seen it. Reported separately from single strings.
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
        // Every entry under a context named after a .qml file must be asked for
        // by some call site. This notices a reworded string, and a wrong context
        // derivation orphans everything. Contexts from src/ have no .qml: skipped.
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

    // The `type="unfinished"` flag is not part of the rule above: lrelease
    // ships an unfinished translation as long as it carries text. That holds
    // only while lrelease runs without --no-unfinished, which this checks.
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
