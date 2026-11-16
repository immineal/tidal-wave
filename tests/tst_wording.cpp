// The words the app shows, read from the German catalogue, which carries
// every English source next to its German. One word per thing in both
// languages, sentence case in English, and separators kept out of strings.
// TIDALWAVE_QML_DIR comes from tests/CMakeLists.txt.

#include <QTest>
#include <QDirIterator>
#include <QFile>
#include <QRegularExpression>
#include <QStringList>
#include <QXmlStreamReader>

namespace {

struct Entry {
    QString context;
    QString source;
    QString german;   // numerus forms joined with " | "
};

QList<Entry> readCatalogue(QString *why) {
    QList<Entry> out;
    QFile f(QStringLiteral(TIDALWAVE_QML_DIR "/../i18n/tidal-wave_de.ts"));
    if (!f.open(QIODevice::ReadOnly)) {
        *why = QStringLiteral("could not read %1").arg(f.fileName());
        return out;
    }
    QXmlStreamReader xml(&f);
    QString context;
    Entry e;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == QLatin1String("message")) {
            e.context = context;
            out << e;
            e = Entry();
            continue;
        }
        if (!xml.isStartElement())
            continue;
        if (xml.name() == QLatin1String("name"))
            context = xml.readElementText();
        else if (xml.name() == QLatin1String("source"))
            e.source = xml.readElementText();
        else if (xml.name() == QLatin1String("translation"))
            e.german = xml.readElementText(QXmlStreamReader::IncludeChildElements);
    }
    if (xml.hasError())
        *why = xml.errorString();
    return out;
}

QString show(const Entry &e, const QString &text) {
    return QStringLiteral("[%1] %2").arg(e.context, text.left(90));
}

// Proper names, and the names of the app's own pages and Settings sections
// where a sentence refers to them. Removed before the case check.
const QStringList kNames = {
    QStringLiteral("Tidal Wave"), QStringLiteral("TIDAL Music AS"), QStringLiteral("Tidal"),
    QStringLiteral("Now Playing"), QStringLiteral("Dolby Atmos"),
    QStringLiteral("NetEase Cloud Music"), QStringLiteral("China"),
    QStringLiteral("Home / Search / Collection"), QStringLiteral("Experimental"),
    QStringLiteral("Feedback"), QStringLiteral("Hi-Res"), QStringLiteral("Qt"),
    QStringLiteral("Last.fm"),
};

} // namespace

class TestWording : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QString why;
        m_entries = readCatalogue(&why);
        QVERIFY2(why.isEmpty(), qPrintable(why));
        QVERIFY2(m_entries.size() > 300, "the catalogue reads as nearly empty");
    }

    // Tidal's own German calls the saved music "Sammlung", and the sidebar
    // does too. "Mediathek" is Apple's word, "Bibliothek" Spotify's.
    void germanHasOneWordForTheCollection() {
        QStringList bad;
        for (const Entry &e : std::as_const(m_entries))
            if (e.german.contains(QLatin1String("Mediathek"))
                || e.german.contains(QLatin1String("Bibliothek")))
                bad << show(e, e.german);
        QVERIFY2(bad.isEmpty(), qPrintable("not \"Sammlung\":\n  " + bad.join("\n  ")));
    }

    // German lines the owner chose, so a later edit does not undo them.
    void germanKeepsTheChosenLines() {
        const QList<QPair<QString, QString>> chosen = {
            { QStringLiteral("I've allowed access"), QStringLiteral("Ich habe zugestimmt") },
        };
        for (const auto &c : chosen) {
            bool found = false;
            for (const Entry &e : std::as_const(m_entries))
                if (e.source == c.first) {
                    found = true;
                    QCOMPARE(e.german, c.second);
                }
            QVERIFY2(found, qPrintable("not in the catalogue: " + c.first));
        }
    }

    // Lines that were English turned word for word into German, kept here
    // so they do not come back.
    void germanHasNoWordForWordLines() {
        const QStringList calques = {
            QStringLiteral("hereinlassen"),          // "Let the colour in"
            QStringLiteral("Aus teilen"),            // "Off, all six share"
            QStringLiteral("Jedes Thema"),           // the heading says "Design"
            QStringLiteral("Nach lrclib.net gefragt"),
            QStringLiteral(", standardmäßig an,"),
            QStringLiteral(", über die Schalter unter"),
            QStringLiteral("sehr fein aufgelöst"),
            QStringLiteral("bereits darin"),
            QStringLiteral("Nichts passt zu"),
            QStringLiteral("Mehr wird geladen"),
            QStringLiteral("nicht mehr existieren"),
        };
        QStringList bad;
        for (const Entry &e : std::as_const(m_entries))
            for (const QString &c : calques)
                if (e.german.contains(c))
                    bad << show(e, c);
        QVERIFY2(bad.isEmpty(), qPrintable("word for word:\n  " + bad.join("\n  ")));
    }

    // Sentence case: after the first word, only names and acronyms start
    // with a capital. A new sentence, or a quoted label, starts over.
    void englishIsInSentenceCase() {
        static const QRegularExpression word(QStringLiteral("[A-Za-z][A-Za-z'-]*"));
        QStringList bad;
        for (const Entry &e : std::as_const(m_entries)) {
            QString s = e.source;
            for (const QString &n : kNames)
                s.replace(n, QString(n.size(), QLatin1Char('x')));
            bool start = true;
            int last = 0;
            for (auto it = word.globalMatch(s); it.hasNext();) {
                const auto m = it.next();
                const QString between = s.mid(last, m.capturedStart() - last);
                last = m.capturedEnd();
                if (between.contains(QRegularExpression(QStringLiteral("[.?!]\\s")))
                    || between.contains(QLatin1Char('"')) || between.contains(u'“'))
                    start = true;
                const QString w = m.captured();
                const bool percent = between.endsWith(QLatin1Char('%'));
                const bool acronym = w.size() == 1
                    || w.mid(1).contains(QRegularExpression(QStringLiteral("[A-Z]")));
                if (!start && !percent && !acronym && w.at(0).isUpper())
                    bad << show(e, e.source);
                start = false;
            }
        }
        bad.removeDuplicates();
        QVERIFY2(bad.isEmpty(), qPrintable("Title Case:\n  " + bad.join("\n  ")));
    }

    // One noun per thing: a track, the collection, log in, show all, yours.
    void englishHasOneWordPerThing() {
        const QList<QPair<QRegularExpression, QString>> rules = {
            { QRegularExpression(QStringLiteral("\\bsongs?\\b"),
                                 QRegularExpression::CaseInsensitiveOption), "track" },
            { QRegularExpression(QStringLiteral("\\blibrary\\b"),
                                 QRegularExpression::CaseInsensitiveOption), "collection" },
            { QRegularExpression(QStringLiteral("\\bsign(ed)? (in|out)\\b"),
                                 QRegularExpression::CaseInsensitiveOption), "log in" },
            { QRegularExpression(QStringLiteral("\\bView all\\b")), "Show all" },
            { QRegularExpression(QStringLiteral("^My ")), "Your" },
        };
        QStringList bad;
        for (const Entry &e : std::as_const(m_entries))
            for (const auto &r : rules)
                if (r.first.match(e.source).hasMatch())
                    bad << show(e, e.source) + QStringLiteral("  (say \"%1\")").arg(r.second);
        QVERIFY2(bad.isEmpty(), qPrintable("another word for the same thing:\n  "
                                           + bad.join("\n  ")));
    }

    // A separator between two pieces belongs to the code that joins them,
    // and there is one: the middle dot.
    void separatorsStayOutOfStrings() {
        QStringList bad;
        for (const Entry &e : std::as_const(m_entries)) {
            const QString s = e.source.trimmed();
            if (s.contains(u'•') || e.german.contains(u'•')
                || s.startsWith(u'·') || s.endsWith(u'·'))
                bad << show(e, e.source);
        }
        QDirIterator it(QStringLiteral(TIDALWAVE_QML_DIR), { QStringLiteral("*.qml") },
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            QFile f(it.next());
            QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
            int line = 0;
            while (!f.atEnd()) {
                ++line;
                const QString l = QString::fromUtf8(f.readLine());
                if (l.contains(u'•') && !l.trimmed().startsWith(QLatin1String("//")))
                    bad << QStringLiteral("%1:%2").arg(it.fileName()).arg(line);
            }
        }
        QVERIFY2(bad.isEmpty(), qPrintable("a bullet, or a separator in a string:\n  "
                                           + bad.join("\n  ")));
    }

private:
    QList<Entry> m_entries;
};

QTEST_GUILESS_MAIN(TestWording)
#include "tst_wording.moc"
