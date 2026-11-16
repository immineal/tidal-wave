// The words the app shows, read from the German catalogue, which carries
// every English source next to its German. One word per thing in both
// languages, sentence case in English, and separators kept out of strings.
// TIDALWAVE_QML_DIR comes from tests/CMakeLists.txt.

#include <QTest>
#include <QFile>
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

private:
    QList<Entry> m_entries;
};

QTEST_GUILESS_MAIN(TestWording)
#include "tst_wording.moc"
