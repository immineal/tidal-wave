// The tray icon's menu, built without a tray host: its labels have to follow
// a live language switch, the window's state and the player's.

#include <QAction>
#include <QApplication>
#include <QMenu>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "ui/I18n.h"
#include "ui/Prefs.h"
#include "ui/TrayMenu.h"

class TestTrayMenu : public QObject {
    Q_OBJECT

    static QAction *action(const TrayMenu &tray, const char *name) {
        return tray.menu()->findChild<QAction *>(QString::fromLatin1(name));
    }

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_tray_menu"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // The menu is built in English and the language is then switched in
    // Settings, which installs the German catalogue while the app runs.
    void followsALiveLanguageSwitch() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("en"));
        I18n i18n(&prefs);
        TrayMenu tray;
        QCOMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Quit"));

        prefs.setLanguage(QStringLiteral("de"));
        QCOMPARE(i18n.effectiveLanguage(), QStringLiteral("de"));
        // Qt posts LanguageChange to the widgets.
        QTRY_COMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Beenden"));

        prefs.setLanguage(QStringLiteral("en"));
        QTRY_COMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Quit"));
    }

    // One entry for the window, not a Show beside a Hide that does nothing.
    void oneEntryForTheWindow() {
        TrayMenu tray;
        int windowItems = 0;
        for (QAction *a : tray.menu()->actions()) {
            if (a->text() == QLatin1String("Show") || a->text() == QLatin1String("Hide"))
                ++windowItems;
        }
        QCOMPARE(windowItems, 1);
    }

    void theWindowEntrySaysWhatItDoes() {
        TrayMenu tray;
        QAction *toggle = action(tray, "trayToggleWindow");
        QVERIFY(toggle);
        TrayMenu::State s;
        s.windowShown = false;
        tray.setState(s);
        QCOMPARE(toggle->text(), QStringLiteral("Show"));
        s.windowShown = true;
        tray.setState(s);
        QCOMPARE(toggle->text(), QStringLiteral("Hide"));

        QSignalSpy toggled(&tray, &TrayMenu::toggleWindowRequested);
        toggle->trigger();
        QCOMPARE(toggled.count(), 1);
    }

    // Previous, Play or Pause, Next: what Strawberry and Clementine offer.
    void hasPlaybackControls() {
        TrayMenu tray;
        QVERIFY(action(tray, "trayPrevious"));
        QVERIFY(action(tray, "trayPlayPause"));
        QVERIFY(action(tray, "trayNext"));
    }

    void playbackFollowsThePlayer() {
        TrayMenu tray;
        QAction *prev = action(tray, "trayPrevious");
        QAction *play = action(tray, "trayPlayPause");
        QAction *next = action(tray, "trayNext");

        // Nothing queued: the buttons would do nothing, and the tooltip
        // names the app.
        TrayMenu::State s;
        tray.setState(s);
        QVERIFY(!play->isEnabled() && !prev->isEnabled() && !next->isEnabled());
        QCOMPARE(tray.toolTip(), QCoreApplication::applicationName());

        QSignalSpy tip(&tray, &TrayMenu::toolTipChanged);
        s.hasTrack = true;
        s.title = QStringLiteral("A Song");
        s.artist = QStringLiteral("A Band");
        tray.setState(s);
        QVERIFY(play->isEnabled() && prev->isEnabled() && next->isEnabled());
        QCOMPARE(play->text(), QStringLiteral("Play"));
        QCOMPARE(tray.toolTip(), QStringLiteral("A Song - A Band"));
        QVERIFY(!tip.isEmpty());
        QCOMPARE(tip.last().first().toString(), QStringLiteral("A Song - A Band"));

        s.playing = true;
        tray.setState(s);
        QCOMPARE(play->text(), QStringLiteral("Pause"));

        QSignalSpy pp(&tray, &TrayMenu::playPauseRequested);
        QSignalSpy nx(&tray, &TrayMenu::nextRequested);
        QSignalSpy pv(&tray, &TrayMenu::previousRequested);
        play->trigger();
        next->trigger();
        prev->trigger();
        QCOMPARE(pp.count(), 1);
        QCOMPARE(nx.count(), 1);
        QCOMPARE(pv.count(), 1);
    }

    void playbackLabelsAreTranslated() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        TrayMenu tray;
        TrayMenu::State s;
        s.hasTrack = true;
        s.playing = true;
        tray.setState(s);
        QCOMPARE(action(tray, "trayPlayPause")->text(), QStringLiteral("Pausieren"));
        QCOMPARE(action(tray, "trayNext")->text(), QStringLiteral("Nächster Titel"));
        QCOMPARE(action(tray, "trayPrevious")->text(), QStringLiteral("Vorheriger Titel"));
        prefs.setLanguage(QStringLiteral("en"));
    }

private:
    QTemporaryDir m_dir;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    TestTrayMenu tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_tray_menu.moc"
