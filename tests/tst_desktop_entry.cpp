// The installed desktop entry against the command line it launches: links
// arrive as %u, the tidal: scheme is claimed, and every action's Exec line
// is one the parser takes as a playback option for a running instance.

#include <QCoreApplication>
#include <QFile>
#include <QMap>
#include <QTest>

#include "ui/RemoteControl.h"

namespace {

using Groups = QMap<QString, QMap<QString, QString>>;

Groups readEntry(const QString &path) {
    Groups groups;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return groups;
    QString group;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        if (line.startsWith(QLatin1Char('[')) && line.endsWith(QLatin1Char(']'))) {
            group = line.mid(1, line.size() - 2);
            groups[group];
            continue;
        }
        const qsizetype eq = line.indexOf(QLatin1Char('='));
        if (eq > 0)
            groups[group].insert(line.left(eq).trimmed(), line.mid(eq + 1).trimmed());
    }
    return groups;
}

QStringList listValue(const QString &v) {
    QStringList items = v.split(QLatin1Char(';'));
    items.removeAll(QString());
    return items;
}

} // namespace

class TestDesktopEntry : public QObject {
    Q_OBJECT

    Groups m_entry;

private slots:
    void initTestCase() {
        m_entry = readEntry(QStringLiteral(TIDALWAVE_DESKTOP_FILE));
        QVERIFY2(m_entry.contains(QStringLiteral("Desktop Entry")), TIDALWAVE_DESKTOP_FILE);
    }

    void takesALink() {
        const auto main = m_entry.value(QStringLiteral("Desktop Entry"));
        QCOMPARE(main.value(QStringLiteral("Exec")), QStringLiteral("tidal-wave %u"));
        QVERIFY(listValue(main.value(QStringLiteral("MimeType")))
                    .contains(QStringLiteral("x-scheme-handler/tidal")));
    }

    void actionsAreRemotePlaybackOptions() {
        const QStringList actions =
            listValue(m_entry.value(QStringLiteral("Desktop Entry")).value(QStringLiteral("Actions")));
        QCOMPARE(actions, (QStringList{"PlayPause", "Next", "Previous"}));

        QList<LaunchRequest::Command> seen;
        for (const QString &id : actions) {
            const QString group = QStringLiteral("Desktop Action ") + id;
            QVERIFY2(m_entry.contains(group), qPrintable(group));
            const auto a = m_entry.value(group);
            QVERIFY2(!a.value(QStringLiteral("Name")).isEmpty(), qPrintable(group));
            QVERIFY2(!a.value(QStringLiteral("Name[de]")).isEmpty(), qPrintable(group));

            const QStringList exec = a.value(QStringLiteral("Exec")).split(QLatin1Char(' '),
                                                                           Qt::SkipEmptyParts);
            QVERIFY2(exec.size() >= 2, qPrintable(group));
            // Flatpak rewrites the binary name; it has to be the main entry's.
            QCOMPARE(exec.first(), QStringLiteral("tidal-wave"));
            const RemoteControl::Parsed p = RemoteControl::parseArguments(exec);
            QVERIFY2(!p.exit, qPrintable(p.error));
            QCOMPARE(p.request.commands.size(), 1);
            QVERIFY2(!p.request.show, qPrintable(group));
            seen << p.request.commands.first();
        }
        QCOMPARE(seen, (QList<LaunchRequest::Command>{LaunchRequest::Command::PlayPause,
                                                      LaunchRequest::Command::Next,
                                                      LaunchRequest::Command::Previous}));
    }
};

QTEST_GUILESS_MAIN(TestDesktopEntry)
#include "tst_desktop_entry.moc"
